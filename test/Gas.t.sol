// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {JobRegistry} from "../src/JobRegistry.sol";
import "../src/Types.sol";
import {JobHarness} from "./utils/JobHarness.sol";
import {AuthSig} from "./utils/AuthSig.sol";
import {OpSig} from "./utils/OpSig.sol";
import {OrderSig} from "./utils/OrderSig.sol";

/// @notice One named gas measurement per relayed op, at the constructor's fees, in the steady
/// state a live network is in: the client already holds a balance, the provider has earned before,
/// the treasury has accrued before, the relayer (this contract) has earned before, and all three
/// payees already hold USDC.
///
/// `snapshots/JobRegistryGas.json` gets two numbers per op:
///   - `<op>`: the execution gas of the call frame (`snapshotGasLastCall`), every touched account
///     and slot cold (`vm.cool`), as in a fresh transaction;
///   - `<op>.tx`: that plus the 21,000 intrinsic gas and the calldata gas (4 per zero byte, 16 per
///     non-zero byte), less the refund capped at a fifth — an estimate of the receipt's gasUsed.
///     The L1 data fee is not gas and is not in either number.
contract GasTest is JobHarness {
    /// @dev a CIDv1 in base32 is 59 characters, the length the coordinator's storage mints
    bytes internal constant CID = "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku";
    /// @dev the FiatToken proxy's implementation slot (zeppelinos), so the implementation's account
    /// can be cooled alongside the proxy
    bytes32 internal constant IMPL_SLOT = 0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3;

    function setUp() public override {
        super.setUp();
        // steady state: a settled job behind every ledger, then payees that already hold USDC
        _settle(opPk, _claim(_gasOrder("prime-1")), 1500, CID);
        jr.payProvider(pid);
        jr.payTreasury();
        jr.payRelayer(address(this));
        _settle(opPk, _claim(_gasOrder("prime-2")), 1500, CID);
        vm.warp(block.timestamp + 1);
    }

    function _gasOrder(string memory tag) internal view returns (Order memory o) {
        o = _refC(keccak256(bytes(tag)));
        o.designated = pid;
        o.taskCid = CID;
    }

    function _cool() internal {
        vm.cool(address(jr));
        vm.cool(address(reg));
        vm.cool(USDC);
        vm.cool(address(uint160(uint256(vm.load(USDC, IMPL_SLOT)))));
        vm.cool(client);
        vm.cool(op);
        vm.cool(treasury);
        vm.cool(address(this));
    }

    function _measure(string memory name, bytes memory data) internal {
        _cool();
        (bool ok, bytes memory ret) = address(jr).call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        uint256 exec = vm.snapshotGasLastCall("JobRegistryGas", name);
        int64 refunded = vm.lastCallGas().gasRefunded;
        uint256 calldataGas;
        for (uint256 i; i < data.length; i++) {
            calldataGas += data[i] == 0 ? 4 : 16;
        }
        uint256 gross = 21_000 + calldataGas + exec;
        uint256 refund = refunded > 0 ? uint256(uint64(refunded)) : 0;
        if (refund > gross / 5) refund = gross / 5;
        vm.snapshotValue("JobRegistryGas", string.concat(name, ".tx"), gross - refund);
    }

    function test_gas_claim() public {
        Order memory o = _gasOrder("claim");
        bytes32 jobId = _jobId(o);
        uint64 t = uint64(block.timestamp);
        bytes memory os = OrderSig.signOrder(vm, clientPk, jr, o);
        bytes memory cs = OpSig.signClaim(vm, opPk, jr, jobId, t);
        _measure("claim", abi.encodeCall(JobRegistry.claim, (o, client, os, t, cs)));
        assertEq(jr.getJob(jobId).state, 1);
    }

    function test_gas_settle() public {
        bytes32 jobId = _claim(_gasOrder("settle"));
        Usage memory u = Usage({promptTok: 900, cachedTok: 300, completionTok: 1500, rateInCached: 3_000});
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signSettle(vm, opPk, jr, jobId, u, t);
        _measure("settle", abi.encodeCall(JobRegistry.submitAndSettle, (jobId, termsOf[jobId], u, CID, t, sig)));
        assertEq(jr.getJob(jobId).state, 2);
    }

    function test_gas_fail() public {
        bytes32 jobId = _claim(_gasOrder("fail"));
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signFail(vm, opPk, jr, jobId, t);
        _measure("fail", abi.encodeCall(JobRegistry.fail, (jobId, termsOf[jobId], t, sig)));
        assertEq(jr.getJob(jobId).endedBecause, 3);
    }

    function test_gas_reclaim() public {
        bytes32 jobId = _claim(_gasOrder("reclaim"));
        vm.warp(block.timestamp + 3601);
        _measure("reclaim", abi.encodeCall(JobRegistry.reclaim, (jobId, termsOf[jobId])));
        assertEq(jr.getJob(jobId).endedBecause, 4);
    }

    function test_gas_cancel() public {
        bytes32 c = keccak256("cancel");
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signCancel(vm, clientPk, jr, keccak256(abi.encodePacked(client, c)), t);
        _measure("cancel", abi.encodeCall(JobRegistry.cancel, (client, c, t, sig)));
    }

    function test_gas_deposit_top_up() public {
        (uint256 validBefore, bytes32 nonce, bytes memory sig) = _depositAuth(jr, 5_000_000);
        _measure("deposit.topUp", abi.encodeCall(JobRegistry.deposit, (client, 5_000_000, validBefore, nonce, sig)));
    }

    /// A first deposit: the owner's account slot goes from zero to non-zero.
    function test_gas_deposit_from_zero() public {
        uint256 pk = 0xF1257;
        address fresh = vm.addr(pk);
        deal(USDC, fresh, 10_000_000);
        uint256 validBefore = block.timestamp + 3600;
        bytes32 nonce = keccak256("first-deposit");
        bytes memory sig = AuthSig.signDeposit(vm, pk, USDC, address(jr), 5_000_000, validBefore, nonce);
        vm.cool(fresh);
        _measure("deposit.fromZero", abi.encodeCall(JobRegistry.deposit, (fresh, 5_000_000, validBefore, nonce, sig)));
        assertEq(jr.balanceOf(fresh), 5_000_000 - 2_000);
    }

    function test_gas_withdraw() public {
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signWithdraw(vm, clientPk, jr, 1_000_000, t);
        _measure("withdraw", abi.encodeCall(JobRegistry.withdraw, (client, 1_000_000, t, sig)));
    }

    function test_gas_payProvider() public {
        _measure("payProvider", abi.encodeCall(JobRegistry.payProvider, (pid)));
        assertEq(jr.earned(pid), 0);
    }

    function test_gas_payTreasury() public {
        _measure("payTreasury", abi.encodeCall(JobRegistry.payTreasury, ()));
        assertEq(jr.accrued(), 0);
    }

    function test_gas_payRelayer() public {
        _measure("payRelayer", abi.encodeCall(JobRegistry.payRelayer, (address(this))));
        assertEq(jr.relayerEarned(address(this)), 0);
    }
}
