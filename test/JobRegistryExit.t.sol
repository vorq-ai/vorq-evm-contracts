// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {JobRegistry, IUSDC} from "../src/JobRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import "../src/Types.sol";
import {JobHarness} from "./utils/JobHarness.sol";
import {OpSig} from "./utils/OpSig.sol";
import {FalseTransferToken} from "./utils/TestDoubles.sol";

/// @notice The two exits that close the job state machine: the permissionless, UNSIGNED `reclaim`
/// anybody may land once a claimed job blows its SLA, and the owner-signed `cancel` that ends a job
/// nobody claimed.
/// @dev feeBps 100 — the protocol's real fee — and gasFee 0, so the reference order locks
/// `cap + feeCap == REF_PULL` and both exits here hand the whole of it back.
/// `EscrowInvariant.t.sol` posts under a nonzero `gasFee`, so the `gasFeeSnap` leg to the treasury
/// is pinned there, not here.
contract JobRegistryExitTest is JobHarness {
    /// @dev the claim-time pull for the reference order at this suite's fees, hand-written rather
    /// than read back off the contract: cap 210 + feeCap 210*100/10000 = 2, gas fee 0.
    uint256 internal constant REF_PULL = REF_CAP + 2;

    function _fees() internal override {
        vm.prank(curation);
        jr.setFees(100, 0);
    }

    // ── reclaim: the SLA deadline, from the other side ─────────────────────────────────────────

    function test_reclaim_after_deadline_is_permissionless_and_penalises() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        vm.expectRevert(JobRegistry.SlaNotExpired.selector);
        jr.reclaim(jobId);
        vm.warp(block.timestamp + 3601);
        uint16 repBefore = reg.reputationOf(pid);
        jr.reclaim(jobId); // no signature, any caller — the one unsigned mutation, by design
        assertEq(usdc.balanceOf(client), 1e24);
        assertEq(reg.reputationOf(pid), repBefore - 40);
        assertEq(jr.activeJobs(pid), 0);
        assertEq(jr.getJob(jobId).endedBecause, 4);
    }

    function test_the_sla_deadline_is_the_handoff_from_settle_to_reclaim() public {
        (bytes32 a,) = postJob(0);
        _claim(a);
        bytes32 b = postJobWith(keccak256("handoff"), REF_RATE_IN, REF_UNITS_IN, REF_RATE_OUT, REF_UNITS_OUT, REF_PULL);
        _claim(b);
        uint256 deadline = uint256(jr.getJob(a).claimedAt) + jr.getJob(a).slaSecs;
        // EXACTLY on the deadline the provider still owns the job. This is the sole discriminator
        // for reclaim's `<=`: one second earlier an inclusive spelling reads the same.
        vm.warp(deadline);
        vm.expectRevert(JobRegistry.SlaNotExpired.selector);
        jr.reclaim(a);
        _settle(opPk, a, 100, bytes("r")); // …and can still settle, on that final second
        // one second later the two permissions have swapped places
        vm.warp(deadline + 1);
        bytes memory lateSig = _settleSig(opPk, b, 100);
        vm.expectRevert(JobRegistry.SlaExpired.selector);
        jr.submitAndSettle(b, 100, bytes("r"), uint64(block.timestamp), lateSig);
        jr.reclaim(b);
        assertEq(jr.getJob(b).endedBecause, 4);
        assertEq(usdc.balanceOf(address(jr)), 0); // both locks resolved, nothing stranded
    }

    function test_reclaim_lands_from_any_sender_and_reads_no_msg_sender() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        vm.warp(block.timestamp + 3601);
        // no registry record, not the owner, and no signature of any kind: `reclaim` is the one
        // mutation whose authority is the clock rather than a key
        address stranger = makeAddr("stranger");
        uint256 clientBefore = usdc.balanceOf(client);
        vm.prank(stranger);
        jr.reclaim(jobId);
        assertEq(usdc.balanceOf(stranger), 0); // the caller is never a payee…
        // …the OWNER is, and for the whole lock: the cap off the row plus its 2-unit fee ceiling,
        // which reclaim returns untouched because the fee is only ever earned at settle
        assertEq(usdc.balanceOf(client) - clientBefore, uint256(jr.capOf(jobId)) + 2);
        assertEq(jr.getJob(jobId).state, 3);
    }

    function test_reclaim_refuses_anything_that_is_not_claimed() public {
        // ambiguity 5: `reclaim` deliberately does NOT check job existence. An absent row reads
        // state 0 (Open), so the state gate answers for it — exactly as in submitAndSettle and fail.
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.reclaim(keccak256("no-such-job"));
        (bytes32 jobId,) = postJob(0);
        // and an abandoned Open row stays Open in STORAGE however expired it reads, so there is
        // nothing for reclaim to unwind: no escrow was ever funded
        vm.warp(block.timestamp + 999_999);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.reclaim(jobId);
    }

    function test_a_reclaimed_row_is_terminal_for_every_other_exit() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        vm.warp(block.timestamp + 3601);
        jr.reclaim(jobId);
        assertEq(usdc.balanceOf(client), 1e24); // refunded exactly once
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.reclaim(jobId); // a second reclaim moves nothing
        bytes memory settleSig = _settleSig(opPk, jobId, 100);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.submitAndSettle(jobId, 100, bytes("r"), uint64(block.timestamp), settleSig);
        bytes memory failSig = _failSig(opPk, jobId);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.fail(jobId, uint64(block.timestamp), failSig);
        _cancelAs(clientPk, jobId); // Cancelled is terminal for cancel too: a silent no-op
        assertEq(usdc.balanceOf(client), 1e24);
        assertEq(jr.getJob(jobId).endedBecause, 4); // and cause 4 is not overwritten with 2
        assertEq(jr.activeJobs(pid), 0);
    }

    function test_after_the_sla_reclaim_and_fail_race_for_the_same_money() public {
        (bytes32 a,) = postJob(0);
        _claim(a);
        bytes32 b = postJobWith(keccak256("race"), REF_RATE_IN, REF_UNITS_IN, REF_RATE_OUT, REF_UNITS_OUT, REF_PULL);
        _claim(b);
        vm.warp(block.timestamp + 3601); // `fail` is NOT SLA-bounded, so both exits are open now
        uint256 clientBefore = usdc.balanceOf(client);
        _fail(opPk, a); // the provider gets there first: cause 3
        jr.reclaim(b); // nobody does: cause 4
        assertEq(jr.getJob(a).endedBecause, 3);
        assertEq(jr.getJob(b).endedBecause, 4);
        // the refund is identical either way, and so is the -40 — only the logged cause differs,
        // which is why a projection cannot read cause 3 vs 4 as "who ended it"
        assertEq(usdc.balanceOf(client) - clientBefore, 2 * REF_PULL); // 2 * (210 + 2)
        assertEq(reg.reputationOf(pid), 920); // 1000 - 40 - 40
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.reclaim(a); // the loser of each race answers NotClaimed
        bytes memory failSig = _failSig(opPk, b);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.fail(b, uint64(block.timestamp), failSig);
    }

    function test_reclaim_penalty_respects_the_reputation_floor() public {
        vm.prank(curation);
        reg.setReputation(pid, 130); // 130 - 40 = 90, under the [100,1000] floor
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        vm.warp(block.timestamp + 3601);
        vm.expectEmit(true, false, false, true);
        emit ProviderRegistry.ReputationChanged(pid, 100);
        jr.reclaim(jobId);
        assertEq(reg.reputationOf(pid), 100); // clamped at the floor, never below it
    }

    function test_reclaim_emits_Ended_with_cause_four_and_never_Settled() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        vm.warp(block.timestamp + 3601);
        vm.recordLogs();
        jr.reclaim(jobId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 endedCount;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(jr)) continue;
            assertTrue(logs[i].topics[0] != JobRegistry.Settled.selector, "reclaim must not emit Settled");
            if (logs[i].topics[0] != JobRegistry.Ended.selector) continue;
            endedCount++;
            assertEq(logs[i].topics[1], jobId); // jobId is the only indexed member
            assertEq(abi.decode(logs[i].data, (uint8)), 4); // reclaim, the only cause this path uses
        }
        assertEq(endedCount, 1);
    }

    function test_reclaim_never_touches_designated() public {
        // an UNDESIGNATED row is what discriminates a stray write: the claimant's id is nonzero, so
        // `designated` staying 0 is only true if nothing assigned it
        (bytes32 undesignated,) = postJob(0);
        _claim(undesignated);
        vm.warp(block.timestamp + 3601);
        jr.reclaim(undesignated);
        assertEq(jr.getJob(undesignated).designated, 0);
        // and a designated row keeps its designation, which is what Plan 4 dispatches recovery on
        (bytes32 jobId,) = postJob(pid);
        _claim(jobId);
        vm.warp(block.timestamp + 3601);
        jr.reclaim(jobId);
        JobView memory v = jr.getJob(jobId);
        assertEq(v.designated, pid); // immutable after post
        assertEq(v.providerId, pid); // the claimant is still on the record
        assertEq(v.state, 3);
        assertEq(v.endedBecause, 4);
        assertEq(v.completionTok, 0); // reclaim meters nothing
        assertEq(v.resultCid.length, 0); // and writes no result
    }

    function test_a_false_returning_token_reverts_the_whole_reclaim() public {
        // The refund runs through `_pay`, so a token that signals failure by RETURNING FALSE must
        // not be mistaken for a completed refund. This instance needs its OWN ProviderRegistry:
        // reclaim always penalises, and that call has to succeed for the refund leg to be reached at
        // all. `EscrowInvariant`'s `test_every_penalty_path_applies_reputation_before_the_untrusted_
        // transfer` is the twin that exploits the opposite, on a registry that refuses the penalty.
        FalseTransferToken bad = new FalseTransferToken();
        ProviderRegistry reg2 = new ProviderRegistry(curation);
        JobRegistry jr2 = new JobRegistry(reg2, IUSDC(address(bad)), curation, treasury);
        vm.startPrank(curation);
        reg2.setJobRegistry(address(jr2), true);
        reg2.registerModel("model-a:fp8");
        uint32 pid2 = reg2.register(op, 16, true, 200); // effectiveCap floors at 1 — enough for one claim
        jr2.setFees(100, 0); // the same fee this suite runs at, so the lock is the same REF_PULL
        vm.stopPrank();
        bad.mint(client, 1000);

        bytes32 jobId = _postTo(jr2, address(bad), keccak256("false-token-reclaim"));
        uint64 t = uint64(block.timestamp);
        jr2.claim(jobId, t, OpSig.signClaim(vm, opPk, jr2, jobId, t));
        assertEq(bad.balanceOf(address(jr2)), REF_PULL); // escrow funded: the pull leg is not at fault
        vm.warp(block.timestamp + 3601);
        vm.expectRevert(JobRegistry.TransferFailed.selector);
        jr2.reclaim(jobId);
        assertEq(jr2.getJob(jobId).state, 1); // the whole reclaim rolled back…
        assertEq(jr2.activeJobs(pid2), 1); // …including the slot release…
        assertEq(reg2.reputationOf(pid2), 200); // …and the penalty (the seed this registration named)
    }

    // ── cancel: one signed entry point, ownership before state ─────────────────────────────────

    function test_cancel_ownership_before_state_open_only_idempotent_terminal() public {
        (bytes32 jobId,) = postJob(0);
        bytes memory strangerSig = _cancelSig(0xBAD, jobId);
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(jobId, uint64(block.timestamp), strangerSig); // 403 before any state info
        _cancelAs(clientPk, jobId); // Open → Cancelled (submitted by the test = relayer)
        assertEq(jr.getJob(jobId).endedBecause, 2);
        _cancelAs(clientPk, jobId); // terminal → silent no-op
        // a CLAIMED row cannot be cancelled: the escrow is funded and the provider is owed a
        // decision, so the client's exit from here is `reclaim`, not `cancel`
        bytes32 j3 = postJobWith(keccak256("cx"), 0, 0, 90_000, 1000, 90);
        _claim(j3);
        bytes memory ownerSig = _cancelSig(clientPk, j3);
        vm.expectRevert(JobRegistry.NotCancellable.selector);
        jr.cancel(j3, uint64(block.timestamp), ownerSig);
    }

    function test_cancel_tells_a_stranger_nothing_about_the_state() public {
        // The only thing that can discriminate ownership-BEFORE-state: a stranger's signature must
        // answer NotTheOwner on a row in every state. State-first would leak the row's state back —
        // NotCancellable on a Claimed job, and a silent success on a terminal one.
        (bytes32 claimed,) = postJob(0);
        _claim(claimed);
        bytes memory onClaimed = _cancelSig(0xBAD, claimed);
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(claimed, uint64(block.timestamp), onClaimed);
        (bytes32 settled,) = postJob(pid);
        _claim(settled);
        _settle(opPk, settled, 100, bytes("r"));
        bytes memory onSettled = _cancelSig(0xBAD, settled);
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(settled, uint64(block.timestamp), onSettled);
        // the idempotent branch is the owner's alone: a stranger gets a 403, not a quiet no-op
        bytes32 ended =
            postJobWith(keccak256("stranger-x"), REF_RATE_IN, REF_UNITS_IN, REF_RATE_OUT, REF_UNITS_OUT, REF_PULL);
        _cancelAs(clientPk, ended);
        bytes memory onCancelled = _cancelSig(0xBAD, ended);
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(ended, uint64(block.timestamp), onCancelled);
        assertEq(jr.getJob(claimed).state, 1); // and none of the three rows moved
        assertEq(jr.getJob(settled).state, 2);
        assertEq(jr.getJob(ended).endedBecause, 2);
    }

    function test_cancel_bounds_issuedAt() public {
        (bytes32 jobId,) = postJob(0);
        uint64 issuedAt = uint64(block.timestamp);
        bytes memory sig = OpSig.signCancel(vm, clientPk, jr, jobId, issuedAt);
        vm.warp(block.timestamp + 700);
        vm.expectRevert(JobRegistry.StaleOp.selector); // one staleness vocabulary for every job op
        jr.cancel(jobId, issuedAt, sig);
        uint64 fresh = uint64(block.timestamp);
        jr.cancel(jobId, fresh, OpSig.signCancel(vm, clientPk, jr, jobId, fresh));
        assertEq(jr.getJob(jobId).endedBecause, 2);
    }

    function test_cancel_on_an_expired_but_open_job_succeeds_and_the_stored_cause_wins() public {
        // ambiguity 6. `getJob` derives an ending for an abandoned Open row but writes nothing, so
        // the row is still cancellable — and once cancelled, the STORED cause is what everyone sees.
        (bytes32 jobId,) = postJob(0);
        vm.warp(block.timestamp + 3601); // strictly past expiresAt
        JobView memory derived = jr.getJob(jobId);
        assertEq(derived.state, 3);
        assertEq(derived.endedBecause, 5); // computed at read time, never stored
        _cancelAs(clientPk, jobId);
        JobView memory v = jr.getJob(jobId);
        assertEq(v.state, 3);
        assertEq(v.endedBecause, 2); // the stored 2 supersedes the read-time 5, forever
        assertEq(usdc.balanceOf(client), 1e24); // an Open job locks nothing, so nothing moves
        assertEq(usdc.balanceOf(address(jr)), 0);
    }

    function test_cancel_from_open_emits_only_Ended_and_moves_nothing() public {
        (bytes32 jobId,) = postJob(0);
        uint256 clientBefore = usdc.balanceOf(client);
        vm.recordLogs();
        _cancelAs(clientPk, jobId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 endedCount;
        for (uint256 i; i < logs.length; i++) {
            // an Open job never funded escrow, so no token leg exists to run — not even a zero one
            assertTrue(logs[i].emitter != address(usdc), "cancel must move no tokens");
            if (logs[i].emitter != address(jr)) continue;
            assertTrue(logs[i].topics[0] != JobRegistry.Settled.selector, "cancel must not emit Settled");
            if (logs[i].topics[0] != JobRegistry.Ended.selector) continue;
            endedCount++;
            assertEq(logs[i].topics[1], jobId);
            assertEq(abi.decode(logs[i].data, (uint8)), 2); // cancelled, the only cause this path uses
        }
        assertEq(endedCount, 1);
        assertEq(usdc.balanceOf(client), clientBefore);
        assertEq(usdc.balanceOf(address(jr)), 0);
        assertEq(jr.capOf(jobId), 0); // `cap` is written by claim, and claim never ran
    }

    function test_cancel_of_a_terminal_row_is_a_silent_no_op() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        _settle(opPk, jobId, 100, bytes("r"));
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 opBefore = usdc.balanceOf(op);
        vm.recordLogs();
        _cancelAs(clientPk, jobId); // Settled: no revert, and no log at all
        assertEq(vm.getRecordedLogs().length, 0);
        JobView memory v = jr.getJob(jobId);
        assertEq(v.state, 2); // still Settled…
        assertEq(v.endedBecause, 1); // …and cause 1 is NOT overwritten with 2
        assertEq(usdc.balanceOf(client), clientBefore);
        assertEq(usdc.balanceOf(op), opBefore);
        // the same for an already-Cancelled row, which is the half that makes the op idempotent
        (bytes32 other,) = postJob(pid);
        _cancelAs(clientPk, other);
        vm.recordLogs();
        _cancelAs(clientPk, other);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(jr.getJob(other).endedBecause, 2);
    }

    function test_a_claimed_row_is_NotCancellable_even_after_its_sla_expires() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        vm.warp(block.timestamp + 3601);
        bytes memory sig = _cancelSig(clientPk, jobId);
        vm.expectRevert(JobRegistry.NotCancellable.selector);
        jr.cancel(jobId, uint64(block.timestamp), sig);
        assertEq(usdc.balanceOf(address(jr)), REF_PULL); // escrow untouched…
        assertEq(jr.activeJobs(pid), 1); // …and the slot still held
        jr.reclaim(jobId); // the exit that DOES apply here
        assertEq(jr.activeJobs(pid), 0);
    }

    function test_unknown_job_answers_NotTheOwner_from_cancel() public {
        // R7. `cancel` checks ownership BEFORE state and `UnknownJob()` is a state answer, so this
        // path has no existence branch at all: an unknown job's owner is address(0), which no real
        // signer matches. `UnknownJob` stays declared and stays in use by `claim`.
        bytes32 ghost = keccak256("ghost-cancel");
        bytes memory sig = _cancelSig(clientPk, ghost);
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(ghost, uint64(block.timestamp), sig);
    }

    function test_cancel_refuses_a_zero_recovered_signer_even_on_an_unknown_job() public {
        // R15 x R7, and the reason the zero-signer refusal comes FIRST here rather than being mere
        // defense in depth: with no existence check, an unknown job's `owner` IS address(0), and
        // `_recover` answers address(0) for a malformed signature. Compare before refusing and a
        // 65-zero-byte signature "matches" that zero owner.
        bytes32 ghost = keccak256("no-such-job");
        uint64 t = uint64(block.timestamp);
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(ghost, t, ""); // empty: the 65-byte length check answers address(0)
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(ghost, t, new bytes(64)); // 64 bytes: same
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(ghost, t, new bytes(65)); // ecrecover itself answers address(0)
        assertFalse(jr.getJob(ghost).found); // and no row was conjured into being
        // the same three against a real row, where the owner is nonzero
        (bytes32 jobId,) = postJob(0);
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(jobId, t, "");
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(jobId, t, new bytes(65));
        assertEq(jr.getJob(jobId).state, 0); // still Open
    }

    function test_cancel_signature_binds_the_jobId_and_issuedAt() public {
        (bytes32 a,) = postJob(0);
        bytes32 b = postJobWith(keccak256("bind"), REF_RATE_IN, REF_UNITS_IN, REF_RATE_OUT, REF_UNITS_OUT, REF_PULL);
        uint64 t = uint64(block.timestamp);
        bytes memory sigForA = OpSig.signCancel(vm, clientPk, jr, a, t);
        // the owner's own signature over job A cannot end job B, and cannot be re-timed
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(b, t, sigForA);
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(a, t + 1, sigForA);
        jr.cancel(a, t, sigForA); // untampered lands
        assertEq(jr.getJob(a).endedBecause, 2);
        assertEq(jr.getJob(b).state, 0); // B is untouched
    }

    function test_cancel_is_relayable_and_reads_no_msg_sender() public {
        (bytes32 jobId,) = postJob(0);
        uint64 t = uint64(block.timestamp);
        bytes memory ownerSig = OpSig.signCancel(vm, clientPk, jr, jobId, t);
        vm.prank(makeAddr("relayer")); // a stranger relays the owner's op: the signature is the auth
        jr.cancel(jobId, t, ownerSig);
        assertEq(jr.getJob(jobId).endedBecause, 2);
        // and the converse: being the owner as SENDER authorizes nothing without the owner's key
        (bytes32 other,) = postJob(pid);
        bytes memory strangerSig = _cancelSig(0xBAD, other);
        vm.prank(client);
        vm.expectRevert(JobRegistry.NotTheOwner.selector);
        jr.cancel(other, uint64(block.timestamp), strangerSig);
    }
}
