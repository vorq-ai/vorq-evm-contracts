// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {JobRegistry, IUSDC} from "../src/JobRegistry.sol";
import "../src/Types.sol";
import {JobHarness} from "./utils/JobHarness.sol";
import {OrderSig} from "./utils/OrderSig.sol";
import {OpSig} from "./utils/OpSig.sol";
import {ZeroSignerRegistry} from "./utils/TestDoubles.sol";

contract JobRegistryClaimTest is JobHarness {
    /// @dev the payment token's own ERC-20 event, so a token movement is locatable in a recorded log
    bytes32 constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    uint256 internal constant REF_LOCK = 212; // cap 210 + feeCap 2 at this suite's 1% fee, gasFee 0

    /// @dev feeBps 100 — the protocol's real fee — gasFee 0 and depositFee 0, so the reference
    /// order's claim locks `cap + feeCap == 210 + 210*100/10000 == 212`. The one test that cares
    /// about the gas fee sets its own.
    function _fees() internal override {
        vm.prank(curation);
        jr.setFees(100, 0, 0);
    }

    /// @dev claim with pre-signed signatures against an armed expectation; asserts nothing landed
    function _claimReverts(Order memory o, bytes memory reason) internal {
        uint64 t = uint64(block.timestamp);
        (bytes memory os, bytes memory cs) = _claimSigs(o);
        vm.expectRevert(reason);
        jr.claim(o, client, os, t, cs);
        assertFalse(jr.getJob(_jobId(o)).found);
        assertEq(jr.balanceOf(client), START);
    }

    function _claimRevertsSel(Order memory o, bytes4 sel) internal {
        _claimReverts(o, abi.encodeWithSelector(sel));
    }

    // ── the happy path ────────────────────────────────────────────────────────────────────────

    function test_claim_records_the_order_locks_the_balance_and_emits_Posted_then_Claimed() public {
        Order memory o = _ref(0);
        bytes32 jobId = _jobId(o);
        uint64 t = uint64(block.timestamp);
        (bytes memory os, bytes memory cs) = _claimSigs(o);
        uint256 held = usdc.balanceOf(address(jr));
        _expectPosted(o, 0);
        vm.expectEmit(true, true, true, true, address(jr));
        emit JobRegistry.Claimed(jobId, pid, makeAddr("relayer"), t);
        vm.prank(makeAddr("relayer")); // a gas-only relayer with no registry record of its own
        jr.claim(o, client, os, t, cs);
        assertEq(jr.balanceOf(client), START - REF_LOCK); // cap 210 + feeCap 2, locked
        assertEq(usdc.balanceOf(address(jr)), held, "claim moves no token");
        assertEq(jr.activeJobs(pid), 1);
        JobView memory v = jr.getJob(jobId);
        assertTrue(v.found);
        assertEq(v.jobId, jobId);
        assertEq(v.state, 1);
        assertEq(v.endedBecause, 0);
        assertEq(v.providerId, pid); // the SIGNER's id — the sender never mattered
        assertEq(v.claimedAt, t);
    }

    /// The shape an indexer decodes: jobId, provider and relayer indexed, claimedAt the data. The
    /// relayer is the sender, and it is the relayer the row's terms hash commits to.
    function test_Claimed_indexes_the_job_the_provider_and_the_relayer() public {
        Order memory o = _ref(0);
        address relayer = makeAddr("relayer");
        vm.recordLogs();
        bytes32 jobId = _claimVia(jr, o, relayer);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory claimed = logs[logs.length - 1];
        assertEq(claimed.emitter, address(jr));
        assertEq(claimed.topics.length, 4);
        assertEq(claimed.topics[0], keccak256("Claimed(bytes32,uint32,address,uint64)"));
        assertEq(claimed.topics[1], jobId);
        assertEq(claimed.topics[2], bytes32(uint256(pid)));
        assertEq(claimed.topics[3], bytes32(uint256(uint160(relayer))));
        assertEq(abi.decode(claimed.data, (uint64)), uint64(block.timestamp));
        // the terms naming this relayer are the ones the row accepts
        vm.warp(block.timestamp + 3601);
        jr.reclaim(jobId, termsOf[jobId]);
        assertEq(jr.getJob(jobId).endedBecause, 4);
    }

    function test_claim_calls_no_token_at_all() public {
        Order memory o = _ref(0);
        uint64 t = uint64(block.timestamp);
        (bytes memory os, bytes memory cs) = _claimSigs(o);
        vm.recordLogs();
        jr.claim(o, client, os, t, cs);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(usdc), "claim must not touch the token");
        }
        assertEq(logs.length, 2); // Posted, Claimed
        assertEq(logs[0].topics[0], JobRegistry.Posted.selector);
        assertEq(logs[1].topics[0], JobRegistry.Claimed.selector);
    }

    /// The job row is one slot: claim writes exactly three — the row, the provider's book and the
    /// owner's account — and the row is the only new one.
    function test_claim_writes_one_new_slot_for_the_job() public {
        Order memory o = _ref(0);
        uint64 t = uint64(block.timestamp);
        (bytes memory os, bytes memory cs) = _claimSigs(o);
        vm.record();
        jr.claim(o, client, os, t, cs);
        (, bytes32[] memory writes) = vm.accesses(address(jr));
        bytes32 rowSlot = keccak256(abi.encode(_jobId(o), uint256(3))); // `jobs` is storage slot 3
        uint256 distinct;
        bool rowWritten;
        for (uint256 i; i < writes.length; i++) {
            bool seen;
            for (uint256 k; k < i; k++) {
                if (writes[k] == writes[i]) seen = true;
            }
            if (!seen) distinct++;
            if (writes[i] == rowSlot) rowWritten = true;
        }
        assertEq(distinct, 3);
        assertTrue(rowWritten, "the row lives at jobs[jobId]");
        // and the row decodes: providerId | claimedAt << 32 | state << 72 | ended << 80 | termsHash << 88
        uint256 row = uint256(vm.load(address(jr), rowSlot));
        assertEq(uint32(row), pid);
        assertEq(uint40(row >> 32), t);
        assertEq(uint8(row >> 72), 1);
        assertEq(uint8(row >> 80), 0);
        assertEq(bytes21(uint168(row >> 88)), bytes21(keccak256(abi.encode(_termsFor(jr, o)))));
        assertEq(vm.load(address(jr), bytes32(uint256(rowSlot) + 1)), bytes32(0), "nothing past the one slot");
    }

    function test_claim_locks_the_gas_fee_live_at_claim_and_announces_it() public {
        vm.prank(curation);
        jr.setFees(100, 7, 0);
        Order memory o = _ref(0);
        uint64 t = uint64(block.timestamp);
        (bytes memory os, bytes memory cs) = _claimSigs(o);
        _expectPosted(o, 7);
        jr.claim(o, client, os, t, cs);
        assertEq(jr.balanceOf(client), START - 219); // 210 + 2 + the gas fee 7
    }

    function test_a_designated_order_claims_for_its_provider() public {
        bytes32 jobId = _claim(_ref(pid));
        assertEq(jr.getJob(jobId).providerId, pid);
        assertEq(jr.balanceOf(client), START - REF_LOCK);
    }

    // ── the order's gates (payload, SLA, expiry, catalog, signature, unused id) ───────────────

    function test_order_gates() public {
        Order memory o = _ref(0);
        o.taskCid = "";
        _claimRevertsSel(o, JobRegistry.EmptyTaskCid.selector);

        o = _ref(0);
        o.slaSecs = 1234;
        _claimRevertsSel(o, JobRegistry.SlaNotAllowed.selector);

        o = _ref(0);
        o.expiresAt = uint64(block.timestamp - 1); // strictly past
        _claimRevertsSel(o, JobRegistry.AlreadyExpired.selector);

        o = _ref(0);
        o.expiresAt = uint64(block.timestamp + 86401);
        _claimRevertsSel(o, JobRegistry.ExpiryTooFar.selector);

        o = _ref(0);
        o.modelId = 9;
        _claimRevertsSel(o, JobRegistry.UnknownModel.selector);

        o = _ref(0);
        vm.prank(curation);
        reg.setModelEnabled(1, false); // the model kill switch gates claim
        _claimRevertsSel(o, JobRegistry.ModelDisabled.selector);
        vm.prank(curation);
        reg.setModelEnabled(1, true);

        // the MAX_EXPIRY ceiling is INCLUSIVE — exactly 86400 s out is a legal order
        o = _refC(keccak256("max-expiry"));
        o.expiresAt = uint64(block.timestamp + jr.MAX_EXPIRY());
        assertTrue(jr.getJob(_claim(o)).found);
    }

    function test_expiry_is_strictly_past_expiresAt() public {
        Order memory o = _ref(0);
        vm.warp(o.expiresAt); // exactly on the expiry second the order still claims
        assertEq(jr.getJob(_claim(o)).state, 1);

        Order memory late = _refC(keccak256("late"));
        vm.warp(late.expiresAt + 1);
        _claimRevertsSelAfterLock(late, JobRegistry.AlreadyExpired.selector);
    }

    // Each order below trips its own gate AND carries a signature from the wrong key, and must still
    // answer its own gate rather than InvalidOrderSignature — the published ladder, pinned from the
    // other side.
    function test_order_gates_precede_the_signature_check() public {
        uint64 t = uint64(block.timestamp);
        Order memory o = _ref(0);
        o.slaSecs = 1234;
        bytes memory bad = OrderSig.signOrder(vm, 0xBAD, jr, o);
        bytes memory cs = OpSig.signClaim(vm, opPk, jr, _jobId(o), t);
        vm.expectRevert(JobRegistry.SlaNotAllowed.selector);
        jr.claim(o, client, bad, t, cs);

        o = _ref(0);
        o.expiresAt = uint64(block.timestamp - 1);
        bad = OrderSig.signOrder(vm, 0xBAD, jr, o);
        vm.expectRevert(JobRegistry.AlreadyExpired.selector);
        jr.claim(o, client, bad, t, cs);

        o = _ref(0);
        o.expiresAt = uint64(block.timestamp + 86401);
        bad = OrderSig.signOrder(vm, 0xBAD, jr, o);
        vm.expectRevert(JobRegistry.ExpiryTooFar.selector);
        jr.claim(o, client, bad, t, cs);

        o = _ref(0);
        o.modelId = 9;
        bad = OrderSig.signOrder(vm, 0xBAD, jr, o);
        vm.expectRevert(JobRegistry.UnknownModel.selector);
        jr.claim(o, client, bad, t, cs);

        o = _ref(0);
        bad = OrderSig.signOrder(vm, 0xBAD, jr, o);
        vm.prank(curation);
        reg.setModelEnabled(1, false);
        vm.expectRevert(JobRegistry.ModelDisabled.selector);
        jr.claim(o, client, bad, t, cs);

        // with the catalog restored the SAME bad signature now reaches the signature gate
        vm.prank(curation);
        reg.setModelEnabled(1, true);
        vm.expectRevert(JobRegistry.InvalidOrderSignature.selector);
        jr.claim(o, client, bad, t, cs);
        assertFalse(jr.getJob(_jobId(o)).found);
    }

    function test_claim_refuses_a_wrong_order_signer_and_a_used_id() public {
        Order memory o = _ref(0);
        uint64 t = uint64(block.timestamp);
        bytes memory badSig = OrderSig.signOrder(vm, 0xBAD, jr, o);
        bytes memory cs = OpSig.signClaim(vm, opPk, jr, _jobId(o), t);
        vm.expectRevert(JobRegistry.InvalidOrderSignature.selector);
        jr.claim(o, client, badSig, t, cs);
        _claim(o);
        // the signature gate runs BEFORE the used-id gate
        vm.expectRevert(JobRegistry.InvalidOrderSignature.selector);
        jr.claim(o, client, badSig, t, cs);
        bytes memory goodSig = OrderSig.signOrder(vm, clientPk, jr, o);
        vm.expectRevert(JobRegistry.NotOpen.selector); // the state machine is the replay guard
        jr.claim(o, client, goodSig, t, cs);
        assertEq(jr.balanceOf(client), START - REF_LOCK); // locked exactly once
        assertEq(jr.activeJobs(pid), 1);
    }

    function test_claim_refuses_a_zero_recovered_order_signer() public {
        Order memory o = _ref(0);
        uint64 t = uint64(block.timestamp);
        bytes memory cs = OpSig.signClaim(vm, opPk, jr, _jobId(o), t);
        vm.expectRevert(JobRegistry.InvalidOrderSignature.selector);
        jr.claim(o, client, "", t, cs); // empty: length check
        vm.expectRevert(JobRegistry.InvalidOrderSignature.selector);
        jr.claim(o, client, new bytes(64), t, cs); // 64 bytes: length check
        vm.expectRevert(JobRegistry.InvalidOrderSignature.selector);
        jr.claim(o, client, new bytes(65), t, cs); // 65 zero bytes: ecrecover answers address(0)
        // and a zero owner must never authorize itself off a malformed signature
        bytes memory zeroCs = OpSig.signClaim(vm, opPk, jr, keccak256(abi.encodePacked(address(0), o.c)), t);
        vm.expectRevert(JobRegistry.InvalidOrderSignature.selector);
        jr.claim(o, address(0), new bytes(65), t, zeroCs);
        assertFalse(jr.getJob(_jobId(o)).found);
    }

    /// `taskCid` is NOT in `ORDER_TYPEHASH`: one order signature claims under any CID, and the CID
    /// the relayer supplied is the one `Posted` announces.
    function test_one_order_signature_claims_under_any_task_cid() public {
        Order memory o = _ref(0);
        uint64 t = uint64(block.timestamp);
        (bytes memory os, bytes memory cs) = _claimSigs(o); // signed while the CID is unknown
        o.taskCid = bytes("bafy-minted-by-the-storage-service");
        vm.recordLogs();
        jr.claim(o, client, os, t, cs);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (,,,,,,,,, bytes memory cid) = abi.decode(
            logs[0].data, (address, bytes32, uint64, uint32, uint128, uint128, uint32, uint32, uint128, bytes)
        );
        assertEq(cid, o.taskCid);
    }

    /// `c` — the keccak of the ciphertext — is signed, and it is what binds the payload.
    function test_c_binds_the_payload_under_a_valid_order_signature() public {
        Order memory o = _ref(0);
        uint64 t = uint64(block.timestamp);
        bytes memory os = OrderSig.signOrder(vm, clientPk, jr, o);
        Order memory tampered = _ref(0);
        tampered.c = keccak256("a different ciphertext entirely");
        bytes memory cs = OpSig.signClaim(vm, opPk, jr, _jobId(tampered), t);
        vm.expectRevert(JobRegistry.InvalidOrderSignature.selector);
        jr.claim(tampered, client, os, t, cs);
        assertFalse(jr.getJob(_jobId(tampered)).found);
        _claim(o); // the untampered order still lands
    }

    function test_setSlaAllowed_extends_and_revokes_an_sla_at_claim() public {
        Order memory o = _ref(0);
        o.slaSecs = 1800;
        _claimRevertsSel(o, JobRegistry.SlaNotAllowed.selector);
        vm.prank(curation);
        vm.expectEmit(false, false, false, true);
        emit JobRegistry.SlaAllowedChanged(1800, true);
        jr.setSlaAllowed(1800, true);
        bytes32 jobId = _claim(o);
        // revoking gates future claims only — a claimed job keeps its SLA
        vm.prank(curation);
        jr.setSlaAllowed(1800, false);
        vm.warp(block.timestamp + 1800);
        _settle(opPk, jobId, 100, bytes("r"));
        assertEq(jr.getJob(jobId).state, 2);
    }

    // ── the provider's gates ──────────────────────────────────────────────────────────────────

    function test_stale_and_future_issuedAt_revert() public {
        Order memory o = _ref(0);
        bytes memory os = OrderSig.signOrder(vm, clientPk, jr, o);
        vm.warp(block.timestamp + 700); // order still live (expiry +3600); the op is what went stale
        uint64 old = uint64(block.timestamp) - 601;
        bytes memory oldSig = OpSig.signClaim(vm, opPk, jr, _jobId(o), old);
        vm.expectRevert(JobRegistry.StaleOp.selector);
        jr.claim(o, client, os, old, oldSig);
        uint64 future = uint64(block.timestamp) + 601;
        bytes memory futureSig = OpSig.signClaim(vm, opPk, jr, _jobId(o), future);
        vm.expectRevert(JobRegistry.StaleOp.selector);
        jr.claim(o, client, os, future, futureSig);
        assertFalse(jr.getJob(_jobId(o)).found);
    }

    function test_staleness_window_is_inclusive_at_both_ends() public {
        Order memory a = _ref(0);
        Order memory b = _ref(pid);
        vm.warp(block.timestamp + 700);
        uint64 t = uint64(block.timestamp);
        uint64 oldest = t - 600;
        jr.claim(
            a, client, OrderSig.signOrder(vm, clientPk, jr, a), oldest, OpSig.signClaim(vm, opPk, jr, _jobId(a), oldest)
        );
        uint64 newest = t + 600;
        jr.claim(
            b, client, OrderSig.signOrder(vm, clientPk, jr, b), newest, OpSig.signClaim(vm, opPk, jr, _jobId(b), newest)
        );
        assertEq(jr.getJob(_jobId(a)).state, 1);
        assertEq(jr.getJob(_jobId(b)).state, 1);
        assertEq(jr.activeJobs(pid), 2);
    }

    function test_stale_op_is_checked_before_provider_resolution() public {
        Order memory o = _ref(0);
        bytes memory os = OrderSig.signOrder(vm, clientPk, jr, o);
        vm.warp(block.timestamp + 700);
        uint64 old = uint64(block.timestamp) - 601;
        bytes memory strangerSig = OpSig.signClaim(vm, 0xBAD, jr, _jobId(o), old);
        vm.expectRevert(JobRegistry.StaleOp.selector); // staleness precedes idOf
        jr.claim(o, client, os, old, strangerSig);
    }

    function test_claim_refuses_a_zero_recovered_signer() public {
        Order memory o = _ref(0);
        uint64 t = uint64(block.timestamp);
        bytes memory os = OrderSig.signOrder(vm, clientPk, jr, o);
        vm.expectRevert(JobRegistry.UnknownProvider.selector);
        jr.claim(o, client, os, t, ""); // empty: the 65-byte length check answers address(0)
        vm.expectRevert(JobRegistry.UnknownProvider.selector);
        jr.claim(o, client, os, t, new bytes(64));
        vm.expectRevert(JobRegistry.UnknownProvider.selector);
        jr.claim(o, client, os, t, new bytes(65)); // 65 zero bytes: ecrecover itself answers address(0)
        assertFalse(jr.getJob(_jobId(o)).found);
    }

    function test_claim_refuses_a_zero_signer_even_when_a_record_maps_the_zero_address() public {
        // R15, defense in depth. This stands up a registry where the zero address IS a provider:
        // without the guard a 65-zero-byte signature authenticates as that provider.
        ZeroSignerRegistry reg2 = new ZeroSignerRegistry(curation);
        JobRegistry jr2 = new JobRegistry(reg2, IUSDC(USDC), curation, treasury);
        vm.startPrank(curation);
        reg2.setJobRegistry(address(jr2), true);
        reg2.registerModel("model-a:fp8");
        uint32 pid2 = reg2.register(op, 16, true, 1000); // listed, allowAllModels, effectiveCap >= 1
        jr2.setFees(100, 0, 0);
        vm.stopPrank();
        reg2.forceZeroSignerRecord(pid2);
        _deposit(jr2, 1000);

        Order memory o = _refC(keccak256("zero-signer"));
        bytes memory os = OrderSig.signOrder(vm, clientPk, jr2, o);
        vm.expectRevert(JobRegistry.UnknownProvider.selector);
        jr2.claim(o, client, os, uint64(block.timestamp), new bytes(65));
        assertFalse(jr2.getJob(_jobId(o)).found);
        assertEq(jr2.balanceOf(client), 1000);
    }

    function test_gate_order_unknown_then_listed_then_model_then_designated_then_capacity() public {
        Order memory o = _ref(0);
        uint64 t = uint64(block.timestamp);
        bytes memory os = OrderSig.signOrder(vm, clientPk, jr, o);
        bytes memory strangerSig = OpSig.signClaim(vm, 0xBAD, jr, _jobId(o), t);
        // an unregistered signer must answer UnknownProvider BEFORE any _rec-gated registry view
        vm.expectRevert(JobRegistry.UnknownProvider.selector);
        jr.claim(o, client, os, t, strangerSig);

        uint32[] memory none = new uint32[](0);
        // unlisted AND with every model revoked: NotListed has to win
        vm.startPrank(curation);
        reg.setListed(pid, false);
        reg.setAllowedModels(pid, none, false);
        vm.stopPrank();
        (, bytes memory cs) = _claimSigs(o);
        vm.expectRevert(JobRegistry.NotListed.selector);
        jr.claim(o, client, os, t, cs);
        vm.prank(curation);
        reg.setListed(pid, true);

        // listed again, models still revoked, and this order is designated elsewhere:
        // ModelNotAllowed has to win over NotDesignated
        Order memory d = _ref(99);
        (bytes memory dos, bytes memory dcs) = _claimSigs(d);
        vm.expectRevert(JobRegistry.ModelNotAllowed.selector);
        jr.claim(d, client, dos, t, dcs);
        vm.prank(curation);
        reg.setAllowedModels(pid, none, true);

        // now only the designation is wrong — checked against the SIGNER's id, never msg.sender
        vm.expectRevert(JobRegistry.NotDesignated.selector);
        jr.claim(d, client, dos, t, dcs);

        assertFalse(jr.getJob(_jobId(o)).found);
        assertFalse(jr.getJob(_jobId(d)).found);
        assertEq(jr.balanceOf(client), START);
        assertEq(jr.activeJobs(pid), 0);
    }

    function test_capacity_gate_uses_effectiveCap() public {
        _requestCapacity(1); // effectiveCap = 1000 * min(1, 16) / 1000 = 1
        _claim(_ref(0));
        assertEq(jr.activeJobs(pid), 1);

        // designation is checked BEFORE capacity: this order is over capacity too, yet the answer
        // is NotDesignated
        _claimRevertsSelAfterLock(_ref(7), JobRegistry.NotDesignated.selector);

        // an undesignated second order hits AtCapacity. cap = ceil(90_000 * 1000 / 1e6) = 90, and
        // its fee ceiling floors away: 90*100/10000 = 0, so it locks the bare 90.
        Order memory o2 = _orderWith(keccak256("second"), 0, 0, 90_000, 1000);
        _claimRevertsSelAfterLock(o2, JobRegistry.AtCapacity.selector);

        // the ceiling is read live, not snapshotted: granting more lets the same order through
        _requestCapacity(2);
        _claim(o2);
        assertEq(jr.activeJobs(pid), 2);
        assertEq(jr.balanceOf(client), START - REF_LOCK - 90);
    }

    function test_capacity_gate_precedes_the_funds_check() public {
        _requestCapacity(1);
        _claim(_ref(0));
        _drainTo(0); // nothing left to lock, so a funds check could only fail…
        _claimRevertsSelAfterLock(_refC(keccak256("cap-vs-funds")), JobRegistry.AtCapacity.selector); // …and the gate answers first
    }

    // ── the funds gate and the money math ─────────────────────────────────────────────────────

    function test_a_short_balance_answers_InsufficientDeposit_and_an_exact_one_claims() public {
        Order memory o = _ref(0);
        _drainTo(REF_LOCK - 1);
        _claimRevertsSelAfterLock(o, JobRegistry.InsufficientDeposit.selector);
        assertFalse(jr.getJob(_jobId(o)).found);
        assertEq(jr.activeJobs(pid), 0);
        // topped up by one atomic unit, the same order claims and the balance is exactly spent
        _deposit(jr, 1);
        _claim(o);
        assertEq(jr.balanceOf(client), 0);
    }

    function test_cap_is_ceiling_division_and_never_zero() public {
        // one atomic unit of raw cost still costs 1 after ceiling division
        _claim(_orderWith(keccak256("cap-1"), 1, 1, 0, 0));
        assertEq(jr.balanceOf(client), START - 1);
        // 1.5 * RATE_SCALE rounds UP, never down
        _claim(_orderWith(keccak256("cap-2"), 1, 1_500_000, 0, 0));
        assertEq(jr.balanceOf(client), START - 3);
        // a free order still locks the 1-unit floor
        _claim(_orderWith(keccak256("cap-0"), 0, 0, 0, 0));
        assertEq(jr.balanceOf(client), START - 4); // 1 + 2 + 1: every fee ceiling floors to 0
        assertEq(jr.activeJobs(pid), 3);
    }

    function test_cap_that_cannot_fit_uint128_reverts_instead_of_truncating() public {
        Order memory huge = _orderWith(keccak256("cap-overflow"), type(uint128).max, type(uint32).max, 0, 0);
        _claimRevertsSelAfterLock(huge, JobRegistry.CapOverflow.selector);
    }

    // ── configuration ─────────────────────────────────────────────────────────────────────────

    function test_unknown_id_returns_zeroed_body_not_revert() public view {
        JobView memory v = jr.getJob(keccak256("nope"));
        assertFalse(v.found);
        assertEq(v.jobId, bytes32(0));
        assertEq(v.providerId, 0);
    }

    // the signing helpers read these typehashes off the contract, so a wrong type string would
    // round-trip through every other test. This is the check that an external client can
    // reproduce the digest.
    function test_job_op_typehashes_are_byte_exact() public view {
        assertEq(
            jr.ORDER_TYPEHASH(),
            keccak256(
                "Order(bytes32 c,uint32 modelId,uint32 slaSecs,uint128 rateIn,uint128 rateOut,uint32 unitsIn,uint32 unitsOut,uint32 designated,uint64 expiresAt)"
            )
        );
        assertEq(jr.CLAIM_TYPEHASH(), keccak256("Claim(bytes32 jobId,uint64 issuedAt)"));
        assertEq(
            jr.SETTLE_TYPEHASH(),
            keccak256(
                "Settle(bytes32 jobId,uint32 promptTok,uint32 cachedTok,uint32 completionTok,uint128 rateInCached,uint64 issuedAt)"
            )
        );
        assertEq(jr.FAIL_TYPEHASH(), keccak256("Fail(bytes32 jobId,uint64 issuedAt)"));
        assertEq(jr.CANCEL_TYPEHASH(), keccak256("Cancel(bytes32 jobId,uint64 issuedAt)"));
        assertEq(jr.WITHDRAW_TYPEHASH(), keccak256("Withdraw(uint128 amount,uint64 issuedAt)"));
    }

    function test_domain_separator_is_the_v2_domain_over_this_contract() public view {
        assertEq(
            jr.DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes(jr.EIP712_NAME())),
                    keccak256("2"),
                    block.chainid,
                    address(jr)
                )
            )
        );
        assertTrue(jr.DOMAIN_SEPARATOR() != reg.DOMAIN_SEPARATOR());
    }

    function test_protocol_constants_are_the_global_values() public view {
        assertEq(jr.MAX_EXPIRY(), 86400);
        assertEq(jr.FAIL_GRACE(), 300);
        assertEq(jr.RATE_SCALE(), 1_000_000);
    }

    function test_constructor_seeds_slas_fees_and_treasury_and_emits_them() public {
        address tre = makeAddr("treasury2");
        vm.expectEmit(false, false, false, true);
        emit JobRegistry.SlaAllowedChanged(3600, true);
        vm.expectEmit(false, false, false, true);
        emit JobRegistry.SlaAllowedChanged(86400, true);
        vm.expectEmit(false, false, false, true);
        emit JobRegistry.FeesChanged(100, 3_000, 2_000);
        vm.expectEmit(false, false, false, true);
        emit JobRegistry.TreasuryChanged(tre);
        JobRegistry fresh = new JobRegistry(reg, IUSDC(USDC), curation, tre);
        assertTrue(fresh.allowedSla(3600));
        assertTrue(fresh.allowedSla(86400));
        assertFalse(fresh.allowedSla(1800));
        assertEq(fresh.feeBps(), 100);
        assertEq(fresh.gasFee(), 3_000); // $0.003
        assertEq(fresh.depositFee(), 2_000); // $0.002
        assertEq(fresh.treasury(), tre);
        assertEq(fresh.curation(), curation);
        assertEq(address(fresh.registry()), address(reg));
        assertEq(address(fresh.usdc()), USDC);
        assertEq(fresh.activeJobs(1), 0);
        assertEq(fresh.accrued(), 0);
    }

    function test_config_setters_are_curation_only() public {
        vm.expectRevert(JobRegistry.NotCuration.selector);
        jr.setFees(1, 1, 1);
        vm.expectRevert(JobRegistry.NotCuration.selector);
        jr.setSlaAllowed(60, true);
        vm.expectRevert(JobRegistry.NotCuration.selector);
        jr.setTreasury(address(1));
        assertEq(jr.feeBps(), 100);
        assertEq(jr.gasFee(), 0);
        assertFalse(jr.allowedSla(60));
    }

    function test_config_setters_emit_and_persist() public {
        vm.prank(curation);
        vm.expectEmit(false, false, false, true);
        emit JobRegistry.FeesChanged(1000, 5, 9);
        jr.setFees(1000, 5, 9); // 1000 bps is the inclusive ceiling
        assertEq(jr.feeBps(), 1000);
        assertEq(jr.gasFee(), 5);
        assertEq(jr.depositFee(), 9);

        vm.prank(curation);
        vm.expectEmit(false, false, false, true);
        emit JobRegistry.TreasuryChanged(address(0xFEE));
        jr.setTreasury(address(0xFEE));
        assertEq(jr.treasury(), address(0xFEE));
    }

    function test_setFees_rejects_above_ten_percent() public {
        vm.prank(curation);
        vm.expectRevert(JobRegistry.FeeTooHigh.selector);
        jr.setFees(1001, 0, 0);
    }

    /// `treasury`, `feeBps` and `gasFee` share storage slot 0, which is what lets claim read both
    /// fees in one load.
    function test_treasury_feeBps_and_gasFee_share_one_slot() public {
        vm.prank(curation);
        jr.setFees(250, 7, 9);
        uint256 s0 = uint256(vm.load(address(jr), bytes32(uint256(0))));
        assertEq(address(uint160(s0)), treasury);
        assertEq(uint16(s0 >> 160), 250);
        assertEq(uint64(s0 >> 176), 7);
        uint256 s1 = uint256(vm.load(address(jr), bytes32(uint256(1))));
        assertEq(uint128(s1), jr.accrued());
        assertEq(uint64(s1 >> 128), 9);
    }

    // ── helpers ───────────────────────────────────────────────────────────────────────────────

    /// @dev its own frame: thirteen event arguments do not fit beside a test body's locals
    function _expectPosted(Order memory o, uint128 gas) private {
        vm.expectEmit(true, true, true, true, address(jr));
        emit JobRegistry.Posted(
            _jobId(o),
            o.modelId,
            o.designated,
            client,
            o.c,
            o.expiresAt,
            o.slaSecs,
            o.rateIn,
            o.rateOut,
            o.unitsIn,
            o.unitsOut,
            gas,
            o.taskCid
        );
    }

    /// @dev pre-signed claim that must revert with `sel`; the balance is whatever it was before
    function _claimRevertsSelAfterLock(Order memory o, bytes4 sel) private {
        uint256 before = jr.balanceOf(client);
        uint64 t = uint64(block.timestamp);
        (bytes memory os, bytes memory cs) = _claimSigs(o);
        vm.expectRevert(sel);
        jr.claim(o, client, os, t, cs);
        assertFalse(jr.getJob(_jobId(o)).found);
        assertEq(jr.balanceOf(client), before);
    }

    /// @dev withdraws the client's balance down to exactly `left`
    function _drainTo(uint256 left) private {
        uint128 amount = uint128(jr.balanceOf(client) - left);
        uint64 t = uint64(block.timestamp);
        jr.withdraw(client, amount, t, OpSig.signWithdraw(vm, clientPk, jr, amount, t));
        assertEq(jr.balanceOf(client), left);
    }
}
