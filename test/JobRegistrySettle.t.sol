// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {JobRegistry, IUSDC} from "../src/JobRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import "../src/Types.sol";
import {JobHarness} from "./utils/JobHarness.sol";
import {OpSig} from "./utils/OpSig.sol";
import {ZeroSignerRegistry, FalseTransferToken} from "./utils/TestDoubles.sol";

contract JobRegistrySettleTest is JobHarness {
    /// @dev the payment token's own Transfer topic, so the payout legs can be counted without
    /// re-declaring an event in a test file (ambiguity 20)
    bytes32 constant ERC20_TRANSFER = keccak256("Transfer(address,address,uint256)");

    /// @dev feeBps 250 (2.5%) and gasFee 5, so every leg of the distribution is non-trivial:
    /// the fee floors, the gas fee rides to the treasury, and the refund is the balance.
    function _fees() internal override {
        vm.prank(curation);
        jr.setFees(250, 5);
    }

    // ── the happy path: distribution, reputation, rotation ────────────────────────────────────

    function test_settle_distributes_fee_payout_refund_relayer_gets_nothing() public {
        (bytes32 jobId,) = postJob(0); // cap 210, feeCap 5, gasFee 5 → pull 220
        _claim(jobId);
        // metered: ceil((30000*1000 + 90000*1500)/1e6) = 165 ; fee = 165*250/10000 = 4, ON TOP
        _settle(opPk, jobId, 1500, bytes("bafy-result")); // test contract submits — a gas-only relayer
        assertEq(usdc.balanceOf(op), 165); // the FULL charge → the operator
        assertEq(usdc.balanceOf(address(this)), 0); // the submitter is paid NOTHING
        assertEq(usdc.balanceOf(treasury), 9); // fee 4 + gasFee 5
        assertEq(usdc.balanceOf(client), 1e24 - 220 + 46); // (cap-charge) 45 + (feeCap-fee) 1
        assertEq(usdc.balanceOf(address(jr)), 0); // escrow fully resolved, nothing stranded
        JobView memory v = jr.getJob(jobId);
        assertEq(v.state, 2);
        assertEq(v.endedBecause, 1);
        assertEq(v.completionTok, 1500);
        assertEq(v.resultCid, bytes("bafy-result"));
        assertEq(v.designated, 0); // still immutable; settle never writes it
        assertEq(v.gasFee, 5); // the snapshot, readable after the job resolved
        assertEq(jr.activeJobs(pid), 0);
        assertEq(reg.reputationOf(pid), 1000); // clamped at ceiling (was 1000)
    }

    function test_completionTok_clamps_to_unitsOut_and_charge_clamps_to_cap() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        _settle(opPk, jobId, 99_999, bytes("r"));
        assertEq(jr.getJob(jobId).completionTok, 2000); // clamp to unitsOut
        // charge == cap == 210 ; fee = 210*250/10000 = 5 == feeCap, so nothing is refunded
        assertEq(usdc.balanceOf(op), 210);
        assertEq(usdc.balanceOf(treasury), 10); // fee 5 + gasFee 5
        assertEq(usdc.balanceOf(client), 1e24 - 220);
        assertEq(usdc.balanceOf(address(jr)), 0);
        assertEq(jr.capOf(jobId), 210);
    }

    /// Was `test_signature_binds_count_and_cid`, which also asserted that a relayer swapping the
    /// CID under a valid signature was refused. That refusal is GONE BY DESIGN: `resultCid` left
    /// `SETTLE_TYPEHASH`, because only the coordinator pins and the storage service mints the name,
    /// so the provider cannot know the CID at signing time. What survives — and is pinned here — is
    /// that the COUNT is still bound: a relayer can choose the CID it records, never the number it
    /// is paid on. The companion below pins the other half, that the swap now really does land.
    function test_signature_binds_the_count_but_no_longer_the_cid() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signSettle(vm, opPk, jr, jobId, 100, t);
        // altering the count under a valid signature still fails recovery
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.submitAndSettle(jobId, 200, bytes("bafy-real"), t, sig);
        // ... but a CID the signer never saw is accepted, and is the one that gets recorded
        jr.submitAndSettle(jobId, 100, bytes("bafy-relayer-chose-this"), t, sig);
        // metered: ceil((30000*1000 + 90000*100)/1e6) = 39 ; fee = 39*250/10000 = 0
        assertEq(usdc.balanceOf(op), 39);
        assertEq(jr.getJob(jobId).completionTok, 100);
        assertEq(jr.getJob(jobId).resultCid, bytes("bafy-relayer-chose-this"));
    }

    /// The settle signature is INDEPENDENT of the CID: one signature, byte for byte, verifies under
    /// two different result CIDs. A state snapshot is what makes "the same signature" literal — the
    /// job settles once, so the second run has to start from the same pre-settle state.
    function test_one_settle_signature_verifies_under_two_different_cids() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signSettle(vm, opPk, jr, jobId, 100, t);
        uint256 snap = vm.snapshotState();

        jr.submitAndSettle(jobId, 100, bytes("bafy-first"), t, sig);
        assertEq(jr.getJob(jobId).state, 2);
        assertEq(jr.getJob(jobId).resultCid, bytes("bafy-first"));
        uint256 paid = usdc.balanceOf(op);

        assertTrue(vm.revertToState(snap));
        assertEq(jr.getJob(jobId).state, 1); // Claimed again, and the SAME `sig` bytes are reused
        jr.submitAndSettle(jobId, 100, bytes("bafy-second-entirely-different"), t, sig);
        assertEq(jr.getJob(jobId).state, 2);
        assertEq(jr.getJob(jobId).resultCid, bytes("bafy-second-entirely-different"));
        assertEq(usdc.balanceOf(op), paid); // and the CID moves no money either way
    }

    function test_settle_pays_the_rotated_operator() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        address op2;
        uint256 op2Pk;
        (op2, op2Pk) = makeAddrAndKey("op2");
        vm.prank(curation);
        reg.setOperator(pid, op2);
        bytes memory oldSig = _settleSig(opPk, jobId, 100);
        vm.expectRevert(JobRegistry.NotTheClaimant.selector); // old key no longer resolves
        jr.submitAndSettle(jobId, 100, bytes("r"), uint64(block.timestamp), oldSig);
        _settle(op2Pk, jobId, 100, bytes("r")); // same id, new key signs
        assertGt(usdc.balanceOf(op2), 0);
        // operatorOf is read AT SETTLE TIME, so the payout follows the rotation
        assertEq(usdc.balanceOf(op2), 39);
        assertEq(usdc.balanceOf(op), 0); // the operator of record at CLAIM time is paid nothing
    }

    function test_settle_pays_the_current_operator_never_the_submitter() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        // the operator's own key relays its own settle: it must still be paid exactly once, as
        // the operator, and never twice — msg.sender plays no part in the distribution
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signSettle(vm, opPk, jr, jobId, 100, t);
        vm.prank(op);
        jr.submitAndSettle(jobId, 100, bytes("r"), t, sig);
        assertEq(usdc.balanceOf(op), 39);
    }

    // ── reputation ────────────────────────────────────────────────────────────────────────────

    function test_settle_adds_five_milli_of_reputation_below_the_ceiling() public {
        vm.prank(curation);
        reg.setReputation(pid, 500); // the harness seeds 1000, where +5 is invisible
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        vm.expectEmit(true, false, false, true);
        emit ProviderRegistry.ReputationChanged(pid, 505);
        _settle(opPk, jobId, 100, bytes("r"));
        assertEq(reg.reputationOf(pid), 505);
    }

    // ── the event contract ────────────────────────────────────────────────────────────────────

    function test_settle_emits_Settled_with_the_clamped_count_and_never_Ended() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        vm.recordLogs();
        _settle(opPk, jobId, 99_999, bytes("bafy-clamped"));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 settledCount;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(jr)) continue;
            // causes 1 (settled) and 5 (expired) never travel in an Ended event
            assertTrue(logs[i].topics[0] != JobRegistry.Ended.selector, "settle must not emit Ended");
            if (logs[i].topics[0] != JobRegistry.Settled.selector) continue;
            settledCount++;
            assertEq(logs[i].topics[1], jobId); // jobId is the only indexed member
            (uint32 tok, uint128 fee, bytes memory cid) = abi.decode(logs[i].data, (uint32, uint128, bytes));
            assertEq(tok, 2000); // the CLAMPED count is what the log carries, not 99_999
            assertEq(fee, 5); // charge capped at 210; 210 * 250 / 10000 = 5, what the treasury took
            assertEq(cid, bytes("bafy-clamped"));
        }
        assertEq(settledCount, 1);
    }

    // ── the conservation identity Tasks 7-8 and Plan 2 rely on ────────────────────────────────

    function test_total_paid_out_is_cap_plus_feeCap_plus_gasFeeSnap() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        uint256 opBefore = usdc.balanceOf(op);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 clientBefore = usdc.balanceOf(client);
        assertEq(usdc.balanceOf(address(jr)), 220); // cap 210 + feeCap 5 + gasFeeSnap 5, in escrow
        _settle(opPk, jobId, 1500, bytes("r"));
        uint256 paidOut = (usdc.balanceOf(op) - opBefore) + (usdc.balanceOf(treasury) - treasuryBefore)
            + (usdc.balanceOf(client) - clientBefore);
        // == cap + feeCap + gasFeeSnap, to the atomic unit
        assertEq(paidOut, uint256(jr.capOf(jobId)) + uint256(jr.capOf(jobId)) * jr.feeBps() / 10000 + 5);
        assertEq(usdc.balanceOf(address(jr)), 0); // and the registry keeps nothing
    }

    function test_fail_refunds_the_fee_cap_too() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        assertEq(usdc.balanceOf(client), 1e24 - 220);
        _fail(opPk, jobId);
        assertEq(usdc.balanceOf(client), 1e24 - 5); // cap 210 + feeCap 5 back; gasFee 5 stays out
        assertEq(usdc.balanceOf(op), 0);
        assertEq(usdc.balanceOf(treasury), 5); // the gas fee, and no protocol fee
        assertEq(usdc.balanceOf(address(jr)), 0);
    }

    function test_reclaim_refunds_the_fee_cap_too() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        vm.warp(block.timestamp + 3601);
        jr.reclaim(jobId);
        assertEq(usdc.balanceOf(client), 1e24 - 5);
        assertEq(usdc.balanceOf(treasury), 5);
        assertEq(usdc.balanceOf(address(jr)), 0);
    }

    // ── the gate ladder ───────────────────────────────────────────────────────────────────────

    function test_settle_refused_outside_sla_window() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        vm.warp(block.timestamp + 3601);
        bytes memory sig = _settleSig(opPk, jobId, 100);
        vm.expectRevert(JobRegistry.SlaExpired.selector);
        jr.submitAndSettle(jobId, 100, bytes("r"), uint64(block.timestamp), sig);
        assertEq(usdc.balanceOf(address(jr)), 220); // escrow untouched
        assertEq(jr.activeJobs(pid), 1);
    }

    function test_settle_at_exactly_the_sla_deadline_succeeds() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        uint64 deadline = jr.getJob(jobId).claimedAt + 3600;
        vm.warp(deadline); // the deadline is claimedAt + slaSecs and expiry is STRICTLY past it
        _settle(opPk, jobId, 100, bytes("r"));
        assertEq(jr.getJob(jobId).state, 2);
    }

    function test_the_sla_clock_starts_at_the_claim_not_the_order_expiry() public {
        (bytes32 jobId, Order memory o) = postJob(0);
        vm.warp(block.timestamp + 1000); // claim late, so claimedAt + slaSecs runs past expiresAt
        _claim(jobId);
        vm.warp(uint256(o.expiresAt) + 400); // past the ORDER's expiry, still inside the SLA window
        _settle(opPk, jobId, 100, bytes("r"));
        assertEq(jr.getJob(jobId).state, 2); // expiresAt bounds the CLAIM; the SLA bounds the settle
    }

    function test_settle_pays_the_gasFee_snapshot_not_the_live_one() public {
        (bytes32 jobId,) = postJob(0); // gasFeeSnap = 5
        _claim(jobId); // pulled cap 210 + feeCap 5 + 5
        vm.prank(curation);
        jr.setFees(250, 999); // a gas fee change after funding must not move an escrowed row
        _settle(opPk, jobId, 1500, bytes("r"));
        assertEq(jr.getJob(jobId).gasFee, 5); // the view reports the snapshot too
        assertEq(usdc.balanceOf(treasury), 9); // fee 4 + the SNAPSHOT 5, never the live 999
        assertEq(usdc.balanceOf(address(jr)), 0);
    }

    function test_settle_requires_claimant_claimed_state_and_fresh_op() public {
        (bytes32 jobId,) = postJob(0);
        bytes memory openSig = _settleSig(opPk, jobId, 100);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.submitAndSettle(jobId, 100, bytes("r"), uint64(block.timestamp), openSig); // still Open
        _claim(jobId);
        uint256 strangerPk = 0x57;
        vm.prank(curation);
        reg.register(vm.addr(strangerPk), 4, true, 1000);
        bytes memory strangerSig = _settleSig(strangerPk, jobId, 100);
        vm.expectRevert(JobRegistry.NotTheClaimant.selector); // registered, but not the claimant
        jr.submitAndSettle(jobId, 100, bytes("r"), uint64(block.timestamp), strangerSig);
        uint64 stale = uint64(block.timestamp); // sign now, land later
        bytes memory sig = OpSig.signSettle(vm, opPk, jr, jobId, 100, stale);
        vm.warp(block.timestamp + 601);
        vm.expectRevert(JobRegistry.StaleOp.selector);
        jr.submitAndSettle(jobId, 100, bytes("r"), stale, sig);
    }

    function test_unknown_job_answers_NotClaimed() public {
        // ambiguity 5: submitAndSettle deliberately does NOT check job existence. An absent row
        // reads state 0 (Open), so the state gate answers for it — documented in the README.
        bytes32 ghost = keccak256("no-such-job");
        bytes memory sig = _settleSig(opPk, ghost, 100);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.submitAndSettle(ghost, 100, bytes("r"), uint64(block.timestamp), sig);
    }

    function test_settle_refuses_a_zero_recovered_signer() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        uint64 t = uint64(block.timestamp);
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.submitAndSettle(jobId, 100, bytes("r"), t, ""); // empty: the 65-byte check answers 0
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.submitAndSettle(jobId, 100, bytes("r"), t, new bytes(64)); // 64 bytes: same
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.submitAndSettle(jobId, 100, bytes("r"), t, new bytes(65)); // ecrecover answers 0 itself
        assertEq(jr.getJob(jobId).state, 1);
        assertEq(usdc.balanceOf(address(jr)), 220);
    }

    function test_settle_refuses_a_zero_signer_even_when_a_record_maps_the_zero_address() public {
        // R15, defense in depth. Against the shared registry the explicit guard is invisible:
        // idOf[address(0)] is 0, so the `provider == 0` disjunct answers the same error anyway.
        // This stands up a registry where the zero address IS the claiming provider — without the
        // guard a 65-zero-byte signature authenticates as the claimant and takes the payout.
        ZeroSignerRegistry reg2 = new ZeroSignerRegistry(curation);
        JobRegistry jr2 = new JobRegistry(reg2, IUSDC(address(usdc)), curation, treasury);
        vm.startPrank(curation);
        reg2.setJobRegistry(address(jr2), true);
        reg2.registerModel("model-a:fp8");
        uint32 pid2 = reg2.register(op, 16, true, 1000); // listed, allowAllModels, effectiveCap >= 1
        jr2.setFees(250, 5);
        vm.stopPrank();
        reg2.forceZeroSignerRecord(pid2);

        bytes32 jobId = _postTo(jr2, address(usdc), keccak256("zero-signer-settle"));
        uint64 t = uint64(block.timestamp);
        jr2.claim(jobId, t, OpSig.signClaim(vm, opPk, jr2, jobId, t));
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr2.submitAndSettle(jobId, 100, bytes("r"), t, new bytes(65));
        assertEq(jr2.getJob(jobId).state, 1);
        assertEq(usdc.balanceOf(address(jr2)), 220); // the escrow never moved
    }

    function test_empty_resultCid_is_refused_after_the_freshness_check() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        bytes memory emptySig = _settleSig(opPk, jobId, 100);
        vm.expectRevert(JobRegistry.EmptyResultCid.selector);
        jr.submitAndSettle(jobId, 100, bytes(""), uint64(block.timestamp), emptySig);
        // a stale op with an empty CID answers StaleOp: freshness is the earlier gate
        uint64 stale = uint64(block.timestamp);
        bytes memory staleSig = OpSig.signSettle(vm, opPk, jr, jobId, 100, stale);
        vm.warp(block.timestamp + 601);
        vm.expectRevert(JobRegistry.StaleOp.selector);
        jr.submitAndSettle(jobId, 100, bytes(""), stale, staleSig);
        assertEq(usdc.balanceOf(address(jr)), 220);
    }

    function test_settled_row_answers_NotClaimed_to_replay() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signSettle(vm, opPk, jr, jobId, 100, t);
        jr.submitAndSettle(jobId, 100, bytes("r"), t, sig);
        vm.expectRevert(JobRegistry.NotClaimed.selector); // the persisted row is the replay guard
        jr.submitAndSettle(jobId, 100, bytes("r"), t, sig);
        assertEq(usdc.balanceOf(op), 39); // paid exactly once
        assertEq(usdc.balanceOf(address(jr)), 0);
    }

    // ── the money math at the floor ───────────────────────────────────────────────────────────

    function test_dust_job_charges_minimum_one() public {
        // cap = max(1, ceil(1/1e6)) = 1; feeCap = 1*250/10000 = 0, so the pull is 1 + gasFee 5 = 6
        bytes32 jobId = postJobWith(keccak256("dust"), 0, 0, 1, 1, 6);
        _claim(jobId);
        _settle(opPk, jobId, 1, bytes("r"));
        assertEq(jr.capOf(jobId), 1);
        // charge 1, fee = 1*250/10000 = 0 → the whole atomic unit reaches the operator
        assertEq(usdc.balanceOf(op), 1);
        assertEq(usdc.balanceOf(treasury), 5); // fee 0 + gasFeeSnap 5
        assertEq(usdc.balanceOf(address(jr)), 0);
    }

    // ── `_pay`'s two documented behaviours, which Tasks 7-8 inherit ────────────────────────────

    function test_a_zero_payout_leg_moves_no_tokens() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        vm.recordLogs();
        _settle(opPk, jobId, 99_999, bytes("r")); // charge == cap, so the refund leg is zero
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 transfers;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(usdc) && logs[i].topics[0] == ERC20_TRANSFER) transfers++;
        }
        assertEq(transfers, 2); // operator + treasury only: `_pay` short-circuits a zero amount
    }

    function test_a_false_returning_token_reverts_TransferFailed() public {
        // Real USDC reverts on a shortfall, but the constructor accepts any ERC-20 — and a token
        // that signals failure by RETURNING FALSE must not be read as a successful payout. The
        // pull leg still succeeds, so the failure lands exactly on settle's distribution.
        FalseTransferToken bad = new FalseTransferToken();
        // This instance needs its OWN ProviderRegistry. `submitAndSettle` applies the +5 reputation
        // BEFORE the payout legs (R25), and the shared `reg` has the harness's `jr` registered, so a
        // call from `jr2` would answer `NotJobRegistry()` and mask the leg under test. With its own
        // registry the reward lands and the refusal is the payout's, which is the point here.
        ProviderRegistry reg2 = new ProviderRegistry(curation);
        JobRegistry jr2 = new JobRegistry(reg2, IUSDC(address(bad)), curation, treasury);
        vm.startPrank(curation);
        reg2.setJobRegistry(address(jr2), true);
        reg2.registerModel("model-a:fp8");
        uint32 pid2 = reg2.register(op, 16, true, 200); // effectiveCap floors at 1 — enough for one claim
        jr2.setFees(250, 5);
        vm.stopPrank();
        bad.mint(client, 1000);

        bytes32 jobId = _postTo(jr2, address(bad), keccak256("false-token"));
        uint64 t = uint64(block.timestamp);
        jr2.claim(jobId, t, OpSig.signClaim(vm, opPk, jr2, jobId, t));
        assertEq(bad.balanceOf(address(jr2)), 220); // escrow funded, so the pull leg is not at fault

        bytes memory sig = OpSig.signSettle(vm, opPk, jr2, jobId, 100, t);
        vm.expectRevert(JobRegistry.TransferFailed.selector);
        jr2.submitAndSettle(jobId, 100, bytes("r"), t, sig);
        assertEq(jr2.getJob(jobId).state, 1); // the whole settlement rolled back…
        assertEq(jr2.activeJobs(pid2), 1); // …including the slot release…
        assertEq(reg2.reputationOf(pid2), 200); // …and the reward (the seed this registration named)
    }
}

