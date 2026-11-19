// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {JobRegistry, IUSDC} from "../src/JobRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import "../src/Types.sol";
import {JobHarness} from "./utils/JobHarness.sol";
import {OpSig} from "./utils/OpSig.sol";
import {ZeroSignerRegistry} from "./utils/TestDoubles.sol";

contract JobRegistryFailTest is JobHarness {
    /// @dev feeBps 100 — the protocol's real fee — gasFee 5 and depositFee 0, so the claim locks
    /// `cap + feeCap + gasFee == 210 + 2 + 5 == 217`. `fail` has no protocol-fee leg: the fee
    /// ceiling is only ever EARNED at settle, so the cap and the 2 go back to the owner; the gas fee
    /// goes to the claim's relayer, because it spent that gas whether or not the job delivered.
    function _fees() internal override {
        vm.prank(curation);
        jr.setFees(100, 5, 0);
    }

    // ── the grace window ──────────────────────────────────────────────────────────────────────

    function test_in_grace_fail_is_free_and_relayable() public {
        bytes32 jobId = _claim(_ref(0));
        uint16 repBefore = reg.reputationOf(pid);
        vm.warp(block.timestamp + 299);
        vm.expectEmit(true, false, false, true);
        emit JobRegistry.Ended(jobId, 3);
        _fail(opPk, jobId); // operator-SIGNED, and submitted by this test contract: a gas-only sender
        assertEq(jr.balanceOf(client), START - 5); // cap + feeCap back; the gas fee stays spent
        assertEq(jr.relayerEarned(address(this)), 5); // free of penalty, never free of gas
        assertEq(jr.accrued(), 0);
        assertEq(reg.reputationOf(pid), repBefore); // no delta
        assertEq(jr.activeJobs(pid), 0); // slot free immediately
        JobView memory v = jr.getJob(jobId);
        assertEq(v.state, 3);
        assertEq(v.endedBecause, 3);
        assertEq(v.providerId, pid); // the claimant is still on the record
    }

    function test_post_grace_fail_prices_a_miss() public {
        bytes32 jobId = _claim(_ref(0));
        uint16 repBefore = reg.reputationOf(pid);
        vm.warp(block.timestamp + 301);
        _fail(opPk, jobId);
        assertEq(jr.balanceOf(client), START - 5); // refund identical either way
        assertEq(reg.reputationOf(pid), repBefore - 40);
        assertEq(jr.activeJobs(pid), 0);
    }

    function test_grace_prices_at_landing_not_issuedAt() public {
        bytes32 jobId = _claim(_ref(0));
        Terms memory terms = termsOf[jobId];
        uint16 repBefore = reg.reputationOf(pid);
        uint64 signedInGrace = uint64(block.timestamp) + 250; // op authored inside grace…
        bytes memory sig = OpSig.signFail(vm, opPk, jr, jobId, signedInGrace);
        vm.warp(block.timestamp + 550); // …but lands past it (still ±600 fresh)
        jr.fail(jobId, terms, signedInGrace, sig);
        assertEq(reg.reputationOf(pid), repBefore - 40); // landing time governs: the miss prices
    }

    function test_fail_at_the_exact_grace_boundary_is_free() public {
        bytes32 jobId = _claim(_ref(0));
        // the ONLY discriminator for the window being strictly `>`
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
        bytes32 jobId = _claim(_ref(0));
        Terms memory terms = termsOf[jobId];
        uint64 signedAt = uint64(block.timestamp);
        bytes memory sig = OpSig.signFail(vm, opPk, jr, jobId, signedAt);
        vm.warp(block.timestamp + 600); // the ±600 s freshness window is INCLUSIVE at this end…
        jr.fail(jobId, terms, signedAt, sig);
        // …and it says nothing about the fee clock: grace closed 300 s ago, so the miss still prices
        assertEq(reg.reputationOf(pid), 960);
        assertEq(jr.balanceOf(client), START - 5);
    }

    function test_post_grace_penalty_respects_the_reputation_floor() public {
        vm.prank(curation);
        reg.setReputation(pid, 130); // 130 - 40 = 90, which is under the [100,1000] floor
        bytes32 jobId = _claim(_ref(0));
        vm.warp(block.timestamp + 301);
        vm.expectEmit(true, false, false, true);
        emit ProviderRegistry.ReputationChanged(pid, 100);
        _fail(opPk, jobId);
        assertEq(reg.reputationOf(pid), 100);
    }

    // ── the money: the gas fee to the relayer and the rest to the owner, no token moved ───────

    function test_fail_releases_cap_and_fee_cap_and_pays_the_relayer_the_claimed_gas_fee() public {
        bytes32 jobId = _claim(_ref(0)); // cap 210 + feeCap 2 + gasFee 5 → 217 locked
        assertEq(START - jr.balanceOf(client), 217);
        vm.prank(curation);
        // the gas fee taken is the one fixed at claim, whatever curation set after it. feeBps stays at
        // the suite's 100: it is read live at the exit, and moves only with the book empty.
        jr.setFees(100, 999, 0);
        uint256 held = usdc.balanceOf(address(jr));
        uint256 clientBefore = jr.balanceOf(client);
        vm.recordLogs();
        _fail(opPk, jobId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(usdc), "fail must not touch the token");
        }
        assertEq(jr.balanceOf(client) - clientBefore, 212); // the cap and its 2-unit fee ceiling
        assertEq(jr.earned(pid), 0); // the provider earns nothing on its own abort
        assertEq(jr.relayerEarned(address(this)), 5); // the claimed 5, never the live 999
        assertEq(jr.accrued(), 0); // no fee leg
        assertEq(usdc.balanceOf(address(jr)), held);
    }

    function test_fail_refuses_terms_other_than_the_claimed_ones() public {
        bytes32 jobId = _claim(_ref(0));
        Terms memory bad = termsOf[jobId];
        bad.gasFee = 0; // a forged gas fee
        bytes memory sig = _failSig(opPk, jobId);
        vm.expectRevert(JobRegistry.TermsMismatch.selector);
        jr.fail(jobId, bad, uint64(block.timestamp), sig);
        bad = termsOf[jobId];
        bad.owner = makeAddr("thief");
        vm.expectRevert(JobRegistry.TermsMismatch.selector);
        jr.fail(jobId, bad, uint64(block.timestamp), sig);
        bad = termsOf[jobId];
        bad.relayer = makeAddr("thief"); // the gas fee redirected to another relayer
        vm.expectRevert(JobRegistry.TermsMismatch.selector);
        jr.fail(jobId, bad, uint64(block.timestamp), sig);
        assertEq(jr.getJob(jobId).state, 1);
    }

    // ── the event contract ────────────────────────────────────────────────────────────────────

    function test_fail_emits_Ended_with_cause_three_and_never_Settled() public {
        bytes32 jobId = _claim(_ref(0));
        vm.recordLogs();
        _fail(opPk, jobId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 endedCount;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(jr)) continue;
            assertTrue(logs[i].topics[0] != JobRegistry.Settled.selector, "fail must not emit Settled");
            if (logs[i].topics[0] != JobRegistry.Ended.selector) continue;
            endedCount++;
            assertEq(logs[i].topics[1], jobId);
            assertEq(abi.decode(logs[i].data, (uint8)), 3);
        }
        assertEq(endedCount, 1);
    }

    // ── the gate ladder ───────────────────────────────────────────────────────────────────────

    function test_fail_is_claimant_only_claimed_only_and_fresh() public {
        Order memory o = _ref(0);
        bytes32 jobId = _jobId(o);
        Terms memory terms = _termsFor(jr, o);
        bytes memory openSig = _failSig(opPk, jobId);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.fail(jobId, terms, uint64(block.timestamp), openSig); // never claimed
        _claim(o);
        bytes memory strangerSig = _failSig(0xBAD, jobId);
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.fail(jobId, terms, uint64(block.timestamp), strangerSig); // signer has no provider id
        uint64 stale = uint64(block.timestamp);
        bytes memory sig = OpSig.signFail(vm, opPk, jr, jobId, stale);
        vm.warp(block.timestamp + 601);
        vm.expectRevert(JobRegistry.StaleOp.selector);
        jr.fail(jobId, terms, stale, sig);
    }

    function test_a_registered_stranger_cannot_abort_someone_elses_job() public {
        bytes32 jobId = _claim(_ref(0));
        Terms memory terms = termsOf[jobId];
        uint256 strangerPk = 0x57;
        vm.prank(curation);
        reg.register(vm.addr(strangerPk), 4, true, 1000); // a real provider id, just not this job's
        bytes memory strangerSig = _failSig(strangerPk, jobId);
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.fail(jobId, terms, uint64(block.timestamp), strangerSig);
        assertEq(jr.getJob(jobId).state, 1);
        assertEq(START - jr.balanceOf(client), 217); // the lock is not a stranger's to release
        assertEq(jr.activeJobs(pid), 1);
    }

    function test_the_state_gate_precedes_the_freshness_check() public {
        Order memory o = _ref(0);
        bytes32 jobId = _jobId(o);
        uint64 stale = uint64(block.timestamp);
        bytes memory sig = OpSig.signFail(vm, opPk, jr, jobId, stale);
        Terms memory terms = _termsFor(jr, o);
        vm.warp(block.timestamp + 601);
        vm.expectRevert(JobRegistry.NotClaimed.selector);
        jr.fail(jobId, terms, stale, sig);
    }

    function test_fail_lands_from_any_sender_and_never_reads_msg_sender() public {
        bytes32 jobId = _claim(_ref(0));
        Terms memory terms = termsOf[jobId];
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signFail(vm, opPk, jr, jobId, t);
        vm.prank(makeAddr("relayer"));
        jr.fail(jobId, terms, t, sig);
        assertEq(jr.getJob(jobId).state, 3);
        // and the converse: being the operator KEY authorizes nothing without the operator's signature
        bytes32 other = _claim(_ref(pid));
        Terms memory otherTerms = termsOf[other];
        bytes memory strangerSig = _failSig(0xBAD, other);
        vm.prank(op);
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.fail(other, otherTerms, uint64(block.timestamp), strangerSig);
    }

    function test_failed_row_answers_NotClaimed_to_replay() public {
        bytes32 jobId = _claim(_ref(0));
        Terms memory terms = termsOf[jobId];
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signFail(vm, opPk, jr, jobId, t);
        jr.fail(jobId, terms, t, sig);
        vm.expectRevert(JobRegistry.NotClaimed.selector); // the persisted terminal row is the guard
        jr.fail(jobId, terms, t, sig);
        assertEq(jr.balanceOf(client), START - 5); // released exactly once
        assertEq(jr.relayerEarned(address(this)), 5); // and the gas fee taken exactly once
        assertEq(jr.activeJobs(pid), 0);
    }

    function test_fail_refuses_a_zero_recovered_signer() public {
        bytes32 jobId = _claim(_ref(0));
        Terms memory terms = termsOf[jobId];
        uint64 t = uint64(block.timestamp);
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.fail(jobId, terms, t, "");
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.fail(jobId, terms, t, new bytes(64));
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr.fail(jobId, terms, t, new bytes(65));
        assertEq(jr.getJob(jobId).state, 1);
    }

    function test_fail_refuses_a_zero_signer_even_when_a_record_maps_the_zero_address() public {
        ZeroSignerRegistry reg2 = new ZeroSignerRegistry(curation);
        JobRegistry jr2 = new JobRegistry(reg2, IUSDC(address(usdc)), curation, treasury);
        vm.startPrank(curation);
        reg2.setJobRegistry(address(jr2), true);
        reg2.registerModel("model-a:fp8");
        uint32 pid2 = reg2.register(op, 16, true, 1000);
        jr2.setFees(100, 5, 0);
        vm.stopPrank();
        reg2.forceZeroSignerRecord(pid2);
        _deposit(jr2, 1000);

        bytes32 jobId = _claimOn(jr2, _refC(keccak256("zero-signer-fail")));
        Terms memory terms = termsOf[jobId];
        uint64 t = uint64(block.timestamp);
        vm.expectRevert(JobRegistry.NotTheClaimant.selector);
        jr2.fail(jobId, terms, t, new bytes(65));
        assertEq(jr2.getJob(jobId).state, 1);
        assertEq(jr2.balanceOf(client), 1000 - 217); // the lock never moved
    }
}
