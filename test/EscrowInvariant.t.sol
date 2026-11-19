// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {JobRegistry, IUSDC} from "../src/JobRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import "../src/Types.sol";
import {IFiatToken} from "./utils/BaseFork.sol";
import {JobHarness} from "./utils/JobHarness.sol";
import {AuthSig} from "./utils/AuthSig.sol";
import {OpSig} from "./utils/OpSig.sol";
import {OrderSig} from "./utils/OrderSig.sol";

/// @notice R23's net. Every claim locks `cap + feeCap + gasFee` out of the owner's balance and
/// every lock resolves exactly once: split at settle, released at fail and reclaim with the gas fee
/// to the claim's relayer, never taken at all by a cancel. Each exit also hands the provider's
/// capacity slot back. And across any sequence of ops:
///
///   USDC held == Σ balances + Σ live locks + Σ earned + Σ relayerEarned + accrued
contract EscrowInvariantTest is JobHarness {
    /// @dev feeBps 100 — the protocol's real fee — gasFee 5 and depositFee 0: the reference lock is
    /// `cap + feeCap + gasFee == 210 + 2 + 5 == 217`. One test raises `feeBps` to the 1000 ceiling
    /// before its own claim to sweep the fee leg at a rate that cannot floor away.
    function _fees() internal override {
        vm.prank(curation);
        jr.setFees(100, 5, 0);
    }

    function _assertConserved(uint256 liveLocks, string memory why) private view {
        assertEq(
            usdc.balanceOf(address(jr)),
            uint256(jr.balanceOf(client)) + liveLocks + jr.earned(pid) + jr.relayerEarned(address(this)) + jr.accrued(),
            why
        );
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_every_lock_resolves_exactly_once(uint8 exitPath, uint32 tok) public {
        bytes32 jobId = _claim(_ref(0));
        uint256 locked = START - jr.balanceOf(client);
        assertEq(locked, 210 + 2 + 5);
        _assertConserved(locked, "after claim");
        if (exitPath % 3 == 0) {
            _settle(opPk, jobId, tok, bytes("r"));
        } else if (exitPath % 3 == 1) {
            _fail(opPk, jobId);
        } else {
            vm.warp(block.timestamp + 3601);
            _reclaim(jobId);
        }
        _assertConserved(0, "after the exit");
        // every atom of the lock went to exactly one of the four ledgers
        assertEq(
            (jr.balanceOf(client) - (START - locked)) + jr.earned(pid) + jr.relayerEarned(address(this)) + jr.accrued(),
            locked
        );
        assertEq(jr.activeJobs(pid), 0); // R23's other half

        // a second exit of any kind must revert — or, for cancel, no-op — without moving anything
        Terms memory terms = termsOf[jobId];
        uint256 snapshot = jr.balanceOf(client);
        uint64 t = uint64(block.timestamp);
        bytes memory settleSig = _settleSig(opPk, jobId, 1);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.submitAndSettle(jobId, terms, OpSig.usage(1), bytes("r"), t, settleSig);
        bytes memory failSig = _failSig(opPk, jobId);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.fail(jobId, terms, t, failSig);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.reclaim(jobId, terms);
        _cancelAs(clientPk, _ref(0).c);
        assertEq(jr.balanceOf(client), snapshot);
        assertEq(jr.activeJobs(pid), 0);

        // and the books pay out to the last atom: the contract ends holding nothing
        uint256 relayerPaid = _payOutEverything();
        assertEq(usdc.balanceOf(address(jr)), 0);
        assertEq(
            usdc.balanceOf(client) + usdc.balanceOf(op) + usdc.balanceOf(treasury) + relayerPaid,
            WALLET,
            "supply conserved"
        );
    }

    function test_all_four_terminal_paths_release_the_slot_and_leave_no_dust() public {
        bytes32 a = _claim(_refC(keccak256("path-settle")));
        assertEq(jr.activeJobs(pid), 1);
        _assertConserved(217, "a locked");
        _settle(opPk, a, 1500, bytes("r"));
        assertEq(jr.activeJobs(pid), 0, "settle must release the slot");
        _assertConserved(0, "settle must credit the whole lock");

        bytes32 b = _claim(_refC(keccak256("path-fail")));
        uint256 beforeFail = jr.balanceOf(client);
        uint256 relayerBefore = jr.relayerEarned(address(this));
        _fail(opPk, b);
        assertEq(jr.balanceOf(client) - beforeFail, 212, "fail must release cap + feeCap");
        assertEq(jr.relayerEarned(address(this)) - relayerBefore, 5, "fail must pay the relayer the gas fee");
        assertEq(jr.activeJobs(pid), 0, "fail must release the slot");
        _assertConserved(0, "after fail");

        bytes32 c = _claim(_refC(keccak256("path-reclaim")));
        vm.warp(block.timestamp + 3601);
        uint256 beforeReclaim = jr.balanceOf(client);
        relayerBefore = jr.relayerEarned(address(this));
        _reclaim(c);
        assertEq(jr.balanceOf(client) - beforeReclaim, 212, "reclaim must release cap + feeCap");
        assertEq(jr.relayerEarned(address(this)) - relayerBefore, 5, "reclaim must pay the relayer the gas fee");
        assertEq(jr.activeJobs(pid), 0, "reclaim must release the slot");
        _assertConserved(0, "after reclaim");

        // cancel of an unclaimed order: never locked, so it never took a slot to give back either
        uint256 clientBefore = jr.balanceOf(client);
        _cancelAs(clientPk, keccak256("path-cancel"));
        assertEq(jr.activeJobs(pid), 0, "an unclaimed order never took a slot");
        assertEq(jr.balanceOf(client), clientBefore, "cancel moves no funds");
        _assertConserved(0, "after cancel");

        uint256 relayerPaid = _payOutEverything();
        assertEq(usdc.balanceOf(address(jr)), 0);
        assertEq(
            usdc.balanceOf(client) + usdc.balanceOf(op) + usdc.balanceOf(treasury) + relayerPaid,
            WALLET,
            "supply conserved"
        );
    }

    function test_conservation_holds_with_a_fee_on_top_and_a_mid_flight_gas_fee_change() public {
        vm.prank(curation);
        jr.setFees(1000, 5, 0); // 10% on top, set BEFORE the claim
        bytes32 jobId = _claim(_refC(keccak256("fee-leg")));
        uint256 locked = START - jr.balanceOf(client);
        assertEq(locked, 236); // cap 210 + feeCap 21 + gasFee 5
        vm.prank(curation);
        jr.setFees(1000, 999, 0); // the gas fee moves; the claimed one holds
        uint256 afterClaim = jr.balanceOf(client);
        _settle(opPk, jobId, 1500, bytes("r"));
        // charge = 165 ; fee = 165*1000/10000 = 16
        assertEq(jr.earned(pid), 165);
        assertEq(jr.accrued(), 16); // fee 16
        assertEq(jr.relayerEarned(address(this)), 5); // the claimed 5, never the live 999
        assertEq(jr.balanceOf(client) - afterClaim, 50); // 45 + (21 - 16)
        assertEq(165 + 21 + 50, locked);
        _assertConserved(0, "after settle");
    }

    /// @notice The deploy-order hazard: a `ProviderRegistry` whose `setJobRegistry` points at some
    /// OTHER address. Claim still lands — it writes nothing to the registry — but every exit that
    /// prices the outcome goes through `applyReputationDelta`, which is `onlyJobRegistry`:
    /// `submitAndSettle`, `reclaim` always, and `fail` past `FAIL_GRACE`. Inside `FAIL_GRACE` the
    /// unpenalised `fail` is the one way out; past it the lock is stranded until curation authorises
    /// the right registry, which then repairs it.
    function test_a_misdirected_setJobRegistry_strands_the_lock_until_curation_repairs_it() public {
        ProviderRegistry reg2 = new ProviderRegistry(curation);
        JobRegistry jr2 = new JobRegistry(reg2, IUSDC(address(usdc)), curation, treasury);
        vm.startPrank(curation);
        reg2.setJobRegistry(address(jr), true); // the fat-finger: another live JobRegistry
        reg2.registerModel("model-a:fp8");
        uint32 pid2 = reg2.register(op, 16, true, 1000); // capacityRequested 0 ⇒ effectiveCap floors at 1
        jr2.setFees(100, 5, 0);
        vm.stopPrank();
        _deposit(jr2, 1000);

        bytes32 escapable = _claimOn(jr2, _refC(keccak256("miswired-in-grace")));
        assertEq(jr2.balanceOf(client), 1000 - 217);
        uint64 tf = uint64(block.timestamp);
        jr2.fail(escapable, termsOf[escapable], tf, OpSig.signFail(vm, opPk, jr2, escapable, tf));
        assertEq(jr2.balanceOf(client), 1000 - 5); // cap + feeCap came back; the gas fee did not
        assertEq(jr2.activeJobs(pid2), 0);

        uint64 t0 = uint64(block.timestamp);
        bytes32 stuck = _claimOn(jr2, _refC(keccak256("miswired-past-grace")));
        Terms memory terms = termsOf[stuck];

        bytes memory settleSig = OpSig.signSettle(vm, opPk, jr2, stuck, OpSig.usage(100), t0);
        vm.expectRevert(ProviderRegistry.NotJobRegistry.selector);
        jr2.submitAndSettle(stuck, terms, OpSig.usage(100), bytes("r"), t0, settleSig);

        vm.warp(t0 + 301); // past FAIL_GRACE, so the abort prices the miss and therefore writes
        uint64 tg = uint64(block.timestamp);
        bytes memory failSig = OpSig.signFail(vm, opPk, jr2, stuck, tg);
        vm.expectRevert(ProviderRegistry.NotJobRegistry.selector);
        jr2.fail(stuck, terms, tg, failSig);

        vm.expectRevert(JobRegistry.SlaNotExpired.selector);
        jr2.reclaim(stuck, terms);
        vm.warp(t0 + 3601);
        vm.expectRevert(ProviderRegistry.NotJobRegistry.selector);
        jr2.reclaim(stuck, terms);

        uint64 tc = uint64(block.timestamp);
        bytes32 c = keccak256("miswired-past-grace");
        bytes memory cancelSig = OpSig.signCancel(vm, clientPk, jr2, stuck, tc);
        vm.expectRevert(JobRegistry.NotCancellable.selector);
        jr2.cancel(client, c, tc, cancelSig);

        assertEq(jr2.balanceOf(client), 1000 - 5 - 217); // stranded: no reachable transition out
        assertEq(jr2.getJob(stuck).state, 1);
        assertEq(jr2.activeJobs(pid2), 1);

        vm.prank(curation);
        reg2.setJobRegistry(address(jr2), true);
        jr2.reclaim(stuck, terms);
        assertEq(jr2.balanceOf(client), 1000 - 10, "cap + feeCap went back to the client");
        assertEq(jr2.relayerEarned(address(this)), 10, "and both gas fees to the relayer");
        assertEq(jr2.accrued(), 0);
        assertEq(jr2.getJob(stuck).state, 3);
        assertEq(jr2.activeJobs(pid2), 0);
    }

    /// @dev returns what the relayer — this contract — was paid, so the supply check can count it
    function _payOutEverything() private returns (uint256 relayerPaid) {
        if (jr.earned(pid) > 0) jr.payProvider(pid);
        if (jr.accrued() > 0) jr.payTreasury();
        relayerPaid = jr.relayerEarned(address(this));
        if (relayerPaid > 0) jr.payRelayer(address(this));
        uint128 left = jr.balanceOf(client);
        if (left > 0) {
            uint64 t = uint64(block.timestamp);
            jr.withdraw(client, left, t, OpSig.signWithdraw(vm, clientPk, jr, left, t));
        }
    }
}

/// @notice Random sequences of every op, against the conservation identity.
contract LedgerInvariantTest is JobHarness {
    LedgerHandler internal handler;

    function _fees() internal override {
        vm.prank(curation);
        jr.setFees(250, 5, 3);
    }

    function setUp() public override {
        super.setUp();
        // the harness's own deposit was relayed by this contract, so it is one of the relayers
        handler = new LedgerHandler(jr, reg, clientPk, opPk, pid, address(this));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 10
    /// forge-config: default.invariant.depth = 20
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_usdc_held_equals_balances_plus_locks_plus_earned_plus_accrued() public view {
        uint256 relayed;
        for (uint256 i; i < 3; i++) {
            relayed += jr.relayerEarned(handler.relayers(i));
        }
        assertEq(
            usdc.balanceOf(address(jr)),
            uint256(jr.balanceOf(client)) + handler.liveLocks() + jr.earned(pid) + relayed + jr.accrued()
        );
        assertEq(jr.activeJobs(pid), handler.liveCount());
    }
}

contract LedgerHandler is Test {
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    JobRegistry internal jr;
    ProviderRegistry internal reg;
    uint256 internal clientPk;
    uint256 internal opPk;
    uint32 internal pid;
    address internal client;

    uint256 internal seq;
    uint64 internal lastWithdraw;
    uint256 public liveLocks;
    bytes32[] internal live;
    mapping(bytes32 => Terms) internal termsOf;
    mapping(bytes32 => uint256) internal lockOf;
    /// @dev every sender a deposit or claim lands from: the suite, this handler, and an outsider
    address[3] public relayers;

    constructor(JobRegistry jr_, ProviderRegistry reg_, uint256 clientPk_, uint256 opPk_, uint32 pid_, address suite) {
        jr = jr_;
        reg = reg_;
        clientPk = clientPk_;
        opPk = opPk_;
        pid = pid_;
        client = vm.addr(clientPk_);
        relayers = [suite, address(this), makeAddr("outside-relayer")];
    }

    function liveCount() external view returns (uint256) {
        return live.length;
    }

    function deposit(uint256 value, uint8 who) external {
        value = bound(value, jr.depositFee() + 1, 1_000e6);
        uint256 validBefore = block.timestamp + 3600;
        bytes32 nonce = keccak256(abi.encode("handler-deposit", ++seq));
        bytes memory sig = AuthSig.signDeposit(vm, clientPk, USDC, address(jr), value, validBefore, nonce);
        vm.prank(relayers[who % 3]);
        jr.deposit(client, value, validBefore, nonce, sig);
    }

    function claim(uint32 unitsOut, uint128 rateOut, uint8 who) external {
        if (live.length >= reg.effectiveCap(pid)) return;
        Order memory o = Order({
            c: keccak256(abi.encode("handler-order", ++seq)),
            modelId: 1,
            slaSecs: 3600,
            rateIn: 30_000,
            rateOut: uint128(bound(rateOut, 0, 1e6)),
            unitsIn: 1000,
            unitsOut: uint32(bound(unitsOut, 0, 100_000)),
            designated: 0,
            expiresAt: uint64(block.timestamp + 3600),
            taskCid: bytes("bafy-handler")
        });
        uint256 raw = uint256(o.rateIn) * o.unitsIn + uint256(o.rateOut) * o.unitsOut;
        uint256 cap = (raw + 999_999) / 1_000_000;
        if (cap == 0) cap = 1;
        uint256 lock = cap + cap * jr.feeBps() / 10000 + jr.gasFee();
        if (lock > jr.balanceOf(client)) return;
        bytes32 jobId = keccak256(abi.encodePacked(client, o.c));
        uint64 t = uint64(block.timestamp);
        address relayer = relayers[who % 3];
        Terms memory terms = Terms(client, o.rateIn, o.rateOut, o.unitsIn, o.unitsOut, o.slaSecs, jr.gasFee(), relayer);
        bytes memory orderSig = OrderSig.signOrder(vm, clientPk, jr, o);
        bytes memory claimSig = OpSig.signClaim(vm, opPk, jr, jobId, t);
        vm.prank(relayer);
        jr.claim(o, client, orderSig, t, claimSig);
        termsOf[jobId] = terms;
        lockOf[jobId] = lock;
        liveLocks += lock;
        live.push(jobId);
    }

    function settle(uint256 idx, uint32 promptTok, uint32 cachedTok, uint32 completionTok) external {
        if (live.length == 0) return;
        bytes32 jobId = live[idx % live.length];
        if (block.timestamp > uint256(jr.getJob(jobId).claimedAt) + 3600) return; // past its SLA
        Usage memory u = Usage(promptTok, cachedTok, completionTok, uint128(bound(promptTok, 0, 40_000)));
        uint64 t = uint64(block.timestamp);
        jr.submitAndSettle(jobId, termsOf[jobId], u, bytes("r"), t, OpSig.signSettle(vm, opPk, jr, jobId, u, t));
        _resolve(idx % live.length);
    }

    function fail(uint256 idx) external {
        if (live.length == 0) return;
        bytes32 jobId = live[idx % live.length];
        uint64 t = uint64(block.timestamp);
        jr.fail(jobId, termsOf[jobId], t, OpSig.signFail(vm, opPk, jr, jobId, t));
        _resolve(idx % live.length);
    }

    function reclaim(uint256 idx) external {
        if (live.length == 0) return;
        bytes32 jobId = live[idx % live.length];
        uint256 deadline = uint256(jr.getJob(jobId).claimedAt) + 3600;
        if (block.timestamp <= deadline) vm.warp(deadline + 1);
        jr.reclaim(jobId, termsOf[jobId]);
        _resolve(idx % live.length);
    }

    function cancel() external {
        bytes32 c = keccak256(abi.encode("handler-cancel", ++seq));
        uint64 t = uint64(block.timestamp);
        jr.cancel(client, c, t, OpSig.signCancel(vm, clientPk, jr, keccak256(abi.encodePacked(client, c)), t));
    }

    function withdraw(uint128 amount) external {
        uint128 bal = jr.balanceOf(client);
        amount = uint128(bound(amount, 0, bal));
        if (block.timestamp <= lastWithdraw) vm.warp(lastWithdraw + 1);
        uint64 t = uint64(block.timestamp);
        jr.withdraw(client, amount, t, OpSig.signWithdraw(vm, clientPk, jr, amount, t));
        lastWithdraw = t;
    }

    function payProvider() external {
        if (jr.earned(pid) == 0) return;
        jr.payProvider(pid);
    }

    function payTreasury() external {
        if (jr.accrued() == 0) return;
        jr.payTreasury();
    }

    function payRelayer(uint8 who) external {
        address relayer = relayers[who % 3];
        if (jr.relayerEarned(relayer) == 0) return;
        jr.payRelayer(relayer);
    }

    function warp(uint16 secs) external {
        vm.warp(block.timestamp + secs);
    }

    function _resolve(uint256 i) private {
        bytes32 jobId = live[i];
        liveLocks -= lockOf[jobId];
        live[i] = live[live.length - 1];
        live.pop();
    }
}
