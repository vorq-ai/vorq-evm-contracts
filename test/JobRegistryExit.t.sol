// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {JobRegistry, IUSDC} from "../src/JobRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import "../src/Types.sol";
import {JobHarness} from "./utils/JobHarness.sol";
import {OpSig} from "./utils/OpSig.sol";
import {OrderSig} from "./utils/OrderSig.sol";

/// @notice The two exits that close the job state machine: the permissionless, UNSIGNED `reclaim`
/// anybody may land once a claimed job blows its SLA, and the owner-signed `cancel` that ends an
/// order nobody claimed.
/// @dev feeBps 100 — the protocol's real fee — gasFee 0 and depositFee 0, so the reference order
/// locks `cap + feeCap == REF_LOCK` and both exits here hand the whole of it back.
/// `EscrowInvariant.t.sol` runs under a nonzero `gasFee`, so the gas fee leg is pinned there.
contract JobRegistryExitTest is JobHarness {
    /// @dev cap 210 + feeCap 210*100/10000 = 2, gas fee 0
    uint256 internal constant REF_LOCK = REF_CAP + 2;

    function _fees() internal override {
        vm.prank(curation);
        jr.setFees(100, 0, 0);
    }

    // ── reclaim: the SLA deadline, from the other side ─────────────────────────────────────────

    function test_reclaim_after_deadline_is_permissionless_and_penalises() public {
        bytes32 jobId = _claim(_ref(0));
        Terms memory terms = termsOf[jobId];
        vm.expectRevert(JobRegistry.SlaNotExpired.selector);
        jr.reclaim(jobId, terms);
        vm.warp(block.timestamp + 3601);
        uint16 repBefore = reg.reputationOf(pid);
        jr.reclaim(jobId, terms); // no signature, any caller — the one unsigned job op, by design
        assertEq(jr.balanceOf(client), START);
        assertEq(reg.reputationOf(pid), repBefore - 40);
        assertEq(jr.activeJobs(pid), 0);
        assertEq(jr.getJob(jobId).endedBecause, 4);
    }

    function test_the_sla_deadline_is_the_handoff_from_settle_to_reclaim() public {
        bytes32 a = _claim(_ref(0));
        bytes32 b = _claim(_refC(keccak256("handoff")));
        uint256 deadline = uint256(jr.getJob(a).claimedAt) + 3600;
        // EXACTLY on the deadline the provider still owns the job
        vm.warp(deadline);
        Terms memory ta = termsOf[a];
        vm.expectRevert(JobRegistry.SlaNotExpired.selector);
        jr.reclaim(a, ta);
        _settle(opPk, a, 100, bytes("r")); // …and can still settle, on that final second
        // one second later the two permissions have swapped places
        vm.warp(deadline + 1);
        bytes memory lateSig = _settleSig(opPk, b, 100);
        Terms memory tb = termsOf[b];
        vm.expectRevert(JobRegistry.SlaExpired.selector);
        jr.submitAndSettle(b, tb, OpSig.usage(100), bytes("r"), uint64(block.timestamp), lateSig);
        _reclaim(b);
        assertEq(jr.getJob(b).endedBecause, 4);
    }

    function test_reclaim_lands_from_any_sender_and_reads_no_msg_sender() public {
        bytes32 jobId = _claim(_ref(0));
        Terms memory terms = termsOf[jobId];
        vm.warp(block.timestamp + 3601);
        address stranger = makeAddr("stranger");
        uint256 clientBefore = jr.balanceOf(client);
        vm.prank(stranger);
        jr.reclaim(jobId, terms);
        assertEq(jr.balanceOf(stranger), 0); // the caller is never credited…
        assertEq(jr.balanceOf(client) - clientBefore, REF_LOCK); // …the OWNER is, for the whole lock
        assertEq(jr.getJob(jobId).state, 3);
    }

    function test_reclaim_refuses_anything_that_is_not_claimed() public {
        Terms memory none;
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.reclaim(keccak256("no-such-job"), none);
        // an order that was never claimed has no row, so there is nothing to release however long
        // it has been
        Order memory o = _ref(0);
        Terms memory terms = _termsFor(jr, o);
        vm.warp(block.timestamp + 999_999);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.reclaim(_jobId(o), terms);
    }

    function test_reclaim_refuses_terms_other_than_the_claimed_ones() public {
        bytes32 jobId = _claim(_ref(0));
        vm.warp(block.timestamp + 3601);
        Terms memory bad = termsOf[jobId];
        bad.owner = makeAddr("thief"); // a stranger cannot redirect the refund
        vm.expectRevert(JobRegistry.TermsMismatch.selector);
        jr.reclaim(jobId, bad);
        bad = termsOf[jobId];
        bad.slaSecs = 7200; // nor move the deadline
        vm.expectRevert(JobRegistry.TermsMismatch.selector);
        jr.reclaim(jobId, bad);
        assertEq(jr.balanceOf(makeAddr("thief")), 0);
        assertEq(jr.getJob(jobId).state, 1);
    }

    function test_a_reclaimed_row_is_terminal_for_every_other_exit() public {
        Order memory o = _ref(0);
        bytes32 jobId = _claim(o);
        Terms memory terms = termsOf[jobId];
        vm.warp(block.timestamp + 3601);
        jr.reclaim(jobId, terms);
        assertEq(jr.balanceOf(client), START); // released exactly once
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.reclaim(jobId, terms);
        bytes memory settleSig = _settleSig(opPk, jobId, 100);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.submitAndSettle(jobId, terms, OpSig.usage(100), bytes("r"), uint64(block.timestamp), settleSig);
        bytes memory failSig = _failSig(opPk, jobId);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.fail(jobId, terms, uint64(block.timestamp), failSig);
        _cancelAs(clientPk, o.c); // Cancelled is terminal for cancel too: a silent no-op
        assertEq(jr.balanceOf(client), START);
        assertEq(jr.getJob(jobId).endedBecause, 4); // and cause 4 is not overwritten with 2
        assertEq(jr.activeJobs(pid), 0);
    }

    function test_after_the_sla_reclaim_and_fail_race_for_the_same_money() public {
        bytes32 a = _claim(_ref(0));
        bytes32 b = _claim(_refC(keccak256("race")));
        vm.warp(block.timestamp + 3601); // `fail` is NOT SLA-bounded, so both exits are open now
        uint256 clientBefore = jr.balanceOf(client);
        _fail(opPk, a); // the provider gets there first: cause 3
        _reclaim(b); // nobody does: cause 4
        assertEq(jr.getJob(a).endedBecause, 3);
        assertEq(jr.getJob(b).endedBecause, 4);
        // the refund is identical either way, and so is the -40 — only the logged cause differs
        assertEq(jr.balanceOf(client) - clientBefore, 2 * REF_LOCK);
        assertEq(reg.reputationOf(pid), 920); // 1000 - 40 - 40
        Terms memory ta = termsOf[a];
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.reclaim(a, ta); // the loser of each race answers NotClaimed
        bytes memory failSig = _failSig(opPk, b);
        Terms memory tb = termsOf[b];
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.fail(b, tb, uint64(block.timestamp), failSig);
    }

    function test_reclaim_penalty_respects_the_reputation_floor() public {
        vm.prank(curation);
        reg.setReputation(pid, 130);
        bytes32 jobId = _claim(_ref(0));
        vm.warp(block.timestamp + 3601);
        vm.expectEmit(true, false, false, true);
        emit ProviderRegistry.ReputationChanged(pid, 100);
        _reclaim(jobId);
        assertEq(reg.reputationOf(pid), 100);
    }

    function test_reclaim_emits_Ended_with_cause_four_and_moves_no_token() public {
        bytes32 jobId = _claim(_ref(0));
        vm.warp(block.timestamp + 3601);
        vm.recordLogs();
        _reclaim(jobId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 endedCount;
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(usdc), "reclaim must not touch the token");
            if (logs[i].emitter != address(jr)) continue;
            assertTrue(logs[i].topics[0] != JobRegistry.Settled.selector, "reclaim must not emit Settled");
            if (logs[i].topics[0] != JobRegistry.Ended.selector) continue;
            endedCount++;
            assertEq(logs[i].topics[1], jobId);
            assertEq(abi.decode(logs[i].data, (uint8)), 4);
        }
        assertEq(endedCount, 1);
    }

    // ── cancel: an order nobody claimed ───────────────────────────────────────────────────────

    /// The owner cancels an order before any provider claimed it: a Cancelled row is written, and
    /// that id can never be claimed afterwards.
    function test_cancel_of_an_unclaimed_order_writes_a_cancelled_row_and_refuses_its_claim() public {
        Order memory o = _ref(0);
        bytes32 jobId = _jobId(o);
        assertFalse(jr.getJob(jobId).found);
        vm.expectEmit(true, false, false, true, address(jr));
        emit JobRegistry.Ended(jobId, 2);
        _cancelAs(clientPk, o.c);
        JobView memory v = jr.getJob(jobId);
        assertTrue(v.found);
        assertEq(v.state, 3);
        assertEq(v.endedBecause, 2);
        assertEq(v.providerId, 0);
        assertEq(v.claimedAt, 0);

        uint64 t = uint64(block.timestamp);
        (bytes memory os, bytes memory cs) = _claimSigs(o);
        vm.expectRevert(JobRegistry.NotOpen.selector);
        jr.claim(o, client, os, t, cs);
        assertEq(jr.balanceOf(client), START); // nothing was ever locked
        assertEq(jr.activeJobs(pid), 0);
    }

    function test_cancel_moves_no_funds_and_emits_only_Ended() public {
        Order memory o = _ref(0);
        uint256 held = usdc.balanceOf(address(jr));
        vm.recordLogs();
        _cancelAs(clientPk, o.c);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(jr));
        assertEq(logs[0].topics[0], JobRegistry.Ended.selector);
        assertEq(jr.balanceOf(client), START);
        assertEq(usdc.balanceOf(address(jr)), held);
    }

    function test_cancel_is_owner_only_and_idempotent_on_a_terminal_row() public {
        Order memory o = _ref(0);
        bytes memory strangerSig = _cancelSig(0xBAD, o.c);
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(client, o.c, uint64(block.timestamp), strangerSig);
        _cancelAs(clientPk, o.c);
        vm.recordLogs();
        _cancelAs(clientPk, o.c); // terminal → silent no-op, no log
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(jr.getJob(_jobId(o)).endedBecause, 2);
    }

    function test_a_claimed_order_is_NotCancellable_even_after_its_sla_expires() public {
        Order memory o = _ref(0);
        bytes32 jobId = _claim(o);
        vm.warp(block.timestamp + 3601);
        bytes memory sig = _cancelSig(clientPk, o.c);
        vm.expectRevert(JobRegistry.NotCancellable.selector);
        jr.cancel(client, o.c, uint64(block.timestamp), sig);
        assertEq(START - jr.balanceOf(client), REF_LOCK); // lock untouched…
        assertEq(jr.activeJobs(pid), 1); // …and the slot still held
        _reclaim(jobId); // the exit that DOES apply here
        assertEq(jr.activeJobs(pid), 0);
    }

    function test_cancel_of_a_settled_job_is_a_silent_no_op() public {
        Order memory o = _ref(0);
        bytes32 jobId = _claim(o);
        _settle(opPk, jobId, 100, bytes("r"));
        uint256 clientBefore = jr.balanceOf(client);
        vm.recordLogs();
        _cancelAs(clientPk, o.c);
        assertEq(vm.getRecordedLogs().length, 0);
        JobView memory v = jr.getJob(jobId);
        assertEq(v.state, 2);
        assertEq(v.endedBecause, 1); // cause 1 is NOT overwritten with 2
        assertEq(jr.balanceOf(client), clientBefore);
    }

    /// The id is derived from the `owner` argument, so a stranger can only ever name their own
    /// orders: signing for the client's id fails, and naming themselves reaches a different id.
    function test_a_stranger_can_neither_cancel_nor_probe_someone_elses_order() public {
        Order memory o = _ref(0);
        bytes32 jobId = _claim(o);
        uint256 strangerPk = 0xBAD;
        address stranger = vm.addr(strangerPk);
        bytes memory onClaimed = _cancelSig(strangerPk, o.c);
        vm.expectRevert(JobRegistry.NotTheOwner.selector); // not NotCancellable: nothing leaks
        jr.cancel(client, o.c, uint64(block.timestamp), onClaimed);
        uint64 t = uint64(block.timestamp);
        bytes memory own = OpSig.signCancel(vm, strangerPk, jr, keccak256(abi.encodePacked(stranger, o.c)), t);
        jr.cancel(stranger, o.c, t, own); // the stranger's own id, a different job entirely
        assertEq(jr.getJob(jobId).state, 1);
    }

    function test_cancel_bounds_issuedAt() public {
        Order memory o = _ref(0);
        bytes32 jobId = _jobId(o);
        uint64 issuedAt = uint64(block.timestamp);
        bytes memory sig = OpSig.signCancel(vm, clientPk, jr, jobId, issuedAt);
        vm.warp(block.timestamp + 700);
        vm.expectRevert(JobRegistry.StaleOp.selector);
        jr.cancel(client, o.c, issuedAt, sig);
        uint64 fresh = uint64(block.timestamp);
        jr.cancel(client, o.c, fresh, OpSig.signCancel(vm, clientPk, jr, jobId, fresh));
        assertEq(jr.getJob(jobId).endedBecause, 2);
    }

    function test_cancel_refuses_a_zero_recovered_signer_even_for_a_zero_owner() public {
        bytes32 c = keccak256("ghost");
        uint64 t = uint64(block.timestamp);
        // the zero-signer refusal is load-bearing: a malformed signature recovers address(0), which
        // a zero `owner` would otherwise match
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(address(0), c, t, "");
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(address(0), c, t, new bytes(64));
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(address(0), c, t, new bytes(65));
        assertFalse(jr.getJob(keccak256(abi.encodePacked(address(0), c))).found);
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(client, c, t, new bytes(65));
        assertFalse(jr.getJob(keccak256(abi.encodePacked(client, c))).found);
    }

    function test_cancel_signature_binds_the_jobId_and_issuedAt() public {
        Order memory a = _ref(0);
        Order memory b = _refC(keccak256("bind"));
        uint64 t = uint64(block.timestamp);
        bytes memory sigForA = OpSig.signCancel(vm, clientPk, jr, _jobId(a), t);
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(client, b.c, t, sigForA);
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(client, a.c, t + 1, sigForA);
        jr.cancel(client, a.c, t, sigForA); // untampered lands
        assertEq(jr.getJob(_jobId(a)).endedBecause, 2);
        assertFalse(jr.getJob(_jobId(b)).found); // B is untouched
    }

    function test_cancel_is_relayable_and_reads_no_msg_sender() public {
        Order memory o = _ref(0);
        uint64 t = uint64(block.timestamp);
        bytes memory ownerSig = OpSig.signCancel(vm, clientPk, jr, _jobId(o), t);
        vm.prank(makeAddr("relayer"));
        jr.cancel(client, o.c, t, ownerSig);
        assertEq(jr.getJob(_jobId(o)).endedBecause, 2);
        // and the converse: being the owner as SENDER authorizes nothing without the owner's key
        Order memory other = _ref(pid);
        bytes memory strangerSig = _cancelSig(0xBAD, other.c);
        vm.prank(client);
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(client, other.c, uint64(block.timestamp), strangerSig);
    }

    /// The order signature is checked against `owner` before the row, so a cancelled id answers
    /// NotOpen only to its real owner's order.
    function test_a_cancelled_id_refuses_its_claim_even_with_a_fresh_expiry() public {
        Order memory o = _ref(0);
        _cancelAs(clientPk, o.c);
        vm.warp(block.timestamp + 10);
        o.expiresAt = uint64(block.timestamp + 3600); // a re-signed order under the same `c`
        uint64 t = uint64(block.timestamp);
        bytes memory os = OrderSig.signOrder(vm, clientPk, jr, o);
        bytes memory cs = OpSig.signClaim(vm, opPk, jr, _jobId(o), t);
        vm.expectRevert(JobRegistry.NotOpen.selector);
        jr.claim(o, client, os, t, cs);
    }
}
