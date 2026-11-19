// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {JobRegistry, IUSDC} from "../src/JobRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import "../src/Types.sol";
import {JobHarness} from "./utils/JobHarness.sol";
import {OpSig} from "./utils/OpSig.sol";
import {ZeroSignerRegistry} from "./utils/TestDoubles.sol";

contract JobRegistrySettleTest is JobHarness {
    /// @dev feeBps 250 (2.5%), gasFee 5 and depositFee 0, so every leg of the split is non-trivial:
    /// the fee floors, the gas fee goes to the claim's relayer, and the refund is the balance.
    /// The reference order locks cap 210 + feeCap 5 + gasFee 5 = 220.
    function _fees() internal override {
        vm.prank(curation);
        jr.setFees(250, 5, 0);
    }

    // ── the happy path: the split, reputation, rotation ───────────────────────────────────────

    function test_settle_credits_provider_treasury_and_refund_and_moves_no_token() public {
        bytes32 jobId = _claim(_ref(0));
        uint256 held = usdc.balanceOf(address(jr));
        vm.recordLogs();
        // metered: ceil((30000*1000 + 90000*1500)/1e6) = 165 ; fee = 165*250/10000 = 4, ON TOP
        _settle(opPk, jobId, 1500, bytes("bafy-result")); // test contract submits — a gas-only relayer
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(usdc), "settle must not touch the token");
        }
        assertEq(jr.earned(pid), 165); // the FULL charge, accrued to the provider id
        assertEq(jr.accrued(), 4); // the fee alone
        assertEq(jr.relayerEarned(address(this)), 5); // the gas fee, to the claim's relayer
        assertEq(jr.balanceOf(client), START - 220 + 46); // (cap-charge) 45 + (feeCap-fee) 1
        assertEq(usdc.balanceOf(address(jr)), held);
        assertEq(usdc.balanceOf(address(this)), 0); // the submitter is paid NOTHING
        JobView memory v = jr.getJob(jobId);
        assertEq(v.state, 2);
        assertEq(v.endedBecause, 1);
        assertEq(v.providerId, pid);
        assertEq(jr.activeJobs(pid), 0);
        assertEq(reg.reputationOf(pid), 1000); // clamped at ceiling (was 1000)
    }

    function test_completionTok_clamps_to_unitsOut_and_charge_clamps_to_cap() public {
        bytes32 jobId = _claim(_ref(0));
        _settle(opPk, jobId, 99_999, bytes("r"));
        // charge == cap == 210 ; fee = 210*250/10000 = 5 == feeCap, so nothing is refunded
        assertEq(jr.earned(pid), 210);
        assertEq(jr.accrued(), 5); // fee 5
        assertEq(jr.relayerEarned(address(this)), 5); // gasFee 5
        assertEq(jr.balanceOf(client), START - 220);
    }

    /// The COUNT is bound by the signature; the CID is not — a relayer can choose the CID it
    /// announces, never the number it is paid on.
    function test_signature_binds_the_count_but_not_the_cid() public {
        bytes32 jobId = _claim(_ref(0));
        Terms memory terms = termsOf[jobId];
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signSettle(vm, opPk, jr, jobId, OpSig.usage(100), t);
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.submitAndSettle(jobId, terms, OpSig.usage(200), bytes("bafy-real"), t, sig);
        vm.expectEmit(true, false, false, true, address(jr));
        emit JobRegistry.Settled(jobId, 1000, 0, 100, 0, 0, bytes("bafy-relayer-chose-this"));
        jr.submitAndSettle(jobId, terms, OpSig.usage(100), bytes("bafy-relayer-chose-this"), t, sig);
        // metered: ceil((30000*1000 + 90000*100)/1e6) = 39 ; fee = 39*250/10000 = 0
        assertEq(jr.earned(pid), 39);
    }

    function test_one_settle_signature_verifies_under_two_different_cids() public {
        bytes32 jobId = _claim(_ref(0));
        Terms memory terms = termsOf[jobId];
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signSettle(vm, opPk, jr, jobId, OpSig.usage(100), t);
        uint256 snap = vm.snapshotState();
        jr.submitAndSettle(jobId, terms, OpSig.usage(100), bytes("bafy-first"), t, sig);
        assertEq(jr.getJob(jobId).state, 2);
        uint256 paid = jr.earned(pid);
        assertTrue(vm.revertToState(snap));
        assertEq(jr.getJob(jobId).state, 1); // Claimed again, and the SAME `sig` bytes are reused
        jr.submitAndSettle(jobId, terms, OpSig.usage(100), bytes("bafy-second-entirely-different"), t, sig);
        assertEq(jr.getJob(jobId).state, 2);
        assertEq(jr.earned(pid), paid); // and the CID moves no money either way
    }

    /// Earnings are keyed by provider id: a key rotated after the claim settles the same job, and
    /// the earnings are the id's, paid to whichever key is current at payout.
    function test_a_rotated_operator_settles_and_the_payout_follows_the_rotation() public {
        bytes32 jobId = _claim(_ref(0));
        (address op2, uint256 op2Pk) = makeAddrAndKey("op2");
        vm.prank(curation);
        reg.setOperator(pid, op2);
        bytes memory oldSig = _settleSig(opPk, jobId, 100);
        Terms memory terms = termsOf[jobId];
        vm.expectRevert(JobRegistry.NotTheClaimant.selector); // old key no longer resolves
        jr.submitAndSettle(jobId, terms, OpSig.usage(100), bytes("r"), uint64(block.timestamp), oldSig);
        _settle(op2Pk, jobId, 100, bytes("r")); // same id, new key signs
        assertEq(jr.earned(pid), 39);
        jr.payProvider(pid);
        assertEq(usdc.balanceOf(op2), 39);
        assertEq(usdc.balanceOf(op), 0); // the operator of record at CLAIM time is paid nothing
    }

    function test_settle_relayed_by_the_operator_itself_credits_once() public {
        bytes32 jobId = _claim(_ref(0));
        Terms memory terms = termsOf[jobId];
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signSettle(vm, opPk, jr, jobId, OpSig.usage(100), t);
        vm.prank(op);
        jr.submitAndSettle(jobId, terms, OpSig.usage(100), bytes("r"), t, sig);
        assertEq(jr.earned(pid), 39);
        assertEq(usdc.balanceOf(op), 0);
    }

    // ── the terms ─────────────────────────────────────────────────────────────────────────────

    /// The exits price from terms the relayer hands back, so every member must reproduce the row's
    /// hash: a relayer cannot raise a rate, a unit ceiling, the SLA or the gas fee, nor redirect the
    /// refund to another owner or the gas fee to another relayer.
    function test_settle_refuses_terms_other_than_the_claimed_ones() public {
        bytes32 jobId = _claim(_ref(0));
        uint64 t = uint64(block.timestamp);
        bytes memory sig = _settleSig(opPk, jobId, 100);
        Terms[8] memory bad;
        for (uint256 i; i < 8; i++) {
            bad[i] = termsOf[jobId];
        }
        bad[0].owner = makeAddr("someone-else");
        bad[1].rateIn += 1;
        bad[2].rateOut += 1;
        bad[3].unitsIn += 1;
        bad[4].unitsOut += 1;
        bad[5].slaSecs += 1;
        bad[6].gasFee += 1;
        bad[7].relayer = makeAddr("forger");
        for (uint256 i; i < 8; i++) {
            vm.expectRevert(JobRegistry.TermsMismatch.selector);
            jr.submitAndSettle(jobId, bad[i], OpSig.usage(100), bytes("r"), t, sig);
        }
        _settle(opPk, jobId, 100, bytes("r")); // the claimed terms still settle
    }

    function test_the_gas_fee_is_the_one_fixed_at_claim() public {
        bytes32 jobId = _claim(_ref(0)); // gasFee 5 in the terms
        vm.prank(curation);
        jr.setFees(250, 999, 0); // a gas fee change after the claim must not move this job
        _settle(opPk, jobId, 1500, bytes("r"));
        assertEq(jr.accrued(), 4); // fee 4
        assertEq(jr.relayerEarned(address(this)), 5); // the claimed 5, never the live 999
        assertEq(jr.balanceOf(client), START - 220 + 46);
    }

    // ── reputation ────────────────────────────────────────────────────────────────────────────

    function test_settle_adds_five_milli_of_reputation_below_the_ceiling() public {
        vm.prank(curation);
        reg.setReputation(pid, 500); // the harness seeds 1000, where +5 is invisible
        bytes32 jobId = _claim(_ref(0));
        vm.expectEmit(true, false, false, true);
        emit ProviderRegistry.ReputationChanged(pid, 505);
        _settle(opPk, jobId, 100, bytes("r"));
        assertEq(reg.reputationOf(pid), 505);
    }

    // ── the event contract ────────────────────────────────────────────────────────────────────

    function test_settle_emits_Settled_with_the_clamped_counts_and_never_Ended() public {
        bytes32 jobId = _claim(_ref(0));
        vm.recordLogs();
        _settle(opPk, jobId, 99_999, bytes("bafy-clamped"));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 settledCount;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(jr)) continue;
            assertTrue(logs[i].topics[0] != JobRegistry.Ended.selector, "settle must not emit Ended");
            if (logs[i].topics[0] != JobRegistry.Settled.selector) continue;
            settledCount++;
            assertEq(logs[i].topics[1], jobId); // jobId is the only indexed member
            (uint32 prompt, uint32 cached, uint32 tok, uint128 rateCached, uint128 fee, bytes memory cid) =
                abi.decode(logs[i].data, (uint32, uint32, uint32, uint128, uint128, bytes));
            assertEq(prompt, 1000); // promptTok clamps to unitsIn
            assertEq(cached, 0);
            assertEq(rateCached, 0);
            assertEq(tok, 2000); // the CLAMPED count is what the log carries, not 99_999
            assertEq(fee, 5); // charge capped at 210; 210 * 250 / 10000 = 5
            assertEq(cid, bytes("bafy-clamped"));
        }
        assertEq(settledCount, 1);
    }

    // ── metered input: the backend's prompt and cached counts, the provider's cached rate ─────

    function test_settle_meters_uncached_cached_and_completion_tokens() public {
        bytes32 jobId = _claim(_ref(0));
        Usage memory u = Usage({promptTok: 600, cachedTok: 400, completionTok: 1000, rateInCached: 3000});
        vm.expectEmit(true, false, false, true, address(jr));
        // 30_000*200 + 3_000*400 + 90_000*1000 = 97_200_000 atomic-rate units -> ceil 98; fee 2
        emit JobRegistry.Settled(jobId, 600, 400, 1000, 3000, 2, bytes("r"));
        _settleUsage(opPk, jobId, u, bytes("r"));
        assertEq(jr.earned(pid), 98);
    }

    function test_settle_clamps_every_usage_member_to_the_terms() public {
        bytes32 jobId = _claim(_ref(0));
        Usage memory u = Usage({promptTok: 5000, cachedTok: 9000, completionTok: 5, rateInCached: 99_999});
        vm.expectEmit(true, false, false, true, address(jr));
        // promptTok -> unitsIn 1000, cachedTok -> promptTok 1000, rateInCached -> rateIn 30_000:
        // 30_000*1000 + 90_000*5 = 30_450_000 -> ceil 31; fee 0
        emit JobRegistry.Settled(jobId, 1000, 1000, 5, 30_000, 0, bytes("r"));
        _settleUsage(opPk, jobId, u, bytes("r"));
        assertEq(jr.earned(pid), 31);
    }

    function test_settle_refuses_usage_other_than_what_was_signed() public {
        bytes32 jobId = _claim(_ref(0));
        Terms memory terms = termsOf[jobId];
        uint64 t = uint64(block.timestamp);
        Usage memory signed = Usage({promptTok: 100, cachedTok: 0, completionTok: 10, rateInCached: 0});
        bytes memory sig = OpSig.signSettle(vm, opPk, jr, jobId, signed, t);
        Usage memory edited = Usage({promptTok: 1000, cachedTok: 0, completionTok: 10, rateInCached: 0});
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.submitAndSettle(jobId, terms, edited, bytes("r"), t, sig);
    }

    // ── the conservation identity ─────────────────────────────────────────────────────────────

    function test_the_split_sums_to_cap_plus_feeCap_plus_gasFee() public {
        bytes32 jobId = _claim(_ref(0));
        assertEq(START - jr.balanceOf(client), 220); // cap 210 + feeCap 5 + gasFee 5, locked
        uint256 refundBefore = jr.balanceOf(client);
        _settle(opPk, jobId, 1500, bytes("r"));
        uint256 credited =
            jr.earned(pid) + jr.accrued() + jr.relayerEarned(address(this)) + (jr.balanceOf(client) - refundBefore);
        assertEq(credited, 220, "every atom of the lock is credited somewhere");
    }

    // ── the gate ladder ───────────────────────────────────────────────────────────────────────

    function test_settle_refused_outside_sla_window() public {
        bytes32 jobId = _claim(_ref(0));
        Terms memory terms = termsOf[jobId];
        vm.warp(block.timestamp + 3601);
        bytes memory sig = _settleSig(opPk, jobId, 100);
        vm.expectRevert(JobRegistry.SlaExpired.selector);
        jr.submitAndSettle(jobId, terms, OpSig.usage(100), bytes("r"), uint64(block.timestamp), sig);
        assertEq(jr.balanceOf(client), START - 220); // lock untouched
        assertEq(jr.activeJobs(pid), 1);
    }

    function test_settle_at_exactly_the_sla_deadline_succeeds() public {
        bytes32 jobId = _claim(_ref(0));
        vm.warp(uint256(jr.getJob(jobId).claimedAt) + 3600); // expiry is STRICTLY past the deadline
        _settle(opPk, jobId, 100, bytes("r"));
        assertEq(jr.getJob(jobId).state, 2);
    }

    function test_the_sla_clock_starts_at_the_claim_not_the_order_expiry() public {
        Order memory o = _ref(0);
        vm.warp(block.timestamp + 1000); // claim late, so claimedAt + slaSecs runs past expiresAt
        bytes32 jobId = _claim(o);
        vm.warp(uint256(o.expiresAt) + 400); // past the ORDER's expiry, still inside the SLA window
        _settle(opPk, jobId, 100, bytes("r"));
        assertEq(jr.getJob(jobId).state, 2); // expiresAt bounds the CLAIM; the SLA bounds the settle
    }

    function test_settle_requires_claimant_claimed_state_and_fresh_op() public {
        Order memory o = _ref(0);
        bytes32 jobId = _jobId(o);
        Terms memory terms = _termsFor(jr, o);
        bytes memory openSig = _settleSig(opPk, jobId, 100);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.submitAndSettle(jobId, terms, OpSig.usage(100), bytes("r"), uint64(block.timestamp), openSig);
        _claim(o);
        uint256 strangerPk = 0x57;
        vm.prank(curation);
        reg.register(vm.addr(strangerPk), 4, true, 1000);
        bytes memory strangerSig = _settleSig(strangerPk, jobId, 100);
        vm.expectRevert(JobRegistry.NotTheClaimant.selector); // registered, but not the claimant
        jr.submitAndSettle(jobId, terms, OpSig.usage(100), bytes("r"), uint64(block.timestamp), strangerSig);
        uint64 stale = uint64(block.timestamp); // sign now, land later
        bytes memory sig = OpSig.signSettle(vm, opPk, jr, jobId, OpSig.usage(100), stale);
        vm.warp(block.timestamp + 601);
        vm.expectRevert(JobRegistry.StaleOp.selector);
        jr.submitAndSettle(jobId, terms, OpSig.usage(100), bytes("r"), stale, sig);
    }

    function test_the_state_gate_precedes_the_terms_gate() public {
        // an unknown job answers NotClaimed whatever terms it is handed
        bytes32 ghost = keccak256("no-such-job");
        Terms memory none;
        bytes memory sig = _settleSig(opPk, ghost, 100);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.submitAndSettle(ghost, none, OpSig.usage(100), bytes("r"), uint64(block.timestamp), sig);
    }

    function test_the_terms_gate_precedes_the_signature_check() public {
        bytes32 jobId = _claim(_ref(0));
        Terms memory bad = termsOf[jobId];
        bad.rateOut = 1;
        vm.expectRevert(JobRegistry.TermsMismatch.selector);
        jr.submitAndSettle(jobId, bad, OpSig.usage(100), bytes("r"), uint64(block.timestamp), new bytes(65));
    }

    function test_settle_refuses_a_zero_recovered_signer() public {
        bytes32 jobId = _claim(_ref(0));
        Terms memory terms = termsOf[jobId];
        uint64 t = uint64(block.timestamp);
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.submitAndSettle(jobId, terms, OpSig.usage(100), bytes("r"), t, "");
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.submitAndSettle(jobId, terms, OpSig.usage(100), bytes("r"), t, new bytes(64));
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.submitAndSettle(jobId, terms, OpSig.usage(100), bytes("r"), t, new bytes(65));
        assertEq(jr.getJob(jobId).state, 1);
    }

    function test_settle_refuses_a_zero_signer_even_when_a_record_maps_the_zero_address() public {
        // R15, defense in depth: a registry where the zero address IS the claiming provider —
        // without the guard a 65-zero-byte signature authenticates as the claimant.
        ZeroSignerRegistry reg2 = new ZeroSignerRegistry(curation);
        JobRegistry jr2 = new JobRegistry(reg2, IUSDC(address(usdc)), curation, treasury);
        vm.startPrank(curation);
        reg2.setJobRegistry(address(jr2), true);
        reg2.registerModel("model-a:fp8");
        uint32 pid2 = reg2.register(op, 16, true, 1000);
        jr2.setFees(250, 5, 0);
        vm.stopPrank();
        reg2.forceZeroSignerRecord(pid2);
        _deposit(jr2, 1000);

        bytes32 jobId = _claimOn(jr2, _refC(keccak256("zero-signer-settle")));
        Terms memory terms = termsOf[jobId];
        uint64 t = uint64(block.timestamp);
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr2.submitAndSettle(jobId, terms, OpSig.usage(100), bytes("r"), t, new bytes(65));
        assertEq(jr2.getJob(jobId).state, 1);
        assertEq(jr2.earned(pid2), 0);
    }

    function test_empty_resultCid_is_refused_after_the_freshness_check() public {
        bytes32 jobId = _claim(_ref(0));
        Terms memory terms = termsOf[jobId];
        bytes memory emptySig = _settleSig(opPk, jobId, 100);
        vm.expectRevert(JobRegistry.EmptyResultCid.selector);
        jr.submitAndSettle(jobId, terms, OpSig.usage(100), bytes(""), uint64(block.timestamp), emptySig);
        uint64 stale = uint64(block.timestamp);
        bytes memory staleSig = OpSig.signSettle(vm, opPk, jr, jobId, OpSig.usage(100), stale);
        vm.warp(block.timestamp + 601);
        vm.expectRevert(JobRegistry.StaleOp.selector);
        jr.submitAndSettle(jobId, terms, OpSig.usage(100), bytes(""), stale, staleSig);
    }

    function test_settled_row_answers_NotClaimed_to_replay() public {
        bytes32 jobId = _claim(_ref(0));
        Terms memory terms = termsOf[jobId];
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signSettle(vm, opPk, jr, jobId, OpSig.usage(100), t);
        jr.submitAndSettle(jobId, terms, OpSig.usage(100), bytes("r"), t, sig);
        vm.expectRevert(JobRegistry.NotClaimed.selector); // the persisted row is the replay guard
        jr.submitAndSettle(jobId, terms, OpSig.usage(100), bytes("r"), t, sig);
        assertEq(jr.earned(pid), 39); // credited exactly once
    }

    // ── the money math at the floor ───────────────────────────────────────────────────────────

    function test_dust_job_charges_minimum_one() public {
        // cap = max(1, ceil(1/1e6)) = 1; feeCap = 1*250/10000 = 0, so the lock is 1 + gasFee 5 = 6
        bytes32 jobId = _claim(_orderWith(keccak256("dust"), 0, 0, 1, 1));
        assertEq(START - jr.balanceOf(client), 6);
        _settle(opPk, jobId, 1, bytes("r"));
        assertEq(jr.earned(pid), 1); // the whole atomic unit reaches the provider
        assertEq(jr.accrued(), 0); // fee 0
        assertEq(jr.relayerEarned(address(this)), 5); // gasFee 5
        assertEq(jr.balanceOf(client), START - 6);
    }
}
