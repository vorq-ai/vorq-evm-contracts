// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {JobRegistry, IUSDC} from "../src/JobRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {JobHarness} from "./utils/JobHarness.sol";
import {OpSig} from "./utils/OpSig.sol";
import {FalseTransferToken} from "./utils/TestDoubles.sol";

/// @notice R23's net. Escrow funds exactly once, at claim, for `cap + feeCap + gasFeeSnap`, and resolves
/// exactly once: distributed at settle, split at fail and reclaim into the gas fee snapshot for the
/// treasury and the rest for the owner, never funded at all on
/// a cancel-from-Open. Every one of those four exits must also hand the provider's capacity slot
/// back. No earlier suite can catch a missing `activeJobs` decrement — each one only ever sees its
/// own path — so both halves are asserted here, for all four.
contract EscrowInvariantTest is JobHarness {
    /// @dev feeBps 100 — the protocol's real fee — and gasFee 5, set BEFORE any post, so
    /// `gasFeeSnap` is 5 and the lock below is `cap + feeCap + gasFeeSnap == 210 + 2 + 5`
    /// (feeCap = 210*100/10000, floored). One test raises `feeBps` to the 1000 ceiling before its
    /// own post to sweep the fee leg at a rate that cannot floor away; another raises the gas fee
    /// mid-flight to prove it cannot reach a refund.
    function _fees() internal override {
        vm.prank(curation);
        jr.setFees(100, 5);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_every_funded_lock_resolves_exactly_once(uint8 exitPath, uint32 tok) public {
        (bytes32 jobId,) = postJob(0);
        uint256 clientBefore = usdc.balanceOf(client);
        _claim(jobId);
        uint256 locked = clientBefore - usdc.balanceOf(client);
        assertEq(locked, 210 + 2 + 5); // cap + feeCap (210*100/10000, floored) + gasFeeSnap
        uint256 clientAfterClaim = usdc.balanceOf(client);
        if (exitPath % 3 == 0) {
            _settle(opPk, jobId, tok, bytes("r"));
        } else if (exitPath % 3 == 1) {
            _fail(opPk, jobId);
        } else {
            vm.warp(block.timestamp + 3601);
            jr.reclaim(jobId);
        }
        // conservation: registry drained to zero for this job, and every atom accounted for. The
        // three possible payees are the only accounts a payout leg can name; the submitter (this
        // test contract) is never one of them.
        assertEq(usdc.balanceOf(address(jr)), 0);
        uint256 paid = (usdc.balanceOf(client) - clientAfterClaim) + usdc.balanceOf(op) + usdc.balanceOf(treasury);
        assertEq(paid, locked);
        assertEq(paid, uint256(jr.capOf(jobId)) + 2 + 5); // == cap + feeCap + gasFeeSnap, off the row itself
        assertEq(usdc.balanceOf(address(this)), 0);
        // R23's other half: the claim's increment is released on whichever path was taken
        assertEq(jr.activeJobs(pid), 0);

        // a second exit of any kind must revert — or, for cancel, no-op — without moving funds
        uint256 snapshot = usdc.balanceOf(client);
        uint64 t = uint64(block.timestamp);
        bytes memory settleSig = _settleSig(opPk, jobId, 1);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.submitAndSettle(jobId, 1, bytes("r"), t, settleSig);
        bytes memory failSig = _failSig(opPk, jobId);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.fail(jobId, t, failSig);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.reclaim(jobId);
        _cancelAs(clientPk, jobId); // a terminal row is a silent no-op for cancel, not a revert
        assertEq(usdc.balanceOf(client), snapshot);
        assertEq(usdc.balanceOf(address(jr)), 0);
        assertEq(jr.activeJobs(pid), 0);
    }

    function test_all_four_terminal_paths_release_the_slot_and_leave_no_dust() public {
        // the deterministic companion to the fuzz: all four exits in one sequence, so a missing
        // decrement — or a wrong refund AMOUNT — on ANY of them fails here rather than only on the
        // fuzz branch that happened to pick that path. Each leg captures the client balance across
        // its own exit, so `paid == cap + feeCap + gasFeeSnap` is pinned four times over.
        bytes32 a = _refOrder(keccak256("path-settle"));
        _claim(a);
        assertEq(jr.activeJobs(pid), 1);
        uint256 beforeSettle = usdc.balanceOf(client);
        _settle(opPk, a, 1500, bytes("r"));
        // settle SPLITS the lock three ways, so the identity is the sum over every payee (both are
        // still empty at this point, this being the first exit)
        assertEq(
            (usdc.balanceOf(client) - beforeSettle) + usdc.balanceOf(op) + usdc.balanceOf(treasury),
            uint256(jr.capOf(a)) + 2 + 5,
            "settle must distribute the whole lock"
        );
        assertEq(jr.activeJobs(pid), 0, "settle must release the slot");
        assertEq(usdc.balanceOf(address(jr)), 0, "settle must drain the escrow");

        bytes32 b = _refOrder(keccak256("path-fail"));
        _claim(b);
        assertEq(jr.activeJobs(pid), 1);
        uint256 beforeFail = usdc.balanceOf(client);
        uint256 treasuryBeforeFail = usdc.balanceOf(treasury);
        _fail(opPk, b);
        // fail pays two legs: the gas fee snapshot to the treasury, everything else to the owner
        assertEq(usdc.balanceOf(client) - beforeFail, uint256(jr.capOf(b)) + 2, "fail must refund cap + feeCap");
        assertEq(usdc.balanceOf(treasury) - treasuryBeforeFail, 5, "fail must pay the treasury the gas fee");
        assertEq(jr.activeJobs(pid), 0, "fail must release the slot");
        assertEq(usdc.balanceOf(address(jr)), 0, "fail must drain the escrow");

        bytes32 c = _refOrder(keccak256("path-reclaim"));
        _claim(c);
        assertEq(jr.activeJobs(pid), 1);
        vm.warp(block.timestamp + 3601);
        uint256 beforeReclaim = usdc.balanceOf(client);
        uint256 treasuryBeforeReclaim = usdc.balanceOf(treasury);
        jr.reclaim(c);
        assertEq(usdc.balanceOf(client) - beforeReclaim, uint256(jr.capOf(c)) + 2, "reclaim must refund cap + feeCap");
        assertEq(usdc.balanceOf(treasury) - treasuryBeforeReclaim, 5, "reclaim must pay the treasury the gas fee");
        assertEq(jr.activeJobs(pid), 0, "reclaim must release the slot");
        assertEq(usdc.balanceOf(address(jr)), 0, "reclaim must drain the escrow");

        // cancel-from-Open: never funded, so it never took a slot to give back either
        bytes32 d = _refOrder(keccak256("path-cancel"));
        uint256 clientBefore = usdc.balanceOf(client);
        assertEq(jr.activeJobs(pid), 0);
        _cancelAs(clientPk, d);
        assertEq(jr.activeJobs(pid), 0, "an unclaimed job never took a slot");
        assertEq(usdc.balanceOf(address(jr)), 0);
        assertEq(usdc.balanceOf(client), clientBefore, "cancel moves no funds");
        assertEq(jr.capOf(d), 0, "`cap` is written by claim, and claim never ran");

        // and across the whole sweep no atom was created or destroyed: the client was the only
        // account ever minted to, and the registry holds nothing
        assertEq(
            usdc.balanceOf(client) + usdc.balanceOf(op) + usdc.balanceOf(treasury), 1e24, "supply is conserved too"
        );
    }

    function test_reclaim_refunds_cap_plus_fee_cap_and_pays_the_treasury_the_gasFee_snapshot() public {
        bytes32 jobId = _refOrder(keccak256("reclaim-money"));
        _claim(jobId);
        // a NEW gas fee may not reach the treasury leg: the escrow's size was fixed at post and
        // reclaim pays out exactly the snapshot, the rest to the owner. feeBps stays at the suite's
        // 100 — conservation only holds while it is unchanged between the claim and the terminal call.
        vm.prank(curation);
        jr.setFees(100, 999);
        uint256 clientBefore = usdc.balanceOf(client);
        vm.warp(block.timestamp + 3601);
        jr.reclaim(jobId);
        assertEq(usdc.balanceOf(client) - clientBefore, uint256(jr.capOf(jobId)) + 2);
        assertEq(usdc.balanceOf(op), 0); // the provider that missed the SLA earns nothing
        assertEq(usdc.balanceOf(treasury), 5); // no fee leg; the gas fee SNAPSHOT, never the live 999
        assertEq(usdc.balanceOf(address(this)), 0); // whoever lands a permissionless op is not a payee
        assertEq(usdc.balanceOf(address(jr)), 0);
        assertEq(jr.activeJobs(pid), 0);
    }

    function test_conservation_holds_with_a_fee_on_top_and_a_mid_flight_gas_fee_change() public {
        vm.prank(curation);
        jr.setFees(1000, 5); // 10% on top, set BEFORE the post
        bytes32 jobId = _refOrder(keccak256("fee-leg"));
        uint256 clientBefore = usdc.balanceOf(client);
        _claim(jobId);
        uint256 locked = clientBefore - usdc.balanceOf(client);
        assertEq(locked, 236); // cap 210 + feeCap 21 + gasFeeSnap 5
        vm.prank(curation);
        jr.setFees(1000, 999); // the gas fee moves; the snapshot holds
        uint256 clientAfterClaim = usdc.balanceOf(client);
        _settle(opPk, jobId, 1500, bytes("r"));
        // charge = 165 ; fee = 165*1000/10000 = 16
        assertEq(usdc.balanceOf(op), 165);
        assertEq(usdc.balanceOf(treasury), 21); // fee 16 + gasFeeSnap 5, never the live 999
        assertEq(usdc.balanceOf(client) - clientAfterClaim, 50); // 45 + (21 - 16)
        assertEq(165 + 21 + 50, locked);
        assertEq(usdc.balanceOf(address(jr)), 0);
        assertEq(jr.activeJobs(pid), 0);
    }

    function test_every_penalty_path_applies_reputation_before_the_untrusted_transfer() public {
        // R25, for all three paths that move reputation. `ProviderRegistry.effectiveCap` reads
        // reputation, so a reentrant payment token must never observe pre-penalty capacity — one
        // extra claimable slot at the boundary. The ordering is observable: `jr2` is not `reg`'s
        // registered JobRegistry, so its reputation call answers NotJobRegistry, while the token
        // refuses every payout by returning false. Exactly one of the two can be the revert, so the
        // answer pins the order: reputation-first ⇒ NotJobRegistry, transfer-first ⇒ TransferFailed.
        FalseTransferToken bad = new FalseTransferToken();
        JobRegistry jr2 = new JobRegistry(reg, IUSDC(address(bad)), curation, treasury);
        vm.prank(curation);
        jr2.setFees(100, 5); // the suite's own fees: three locks of 217, inside the 1000 minted below
        bad.mint(client, 1000);
        bytes32 s = _claimOn(jr2, address(bad), keccak256("r25-settle"));
        bytes32 f = _claimOn(jr2, address(bad), keccak256("r25-fail"));
        bytes32 r = _claimOn(jr2, address(bad), keccak256("r25-reclaim"));

        uint64 t = uint64(block.timestamp);
        bytes memory settleSig = OpSig.signSettle(vm, opPk, jr2, s, 100, t);
        vm.expectRevert(ProviderRegistry.NotJobRegistry.selector);
        jr2.submitAndSettle(s, 100, bytes("r"), t, settleSig); // the +5 reward

        vm.warp(block.timestamp + 301); // past FAIL_GRACE, so the abort actually prices
        uint64 tFail = uint64(block.timestamp);
        bytes memory failSig = OpSig.signFail(vm, opPk, jr2, f, tFail);
        vm.expectRevert(ProviderRegistry.NotJobRegistry.selector);
        jr2.fail(f, tFail, failSig); // the -40 penalty

        vm.warp(block.timestamp + 3601); // past the SLA
        vm.expectRevert(ProviderRegistry.NotJobRegistry.selector);
        jr2.reclaim(r); // the -40 penalty again, on the unsigned path
    }

    /// @notice The deploy-order hazard this suite's whole identity rests on NOT happening: a
    /// `ProviderRegistry` whose `setJobRegistry` was pointed at some OTHER address. Escrow still
    /// FUNDS at claim — nothing on that path writes to the registry — but every path that RESOLVES
    /// it and PRICES the outcome goes through `applyReputationDelta`, which is `onlyJobRegistry`:
    /// `submitAndSettle`, and any refund carrying `penalise: true` (`reclaim` always, `fail` past
    /// `FAIL_GRACE`). Inside `FAIL_GRACE` one exit survives, the unpenalised `fail`; past it the
    /// lock is stranded until curation authorises the right registry. Neither contract has a
    /// sweep, an admin withdrawal or an owner path, so that authorisation is the only way out —
    /// "resolves exactly once" is a property of a CORRECTLY WIRED pair and of nothing else.
    /// `setJobRegistry` is a repeatable, revocable boolean map (`isJobRegistry`) — see
    /// ProviderRegistry.sol:101. Revocation and mis-authorisation both strand escrow;
    /// re-authorisation repairs either.
    /// @dev Distinct from `test_every_penalty_path_applies_reputation_before_the_untrusted_transfer`
    /// above: that one mis-wires in order to observe ORDERING inside a payout that reverts anyway,
    /// under a token that refuses every transfer. This one runs the real token, so the stranded
    /// balance is observable, and it pins the STRANDING and its repair rather than the ordering.
    function test_a_misdirected_setJobRegistry_strands_the_lock_until_curation_repairs_it() public {
        ProviderRegistry reg2 = new ProviderRegistry(curation);
        JobRegistry jr2 = new JobRegistry(reg2, IUSDC(address(usdc)), curation, treasury);
        vm.startPrank(curation);
        // the fat-finger: some other live JobRegistry — a previous deployment's — not this pair's own
        reg2.setJobRegistry(address(jr), true);
        reg2.registerModel("model-a:fp8"); // modelId 1
        uint32 pid2 = reg2.register(op, 16, true, 1000); // capacityRequested 0 ⇒ effectiveCap floors at 1
        jr2.setFees(100, 5); // the same 210 + 2 + 5 lock every other test here asserts
        vm.stopPrank();

        // Inside grace the pair still works end to end: post, claim, and the ONE exit that never
        // touches the registry — `fail` with `penalise: false`. This half is also what proves the
        // reverts below are the mis-wiring, and not a second fixture that was simply born broken.
        uint256 clientStart = usdc.balanceOf(client);
        bytes32 escapable = _claimOn(jr2, address(usdc), keccak256("miswired-in-grace"));
        assertEq(usdc.balanceOf(address(jr2)), 217);
        uint64 tf = uint64(block.timestamp);
        jr2.fail(escapable, tf, OpSig.signFail(vm, opPk, jr2, escapable, tf));
        assertEq(usdc.balanceOf(address(jr2)), 0);
        assertEq(usdc.balanceOf(client), clientStart - 5); // cap + feeCap came back; the gas fee did not
        assertEq(jr2.activeJobs(pid2), 0); // and the slot with it, so the next claim fits a cap of 1

        // The same pair, one job later, is a trap.
        uint64 t0 = uint64(block.timestamp);
        bytes32 stuck = _claimOn(jr2, address(usdc), keccak256("miswired-past-grace"));
        assertEq(usdc.balanceOf(address(jr2)), 217); // claim funded it: no registry write on that path

        // settle never had a chance — the +5 reward is a registry write, grace or no grace
        bytes memory settleSig = OpSig.signSettle(vm, opPk, jr2, stuck, 100, t0);
        vm.expectRevert(ProviderRegistry.NotJobRegistry.selector);
        jr2.submitAndSettle(stuck, 100, bytes("r"), t0, settleSig);

        vm.warp(t0 + 301); // past FAIL_GRACE, so the abort prices the miss and therefore writes
        uint64 tg = uint64(block.timestamp);
        bytes memory failSig = OpSig.signFail(vm, opPk, jr2, stuck, tg);
        vm.expectRevert(ProviderRegistry.NotJobRegistry.selector);
        jr2.fail(stuck, tg, failSig); // the one escape hatch has closed behind this job

        vm.expectRevert(JobRegistry.SlaNotExpired.selector);
        jr2.reclaim(stuck); // and the client's exit has not opened yet
        vm.warp(t0 + 3601);
        vm.expectRevert(ProviderRegistry.NotJobRegistry.selector);
        jr2.reclaim(stuck); // when it does, it lands on that very same -40

        // the owner's own exit was never open on a Claimed row
        uint64 tc = uint64(block.timestamp);
        bytes memory cancelSig = OpSig.signCancel(vm, clientPk, jr2, stuck, tc);
        vm.expectRevert(JobRegistry.NotCancellable.selector);
        jr2.cancel(stuck, tc, cancelSig);

        assertEq(usdc.balanceOf(address(jr2)), 217); // stranded: no reachable transition out
        assertEq(jr2.getJob(stuck).state, 1); // still Claimed
        assertEq(jr2.activeJobs(pid2), 1); // the provider's capacity slot is stranded alongside it

        // And this is where the allowlist earns itself. Under a write-once pointer the paragraph
        // above was the end of the story — the lock was unresolvable forever. Curation can now
        // authorize the registry that should have been wired, and the transition that was
        // unreachable a moment ago lands on the very same job.
        vm.prank(curation);
        reg2.setJobRegistry(address(jr2), true);

        jr2.reclaim(stuck);

        assertEq(usdc.balanceOf(address(jr2)), 0, "the stranded lock resolved");
        // two exits on this pair, the in-grace fail above and this reclaim, each kept its 5-unit gas fee
        assertEq(usdc.balanceOf(client), clientStart - 10, "and cap + feeCap went back to the client");
        assertEq(usdc.balanceOf(treasury), 10, "and the gas fees to the treasury");
        assertEq(jr2.getJob(stuck).state, 3); // Cancelled — reclaim's terminal
        assertEq(jr2.activeJobs(pid2), 0); // the capacity slot came back with it
    }

    /// @dev the reference order under a fresh commitment, so one test can fund several locks.
    /// `postJob` derives its `c` from `designated` and therefore gives only one job per value.
    /// The amount is the claim-time pull at the fees live NOW, so the one test that raises `feeBps`
    /// before posting signs its fee ceiling too.
    function _refOrder(bytes32 c) private returns (bytes32) {
        uint256 amount = REF_CAP + REF_CAP * uint256(jr.feeBps()) / 10000 + uint256(jr.gasFee());
        return postJobWith(c, REF_RATE_IN, REF_UNITS_IN, REF_RATE_OUT, REF_UNITS_OUT, amount);
    }

    /// @dev post + claim against a foreign registry instance, in its own frame for the R19 stack
    /// wall. `_postTo` reads the TARGET's own fees, so each caller's `setFees` is what the
    /// authorization signs: `REF_CAP` plus that instance's fee ceiling plus its gas fee.
    function _claimOn(JobRegistry target, address payToken, bytes32 c) private returns (bytes32 jobId) {
        jobId = _postTo(target, payToken, c);
        uint64 t = uint64(block.timestamp);
        target.claim(jobId, t, OpSig.signClaim(vm, opPk, target, jobId, t));
    }
}
