// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {JobRegistry, IUSDC} from "../src/JobRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import "../src/Types.sol";
import {JobHarness} from "./utils/JobHarness.sol";
import {AuthSig} from "./utils/AuthSig.sol";
import {OpSig} from "./utils/OpSig.sol";
import {FalseTransferToken} from "./utils/TestDoubles.sol";

/// @notice The prepaid ledger: `deposit`, `withdraw`, and the three permissionless payouts.
contract JobRegistryLedgerTest is JobHarness {
    bytes32 constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    /// @dev feeBps 100, gasFee 5 and the constructor's $0.002 deposit fee, so the harness's one
    /// deposit already earned its relayer, the test contract, 2_000.
    function _fees() internal override {
        vm.prank(curation);
        jr.setFees(100, 5, 2_000);
    }

    // ── deposit ───────────────────────────────────────────────────────────────────────────────

    function test_the_harness_deposit_credited_value_minus_the_deposit_fee() public view {
        assertEq(START, DEPOSIT - 2_000);
        assertEq(jr.relayerEarned(address(this)), 2_000);
        assertEq(jr.accrued(), 0);
        assertEq(usdc.balanceOf(address(jr)), DEPOSIT);
        assertEq(usdc.balanceOf(client), WALLET - DEPOSIT);
    }

    function test_deposit_is_relayable_pulls_the_value_and_announces_the_split() public {
        (uint256 validBefore, bytes32 nonce, bytes memory sig) = _depositAuth(jr, 5_000_000);
        address relayer = makeAddr("relayer");
        vm.expectEmit(true, true, false, true, address(jr));
        emit JobRegistry.Deposited(client, relayer, 4_998_000, 2_000);
        vm.prank(relayer); // any relayer: the authorization is the whole authority
        jr.deposit(client, 5_000_000, validBefore, nonce, sig);
        assertEq(jr.balanceOf(client), START + 4_998_000);
        assertEq(jr.relayerEarned(relayer), 2_000); // the fee goes to the deposit's sender
        assertEq(jr.relayerEarned(address(this)), 2_000); // and the harness's deposit's stays put
        assertEq(jr.accrued(), 0);
        assertEq(usdc.balanceOf(address(jr)), DEPOSIT + 5_000_000);
        assertTrue(usdc.authorizationState(client, nonce)); // single-use on the token
    }

    function test_a_deposit_authorization_lands_once() public {
        (uint256 validBefore, bytes32 nonce, bytes memory sig) = _depositAuth(jr, 1_000_000);
        jr.deposit(client, 1_000_000, validBefore, nonce, sig);
        vm.expectRevert(bytes("FiatTokenV2: authorization is used or canceled"));
        jr.deposit(client, 1_000_000, validBefore, nonce, sig);
        assertEq(jr.balanceOf(client), START + 998_000);
    }

    function test_a_deposit_cannot_credit_anyone_but_the_signer() public {
        (uint256 validBefore, bytes32 nonce, bytes memory sig) = _depositAuth(jr, 1_000_000);
        address thief = makeAddr("thief");
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        jr.deposit(thief, 1_000_000, validBefore, nonce, sig);
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        jr.deposit(client, 1_000_001, validBefore, nonce, sig); // nor a different value
        assertEq(jr.balanceOf(thief), 0);
        assertEq(jr.balanceOf(client), START);
    }

    function test_only_the_registry_can_execute_a_deposit_authorization() public {
        (uint256 validBefore, bytes32 nonce, bytes memory sig) = _depositAuth(jr, 1_000_000);
        // the signature is public in deposit's calldata; a stranger replaying it to the token moves nothing
        vm.expectRevert(bytes("FiatTokenV2: caller must be the payee"));
        IUSDC(USDC).receiveWithAuthorization(client, address(jr), 1_000_000, 0, validBefore, nonce, sig);
        jr.deposit(client, 1_000_000, validBefore, nonce, sig); // and the deposit still lands
    }

    function test_an_expired_deposit_authorization_is_refused() public {
        (uint256 validBefore, bytes32 nonce, bytes memory sig) = _depositAuth(jr, 1_000_000);
        vm.warp(validBefore);
        vm.expectRevert(bytes("FiatTokenV2: authorization is expired"));
        jr.deposit(client, 1_000_000, validBefore, nonce, sig);
    }

    function test_a_deposit_must_exceed_the_deposit_fee() public {
        (uint256 validBefore, bytes32 nonce, bytes memory sig) = _depositAuth(jr, 2_000);
        vm.expectRevert(JobRegistry.BadDepositValue.selector);
        jr.deposit(client, 2_000, validBefore, nonce, sig);
        (validBefore, nonce, sig) = _depositAuth(jr, 2_001);
        jr.deposit(client, 2_001, validBefore, nonce, sig); // one atom over: one atom credited
        assertEq(jr.balanceOf(client), START + 1);
        uint256 huge = uint256(type(uint128).max) + 1;
        vm.expectRevert(JobRegistry.BadDepositValue.selector);
        jr.deposit(client, huge, validBefore, nonce, sig);
    }

    function test_a_zero_deposit_fee_credits_the_whole_value() public {
        vm.prank(curation);
        jr.setFees(100, 5, 0);
        _deposit(jr, 1);
        assertEq(jr.balanceOf(client), START + 1);
        assertEq(jr.relayerEarned(address(this)), 2_000); // only the harness's deposit ever paid a fee
    }

    function test_a_contract_wallet_owner_is_refused() public {
        address wallet = address(new AnyOneWallet());
        deal(USDC, wallet, 10_000_000);
        uint256 validBefore = block.timestamp + 3600;
        bytes32 nonce = keccak256("wallet-deposit");
        vm.expectRevert(JobRegistry.OwnerHasCode.selector);
        jr.deposit(wallet, 1_000_000, validBefore, nonce, hex"00");
        assertEq(jr.balanceOf(wallet), 0);
        // the token alone would take it: the refusal is the registry's
        vm.prank(address(jr));
        IUSDC(USDC).receiveWithAuthorization(wallet, address(jr), 1_000_000, 0, validBefore, nonce, hex"00");
        // 23 bytes of code that are not a 7702 designator are refused too
        address odd = makeAddr("odd");
        vm.etch(odd, abi.encodePacked(hex"fe0100", address(wallet)));
        vm.expectRevert(JobRegistry.OwnerHasCode.selector);
        jr.deposit(odd, 1_000_000, validBefore, keccak256("odd"), hex"00");
    }

    function test_a_7702_delegated_owner_deposits_and_withdraws() public {
        uint256 pk = 0x7702;
        address owner = vm.addr(pk);
        vm.etch(owner, abi.encodePacked(hex"ef0100", address(new EcdsaDelegate())));
        assertEq(owner.code.length, 23);
        deal(USDC, owner, 10_000_000);
        uint256 validBefore = block.timestamp + 3600;
        bytes32 nonce = keccak256("7702-deposit");
        bytes memory sig = AuthSig.signDeposit(vm, pk, USDC, address(jr), 5_000_000, validBefore, nonce);
        jr.deposit(owner, 5_000_000, validBefore, nonce, sig);
        assertEq(jr.balanceOf(owner), 5_000_000 - 2_000);
        uint64 t = uint64(block.timestamp);
        jr.withdraw(owner, 5_000_000 - 2_000, t, OpSig.signWithdraw(vm, pk, jr, 5_000_000 - 2_000, t));
        assertEq(jr.balanceOf(owner), 0);
        assertEq(usdc.balanceOf(owner), 10_000_000 - 2_000);
    }

    // ── withdraw ──────────────────────────────────────────────────────────────────────────────

    function test_withdraw_pays_the_owner_and_is_relayable() public {
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signWithdraw(vm, clientPk, jr, 1_000_000, t);
        vm.expectEmit(true, false, false, true, address(jr));
        emit JobRegistry.Withdrawn(client, 1_000_000);
        vm.prank(makeAddr("relayer"));
        jr.withdraw(client, 1_000_000, t, sig);
        assertEq(jr.balanceOf(client), START - 1_000_000);
        assertEq(usdc.balanceOf(client), WALLET - DEPOSIT + 1_000_000);
        assertEq(usdc.balanceOf(makeAddr("relayer")), 0);
    }

    function test_a_withdraw_signature_lands_once() public {
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signWithdraw(vm, clientPk, jr, 1_000, t);
        jr.withdraw(client, 1_000, t, sig);
        vm.expectRevert(JobRegistry.StaleOp.selector); // issuedAt must rise strictly
        jr.withdraw(client, 1_000, t, sig);
        assertEq(jr.balanceOf(client), START - 1_000);
    }

    /// The monotonic floor, not the clock window, is what kills an older signature once a newer
    /// one landed — even while the older one is still fresh.
    function test_a_landed_withdraw_kills_every_older_signature() public {
        uint64 t = uint64(block.timestamp);
        bytes memory older = OpSig.signWithdraw(vm, clientPk, jr, 1_000, t);
        bytes memory newer = OpSig.signWithdraw(vm, clientPk, jr, 2_000, t + 1);
        jr.withdraw(client, 2_000, t + 1, newer);
        vm.expectRevert(JobRegistry.StaleOp.selector);
        jr.withdraw(client, 1_000, t, older);
        vm.warp(block.timestamp + 5);
        uint64 later = uint64(block.timestamp);
        jr.withdraw(client, 1_000, later, OpSig.signWithdraw(vm, clientPk, jr, 1_000, later));
        assertEq(jr.balanceOf(client), START - 3_000);
    }

    function test_withdraw_is_fresh_within_600_seconds() public {
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signWithdraw(vm, clientPk, jr, 1_000, t);
        vm.warp(block.timestamp + 601);
        vm.expectRevert(JobRegistry.StaleOp.selector);
        jr.withdraw(client, 1_000, t, sig);
        uint64 future = uint64(block.timestamp) + 601;
        bytes memory early = OpSig.signWithdraw(vm, clientPk, jr, 1_000, future);
        vm.expectRevert(JobRegistry.StaleOp.selector);
        jr.withdraw(client, 1_000, future, early);
    }

    function test_withdraw_refuses_a_wrong_signer_and_an_edited_amount() public {
        uint64 t = uint64(block.timestamp);
        bytes memory stranger = OpSig.signWithdraw(vm, 0xBAD, jr, 1_000, t);
        vm.expectRevert(JobRegistry.InvalidWithdrawSignature.selector);
        jr.withdraw(client, 1_000, t, stranger);
        bytes memory own = OpSig.signWithdraw(vm, clientPk, jr, 1_000, t);
        vm.expectRevert(JobRegistry.InvalidWithdrawSignature.selector);
        jr.withdraw(client, 1_001, t, own);
        vm.expectRevert(JobRegistry.InvalidWithdrawSignature.selector);
        jr.withdraw(client, 1_000, t, new bytes(65)); // zero recovered signer
        vm.expectRevert(JobRegistry.InvalidWithdrawSignature.selector);
        jr.withdraw(address(0), 1_000, t, new bytes(65)); // and a zero owner never matches it
        assertEq(jr.balanceOf(client), START);
    }

    /// Only the unlocked balance can leave: a claimed job's lock is out of it from the claim on, so
    /// a withdrawal can never leave a claimed job unfunded.
    function test_withdraw_cannot_touch_a_live_lock() public {
        _claim(_ref(0)); // locks 210 + 2 + 5
        uint128 all = uint128(START);
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signWithdraw(vm, clientPk, jr, all, t);
        vm.expectRevert(JobRegistry.InsufficientDeposit.selector);
        jr.withdraw(client, all, t, sig);
        uint128 free = uint128(START - 217);
        jr.withdraw(client, free, t, OpSig.signWithdraw(vm, clientPk, jr, free, t));
        assertEq(jr.balanceOf(client), 0);
        assertEq(usdc.balanceOf(address(jr)), 217 + 2_000); // the lock and the relayer's deposit fee
    }

    function test_a_withdrawal_signed_for_one_registry_is_refused_by_another() public {
        JobRegistry jr2 = new JobRegistry(reg, IUSDC(USDC), curation, treasury);
        vm.prank(curation);
        jr2.setFees(100, 5, 0);
        _deposit(jr2, 1_000_000);
        uint64 t = uint64(block.timestamp);
        bytes memory forJr = OpSig.signWithdraw(vm, clientPk, jr, 1_000, t);
        vm.expectRevert(JobRegistry.InvalidWithdrawSignature.selector);
        jr2.withdraw(client, 1_000, t, forJr);
    }

    // ── payouts ───────────────────────────────────────────────────────────────────────────────

    function test_payProvider_pays_the_earned_total_to_the_operator() public {
        bytes32 a = _claim(_ref(0));
        bytes32 b = _claim(_ref(pid));
        _settle(opPk, a, 1500, bytes("r")); // 165
        _settle(opPk, b, 100, bytes("r")); // 39
        assertEq(jr.earned(pid), 204);
        vm.expectEmit(true, true, false, true, address(jr));
        emit JobRegistry.ProviderPaid(pid, op, 204);
        vm.prank(makeAddr("keeper")); // permissionless
        jr.payProvider(pid);
        assertEq(usdc.balanceOf(op), 204);
        assertEq(jr.earned(pid), 0);
        vm.expectRevert(JobRegistry.NothingToPay.selector);
        jr.payProvider(pid);
    }

    /// Earnings belong to the provider id; the payout goes to the operator key current at payout.
    function test_payProvider_after_an_operator_rotation_pays_the_new_operator() public {
        bytes32 jobId = _claim(_ref(0));
        _settle(opPk, jobId, 1500, bytes("r"));
        address op2 = makeAddr("op2-ledger");
        vm.prank(curation);
        reg.setOperator(pid, op2);
        jr.payProvider(pid);
        assertEq(usdc.balanceOf(op2), 165);
        assertEq(usdc.balanceOf(op), 0);
    }

    function test_payProvider_refuses_an_id_with_nothing_earned() public {
        vm.expectRevert(JobRegistry.NothingToPay.selector);
        jr.payProvider(pid);
        vm.expectRevert(JobRegistry.NothingToPay.selector);
        jr.payProvider(999); // never registered: refused before the registry is asked
    }

    function test_payTreasury_pays_every_accrued_fee_to_the_current_treasury() public {
        bytes32 a = _claim(_ref(0));
        _settle(opPk, a, 1500, bytes("r")); // fee 1; the gas 5 is the relayer's
        bytes32 b = _claim(_refC(keccak256("payTreasury-b")));
        _settle(opPk, b, 2000, bytes("r")); // charge 210, fee 2
        bytes32 c = _claim(_ref(pid));
        _fail(opPk, c); // no fee leg
        assertEq(jr.accrued(), 3);
        assertEq(jr.relayerEarned(address(this)), 2_000 + 15);
        address tre2 = makeAddr("treasury-2");
        vm.prank(curation);
        jr.setTreasury(tre2); // unpaid fees follow the treasury
        vm.expectEmit(true, false, false, true, address(jr));
        emit JobRegistry.TreasuryPaid(tre2, 3);
        vm.prank(makeAddr("keeper"));
        jr.payTreasury();
        assertEq(usdc.balanceOf(tre2), 3);
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(jr.accrued(), 0);
        assertEq(jr.relayerEarned(address(this)), 2_000 + 15); // the treasury's payout is its own
        vm.expectRevert(JobRegistry.NothingToPay.selector);
        jr.payTreasury();
    }

    // ── the relayer's earnings ────────────────────────────────────────────────────────────────

    /// The gas fee belongs to the relayer that landed the CLAIM, recorded in the terms, whoever
    /// lands the exit: settle, fail and reclaim each credit relayer A although B sent them.
    function test_the_claims_relayer_earns_the_gas_fee_whoever_lands_the_exit() public {
        address a = makeAddr("relayer-a");
        address b = makeAddr("relayer-b");
        bytes32 s = _claimVia(jr, _refC(keccak256("via-a-settle")), a);
        bytes32 f = _claimVia(jr, _refC(keccak256("via-a-fail")), a);
        bytes32 r = _claimVia(jr, _refC(keccak256("via-a-reclaim")), a);
        assertEq(termsOf[s].relayer, a);
        assertEq(jr.relayerEarned(a), 0); // earned at the exit, never at the claim

        uint64 t = uint64(block.timestamp);
        Usage memory u = OpSig.usage(1500);
        bytes memory settleSig = OpSig.signSettle(vm, opPk, jr, s, u, t);
        vm.prank(b);
        jr.submitAndSettle(s, termsOf[s], u, bytes("r"), t, settleSig);
        assertEq(jr.relayerEarned(a), 5);

        bytes memory failSig = OpSig.signFail(vm, opPk, jr, f, t);
        vm.prank(b);
        jr.fail(f, termsOf[f], t, failSig);
        assertEq(jr.relayerEarned(a), 10);

        vm.warp(block.timestamp + 3601);
        Terms memory forged = termsOf[r];
        forged.relayer = b; // the exit's sender cannot name itself the claim's relayer
        vm.prank(b);
        vm.expectRevert(JobRegistry.TermsMismatch.selector);
        jr.reclaim(r, forged);
        vm.prank(b);
        jr.reclaim(r, termsOf[r]);
        assertEq(jr.relayerEarned(a), 15);

        assertEq(jr.relayerEarned(b), 0);
        assertEq(jr.relayerEarned(address(this)), 2_000); // the harness's deposit fee, untouched
    }

    function test_payRelayer_pays_the_relayer_itself_and_zeroes_its_earnings() public {
        address a = makeAddr("relayer-a");
        _settle(opPk, _claimVia(jr, _ref(0), a), 1500, bytes("r"));
        (uint256 validBefore, bytes32 nonce, bytes memory sig) = _depositAuth(jr, 1_000_000);
        vm.prank(a);
        jr.deposit(client, 1_000_000, validBefore, nonce, sig);
        assertEq(jr.relayerEarned(a), 5 + 2_000); // a claim's gas fee and a deposit's fee, one book
        uint256 held = usdc.balanceOf(address(jr));
        address keeper = makeAddr("keeper");
        vm.expectEmit(true, false, false, true, address(jr));
        emit JobRegistry.RelayerPaid(a, 2_005);
        vm.prank(keeper); // permissionless, and it pays the relayer, never the caller
        jr.payRelayer(a);
        assertEq(usdc.balanceOf(a), 2_005);
        assertEq(usdc.balanceOf(keeper), 0);
        assertEq(usdc.balanceOf(address(jr)), held - 2_005);
        assertEq(jr.relayerEarned(a), 0);
        assertEq(jr.relayerEarned(address(this)), 2_000); // another relayer's book is its own
        vm.expectRevert(JobRegistry.NothingToPay.selector);
        jr.payRelayer(a);
        vm.expectRevert(JobRegistry.NothingToPay.selector);
        jr.payRelayer(makeAddr("never-relayed"));
    }

    /// The two shapes an indexer decodes: owner and relayer indexed, the split in the data.
    function test_Deposited_indexes_the_owner_and_the_relayer() public {
        (uint256 validBefore, bytes32 nonce, bytes memory sig) = _depositAuth(jr, 1_000_000);
        address relayer = makeAddr("relayer");
        vm.recordLogs();
        vm.prank(relayer);
        jr.deposit(client, 1_000_000, validBefore, nonce, sig);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(jr)) continue;
            seen++;
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[0], keccak256("Deposited(address,address,uint128,uint128)"));
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(client))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(relayer))));
            (uint128 credited, uint128 fee) = abi.decode(logs[i].data, (uint128, uint128));
            assertEq(credited, 998_000);
            assertEq(fee, 2_000);
        }
        assertEq(seen, 1);
    }

    /// A token that signals failure by RETURNING FALSE must not be read as a successful payout,
    /// on any of the four legs that move tokens out.
    function test_a_false_returning_token_reverts_every_outbound_leg() public {
        FalseTransferToken bad = new FalseTransferToken();
        ProviderRegistry reg2 = new ProviderRegistry(curation);
        JobRegistry jr2 = new JobRegistry(reg2, IUSDC(address(bad)), curation, treasury);
        vm.startPrank(curation);
        reg2.setJobRegistry(address(jr2), true);
        reg2.registerModel("model-a:fp8");
        uint32 pid2 = reg2.register(op, 16, true, 1000);
        jr2.setFees(100, 5, 1);
        vm.stopPrank();
        bad.mint(client, 10_000);
        jr2.deposit(client, 10_000, 0, bytes32(0), ""); // the double validates nothing
        bytes32 jobId = _claimOn(jr2, _refC(keccak256("false-token")));
        uint64 t = uint64(block.timestamp);
        jr2.submitAndSettle(
            jobId,
            termsOf[jobId],
            OpSig.usage(1500),
            bytes("r"),
            t,
            OpSig.signSettle(vm, opPk, jr2, jobId, OpSig.usage(1500), t)
        );
        assertGt(jr2.earned(pid2), 0);

        vm.expectRevert(JobRegistry.TransferFailed.selector);
        jr2.payProvider(pid2);
        vm.expectRevert(JobRegistry.TransferFailed.selector);
        jr2.payTreasury();
        vm.expectRevert(JobRegistry.TransferFailed.selector);
        jr2.payRelayer(address(this));
        bytes memory sig = OpSig.signWithdraw(vm, clientPk, jr2, 100, t);
        vm.expectRevert(JobRegistry.TransferFailed.selector);
        jr2.withdraw(client, 100, t, sig);
        // every leg rolled back with its revert
        assertGt(jr2.earned(pid2), 0);
        assertGt(jr2.accrued(), 0);
        assertGt(jr2.relayerEarned(address(this)), 0);
        assertEq(jr2.balanceOf(client), 10_000 - 1 - 217 + (217 - 165 - 1 - 5));
    }
}

/// @notice An ERC-1271 wallet that approves every signature: USDC takes its deposit authorization.
contract AnyOneWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}

/// @notice A 7702 delegate: USDC sees code at the EOA and asks ERC-1271, answered by the EOA's own key.
contract EcdsaDelegate {
    function isValidSignature(bytes32 digest, bytes calldata sig) external view returns (bytes4) {
        (bytes32 r, bytes32 s) = abi.decode(sig[:64], (bytes32, bytes32));
        return ecrecover(digest, uint8(sig[64]), r, s) == address(this) ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}
