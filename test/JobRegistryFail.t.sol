// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {JobRegistry, IUSDC} from "../src/JobRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import "../src/Types.sol";
import {JobHarness} from "./utils/JobHarness.sol";
import {OpSig} from "./utils/OpSig.sol";
import {ZeroSignerRegistry, FalseTransferToken} from "./utils/TestDoubles.sol";

contract JobRegistryFailTest is JobHarness {
    /// @dev feeBps 100 — the protocol's real fee — and gasFee 5, so the claim pulls
    /// `cap + feeCap + gasFeeSnap == 210 + 2 + 5 == 217` (feeCap = 210*100/10000, floored).
    /// `fail` has no protocol-fee leg: the fee ceiling is only ever EARNED at settle, so the cap
    /// and the 2 go back to the owner; the 5-unit gas fee snapshot goes to the treasury, because
    /// the relayer spent that gas whether or not the job delivered — which is what one test
    /// proves by raising the fees after the claim. The gas fee is nonzero so the two legs are
    /// distinguishable and the refund cannot be mistaken for `cap` alone.
    function _fees() internal override {
        vm.prank(curation);
        jr.setFees(100, 5);
    }

    // ── the grace window ──────────────────────────────────────────────────────────────────────

    function test_in_grace_fail_is_free_and_relayable() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        uint16 repBefore = reg.reputationOf(pid);
        vm.warp(block.timestamp + 299);
        vm.expectEmit(true, false, false, true);
        emit JobRegistry.Ended(jobId, 3);
        _fail(opPk, jobId); // operator-SIGNED, and submitted by this test contract: a gas-only sender
        assertEq(usdc.balanceOf(client), 1e24 - 5); // cap + feeCap back; the gas fee stays spent
        assertEq(usdc.balanceOf(treasury), 5); // free of penalty, never free of gas
        assertEq(reg.reputationOf(pid), repBefore); // no delta
        assertEq(jr.activeJobs(pid), 0); // slot free immediately
        JobView memory v = jr.getJob(jobId);
        assertEq(v.state, 3);
        assertEq(v.endedBecause, 3);
    }

    function test_post_grace_fail_prices_a_miss() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        uint16 repBefore = reg.reputationOf(pid);
        vm.warp(block.timestamp + 301);
        _fail(opPk, jobId);
        assertEq(usdc.balanceOf(client), 1e24 - 5); // refund identical either way
        assertEq(reg.reputationOf(pid), repBefore - 40);
        assertEq(jr.activeJobs(pid), 0); // slot frees immediately
    }

    function test_grace_prices_at_landing_not_issuedAt() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        uint16 repBefore = reg.reputationOf(pid);
        uint64 signedInGrace = uint64(block.timestamp) + 250; // op authored inside grace…
        bytes memory sig = OpSig.signFail(vm, opPk, jr, jobId, signedInGrace);
        vm.warp(block.timestamp + 550); // …but lands past it (still ±600 fresh)
        jr.fail(jobId, signedInGrace, sig);
        assertEq(reg.reputationOf(pid), repBefore - 40); // landing time governs: the miss prices
    }

    function test_fail_at_the_exact_grace_boundary_is_free() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        // the ONLY discriminator for the window being strictly `>`: at 299 an inclusive `>=` would
        // still read free, so exactly `claimedAt + FAIL_GRACE` is where the two spellings differ
        vm.warp(uint256(jr.getJob(jobId).claimedAt) + jr.FAIL_GRACE());
        vm.recordLogs();
        _fail(opPk, jobId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // free means the delta is never APPLIED, not merely that it nets to zero at the ceiling
        for (uint256 i; i < logs.length; i++) {
            assertTrue(
                logs[i].emitter != address(reg) || logs[i].topics[0] != ProviderRegistry.ReputationChanged.selector,
                "a fail inside the grace window must not touch reputation"
            );
        }
        assertEq(reg.reputationOf(pid), 1000);
        assertEq(jr.getJob(jobId).state, 3);
    }

    function test_freshness_and_grace_are_independent_clocks() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        uint64 signedAt = uint64(block.timestamp);
        bytes memory sig = OpSig.signFail(vm, opPk, jr, jobId, signedAt);
        vm.warp(block.timestamp + 600); // the ±600 s freshness window is INCLUSIVE at this end…
        jr.fail(jobId, signedAt, sig);
        // …and it says nothing about the fee clock: grace closed 300 s ago, so the miss still prices
        assertEq(reg.reputationOf(pid), 960);
        assertEq(usdc.balanceOf(client), 1e24 - 5);
    }

    function test_post_grace_penalty_respects_the_reputation_floor() public {
        vm.prank(curation);
        reg.setReputation(pid, 130); // 130 - 40 = 90, which is under the [100,1000] floor
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        vm.warp(block.timestamp + 301);
        vm.expectEmit(true, false, false, true);
        emit ProviderRegistry.ReputationChanged(pid, 100);
        _fail(opPk, jobId);
        assertEq(reg.reputationOf(pid), 100); // clamped at the floor, never below it
    }

    // ── the money: two legs, the gas fee to the treasury and the rest to the owner ───────────

    function test_fail_refunds_cap_and_fee_cap_and_pays_the_treasury_the_gas_fee_snapshot() public {
        (bytes32 jobId,) = postJob(0); // cap 210 + feeCap 2 + gasFeeSnap 5 → 217 escrowed
        _claim(jobId);
        assertEq(usdc.balanceOf(address(jr)), 217);
        vm.prank(curation);
        // fail takes NO protocol fee, and the gas fee it takes is the SNAPSHOT, whatever curation
        // set after the escrow funded. feeBps is left at the suite's 100: conservation only holds
        // while it is unchanged between the claim and the terminal call, so only the gas fee moves.
        jr.setFees(100, 999);
        uint256 clientBefore = usdc.balanceOf(client);
        _fail(opPk, jobId);
        // the two legs are the conservation identity on this path: paid out == 217, i.e. the cap
        // and its 2-unit fee ceiling to the owner, the 5-unit gas fee snapshot to the treasury
        assertEq(usdc.balanceOf(client) - clientBefore, uint256(jr.capOf(jobId)) + 2);
        assertEq(usdc.balanceOf(op), 0); // the operator earns nothing on its own abort
        assertEq(usdc.balanceOf(treasury), 5); // no fee leg; the snapshot, never the live 999
        assertEq(usdc.balanceOf(address(this)), 0); // the relayer is paid nothing
        assertEq(usdc.balanceOf(address(jr)), 0); // escrow fully resolved, nothing stranded
    }

    function test_fail_never_touches_designated() public {
        // an UNDESIGNATED row is what discriminates a stray write: the claimant's id is nonzero, so
        // `designated` staying 0 is only true if nothing assigned it
        (bytes32 undesignated,) = postJob(0);
        _claim(undesignated);
        _fail(opPk, undesignated);
        assertEq(jr.getJob(undesignated).designated, 0);
        // and a designated row keeps its designation, which is what Plan 4 dispatches recovery on
        (bytes32 jobId,) = postJob(pid); // designated to this very provider
        _claim(jobId);
        vm.warp(block.timestamp + 301);
        _fail(opPk, jobId);
        JobView memory v = jr.getJob(jobId);
        assertEq(v.designated, pid); // immutable after post
        assertEq(v.providerId, pid); // the claimant is still on the record
        assertEq(v.state, 3);
        assertEq(v.endedBecause, 3);
        assertEq(v.completionTok, 0); // fail meters nothing
        assertEq(v.resultCid.length, 0); // and writes no result
    }

    function test_a_false_returning_token_reverts_the_whole_fail() public {
        // Real USDC reverts on a shortfall, but the constructor accepts any ERC-20 — and a token
        // that signals failure by RETURNING FALSE must not be read as a successful refund. The pull
        // leg still succeeds, so the failure lands exactly on the refund.
        FalseTransferToken bad = new FalseTransferToken();
        JobRegistry jr2 = new JobRegistry(reg, IUSDC(address(bad)), curation, treasury);
        bad.mint(client, 1000);
        vm.prank(curation);
        jr2.setFees(100, 5);

        bytes32 jobId = _postTo(jr2, address(bad), keccak256("false-token-fail"));
        uint64 t = uint64(block.timestamp);
        jr2.claim(jobId, t, OpSig.signClaim(vm, opPk, jr2, jobId, t));
        assertEq(bad.balanceOf(address(jr2)), 217); // escrow funded, so the pull leg is not at fault
        // This fail lands INSIDE the grace window, so no reputation call is made at all — and one
        // from `jr2` could not succeed anyway: only the harness's `jr` is authorised on `reg`, so
        // `onlyJobRegistry` would answer `NotJobRegistry()` to `jr2`.
        // `setJobRegistry` is a repeatable, revocable boolean map (`isJobRegistry`) — see
        // ProviderRegistry.sol:101. Revocation and mis-authorisation both strand escrow;
        // re-authorisation repairs either.
        // A test wanting a post-grace fail here must stand up its own `ProviderRegistry`, as the
        // settle suite's twin now does.
        bytes memory sig = OpSig.signFail(vm, opPk, jr2, jobId, t);
        vm.expectRevert(JobRegistry.TransferFailed.selector);
        jr2.fail(jobId, t, sig);
        assertEq(jr2.getJob(jobId).state, 1); // the whole abort rolled back
        assertEq(jr2.activeJobs(pid), 1); // including the slot release
    }

    // ── the event contract ────────────────────────────────────────────────────────────────────

    function test_fail_emits_Ended_with_cause_three_and_never_Settled() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        vm.recordLogs();
        _fail(opPk, jobId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 endedCount;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(jr)) continue;
            assertTrue(logs[i].topics[0] != JobRegistry.Settled.selector, "fail must not emit Settled");
            if (logs[i].topics[0] != JobRegistry.Ended.selector) continue;
            endedCount++;
            assertEq(logs[i].topics[1], jobId); // jobId is the only indexed member
            assertEq(abi.decode(logs[i].data, (uint8)), 3); // provider_fail, the only cause fail uses
        }
        assertEq(endedCount, 1);
    }

    // ── the gate ladder ───────────────────────────────────────────────────────────────────────

    function test_fail_is_claimant_only_claimed_only_and_fresh() public {
        (bytes32 jobId,) = postJob(0);
        bytes memory openSig = _failSig(opPk, jobId);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.fail(jobId, uint64(block.timestamp), openSig); // still Open
        _claim(jobId);
        bytes memory strangerSig = _failSig(0xBAD, jobId);
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.fail(jobId, uint64(block.timestamp), strangerSig); // signer has no provider id
        uint64 stale = uint64(block.timestamp);
        bytes memory sig = OpSig.signFail(vm, opPk, jr, jobId, stale);
        vm.warp(block.timestamp + 601);
        vm.expectRevert(JobRegistry.StaleOp.selector);
        jr.fail(jobId, stale, sig);
    }

    function test_a_registered_stranger_cannot_abort_someone_elses_job() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        uint256 strangerPk = 0x57;
        vm.prank(curation);
        reg.register(vm.addr(strangerPk), 4, true, 1000); // a real provider id, just not this job's
        // the ONLY case that separates the two halves of the claimant gate: a signer the registry
        // resolves, so `provider == 0` cannot answer and the ID equality has to
        bytes memory strangerSig = _failSig(strangerPk, jobId);
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.fail(jobId, uint64(block.timestamp), strangerSig);
        assertEq(jr.getJob(jobId).state, 1);
        assertEq(usdc.balanceOf(address(jr)), 217); // the escrow is not a stranger's to unwind
        assertEq(jr.activeJobs(pid), 1); // nor the slot to release
    }

    function test_the_state_gate_precedes_the_freshness_check() public {
        (bytes32 jobId,) = postJob(0);
        uint64 stale = uint64(block.timestamp);
        bytes memory sig = OpSig.signFail(vm, opPk, jr, jobId, stale);
        vm.warp(block.timestamp + 601);
        // the row is Open AND the op is stale — the state gate is the earlier of the two answers,
        // which is what keeps an unknown/unclaimed job's reply independent of when it is asked
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.fail(jobId, stale, sig);
    }

    function test_fail_lands_from_any_sender_and_never_reads_msg_sender() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signFail(vm, opPk, jr, jobId, t);
        vm.prank(makeAddr("relayer")); // a gas-only relayer with no registry record of its own
        jr.fail(jobId, t, sig);
        assertEq(jr.getJob(jobId).state, 3);
        // and the converse: being the operator KEY authorizes nothing without the operator's
        // signature, so a claimant-sent transaction carrying a stranger's op is still refused
        (bytes32 other,) = postJob(pid);
        _claim(other);
        bytes memory strangerSig = _failSig(0xBAD, other);
        vm.prank(op);
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.fail(other, uint64(block.timestamp), strangerSig);
    }

    function test_failed_row_answers_NotClaimed_to_replay() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signFail(vm, opPk, jr, jobId, t);
        jr.fail(jobId, t, sig);
        vm.expectRevert(JobRegistry.NotClaimed.selector); // the persisted terminal row is the guard
        jr.fail(jobId, t, sig);
        assertEq(usdc.balanceOf(client), 1e24 - 5); // refunded exactly once
        assertEq(usdc.balanceOf(treasury), 5); // and the gas fee taken exactly once
        assertEq(jr.activeJobs(pid), 0);
    }

    function test_unknown_job_answers_NotClaimed_from_fail() public {
        // ambiguity 5: `fail` deliberately does NOT check job existence. An absent row reads
        // state 0 (Open), so the state gate answers for it — documented in the README.
        bytes32 ghost = keccak256("no-such-job");
        bytes memory sig = _failSig(opPk, ghost);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.fail(ghost, uint64(block.timestamp), sig);
    }

    function test_fail_refuses_a_zero_recovered_signer() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        uint64 t = uint64(block.timestamp);
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.fail(jobId, t, ""); // empty: the 65-byte length check answers address(0)
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.fail(jobId, t, new bytes(64)); // 64 bytes: same
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.fail(jobId, t, new bytes(65)); // ecrecover answers address(0) itself
        assertEq(jr.getJob(jobId).state, 1);
        assertEq(usdc.balanceOf(address(jr)), 217); // escrow untouched
    }

    function test_fail_refuses_a_zero_signer_even_when_a_record_maps_the_zero_address() public {
        // R15, defense in depth. Against the shared registry the explicit guard is invisible:
        // idOf[address(0)] is 0, so the `provider == 0` disjunct answers the same error anyway.
        // This stands up a registry where the zero address IS the claiming provider — without the
        // guard a 65-zero-byte signature aborts someone else's job and unwinds their escrow.
        ZeroSignerRegistry reg2 = new ZeroSignerRegistry(curation);
        JobRegistry jr2 = new JobRegistry(reg2, IUSDC(address(usdc)), curation, treasury);
        vm.startPrank(curation);
        reg2.setJobRegistry(address(jr2), true);
        reg2.registerModel("model-a:fp8");
        uint32 pid2 = reg2.register(op, 16, true, 1000); // listed, allowAllModels, effectiveCap >= 1
        jr2.setFees(100, 5);
        vm.stopPrank();
        reg2.forceZeroSignerRecord(pid2);

        bytes32 jobId = _postTo(jr2, address(usdc), keccak256("zero-signer-fail"));
        uint64 t = uint64(block.timestamp);
        jr2.claim(jobId, t, OpSig.signClaim(vm, opPk, jr2, jobId, t));
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr2.fail(jobId, t, new bytes(65));
        assertEq(jr2.getJob(jobId).state, 1);
        assertEq(usdc.balanceOf(address(jr2)), 217); // the escrow never moved
    }
}
