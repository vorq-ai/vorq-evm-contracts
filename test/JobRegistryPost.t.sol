// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {JobRegistry, IUSDC} from "../src/JobRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import "../src/Types.sol";
import {OrderSig} from "./utils/OrderSig.sol";

contract JobRegistryPostTest is Test {
    JobRegistry jr;
    ProviderRegistry reg;
    address curation = makeAddr("curation");
    uint256 clientPk = 0xC11E47;
    address client;

    function setUp() public {
        client = vm.addr(clientPk);
        reg = new ProviderRegistry(curation);
        jr = new JobRegistry(reg, IUSDC(makeAddr("usdc")), curation, makeAddr("treasury"));
        vm.prank(curation);
        reg.setJobRegistry(address(jr), true);
        vm.prank(curation);
        reg.registerModel("model-a:fp8"); // modelId 1
    }

    function baseOrder() internal view returns (Order memory o) {
        o = Order({
            c: keccak256("commitment"),
            modelId: 1,
            slaSecs: 3600,
            rateIn: 30_000,
            rateOut: 90_000,
            unitsIn: 1000,
            unitsOut: 2000,
            designated: 0,
            expiresAt: uint64(block.timestamp + 3600),
            taskCid: bytes("bafy-task")
        });
    }

    function test_post_derives_jobId_and_emits_fat_Posted() public {
        Order memory o = baseOrder();
        bytes32 jobId = keccak256(abi.encodePacked(client, o.c));
        vm.expectEmit(true, true, true, true);
        emit JobRegistry.Posted(
            jobId,
            1,
            0,
            client,
            o.c,
            o.expiresAt,
            3600,
            o.rateIn,
            o.rateOut,
            o.unitsIn,
            o.unitsOut,
            jr.gasFee(),
            o.taskCid
        );
        jr.post(o, client, OrderSig.signOrder(vm, clientPk, jr, o), "");
        JobView memory v = jr.getJob(jobId);
        assertTrue(v.found);
        assertEq(v.jobId, jobId);
        assertEq(uint8(v.state), 0);
        assertEq(v.owner, client);
        assertEq(v.taskCid, o.taskCid);
        assertEq(v.resultCid, bytes(""));
    }

    function test_unknown_id_returns_zeroed_body_not_revert() public view {
        JobView memory v = jr.getJob(keccak256("nope"));
        assertFalse(v.found);
        assertEq(v.owner, address(0));
        assertEq(v.taskCid.length, 0);
    }

    function test_post_validation_gates() public {
        Order memory o = baseOrder();
        o.taskCid = "";
        vm.expectRevert(JobRegistry.EmptyTaskCid.selector);
        jr.post(o, client, "", "");

        o = baseOrder();
        o.slaSecs = 1234;
        bytes memory slaSig = OrderSig.signOrder(vm, clientPk, jr, o);
        vm.expectRevert(JobRegistry.SlaNotAllowed.selector);
        jr.post(o, client, slaSig, "");

        // an order that expires exactly now is already dead — the gate is strict
        o = baseOrder();
        o.expiresAt = uint64(block.timestamp);
        bytes memory nowSig = OrderSig.signOrder(vm, clientPk, jr, o);
        vm.expectRevert(JobRegistry.AlreadyExpired.selector);
        jr.post(o, client, nowSig, "");

        o = baseOrder();
        o.expiresAt = uint64(block.timestamp + 86401);
        bytes memory farSig = OrderSig.signOrder(vm, clientPk, jr, o);
        vm.expectRevert(JobRegistry.ExpiryTooFar.selector);
        jr.post(o, client, farSig, "");

        // the MAX_EXPIRY ceiling is INCLUSIVE — exactly 86400 s out is a legal order, which is
        // what stops the gate drifting to `>=`. A fresh `c` keeps the base commitment unposted
        // so the closing assertion below still holds.
        Order memory maxO = baseOrder();
        maxO.c = keccak256("max-expiry");
        maxO.expiresAt = uint64(block.timestamp + jr.MAX_EXPIRY());
        jr.post(maxO, client, OrderSig.signOrder(vm, clientPk, jr, maxO), "");
        assertTrue(jr.getJob(keccak256(abi.encodePacked(client, maxO.c))).found);

        o = baseOrder();
        o.modelId = 9;
        bytes memory unknownSig = OrderSig.signOrder(vm, clientPk, jr, o);
        vm.expectRevert(JobRegistry.UnknownModel.selector);
        jr.post(o, client, unknownSig, "");

        o = baseOrder();
        bytes memory disabledSig = OrderSig.signOrder(vm, clientPk, jr, o);
        vm.prank(curation);
        reg.setModelEnabled(1, false);
        vm.expectRevert(JobRegistry.ModelDisabled.selector);
        jr.post(o, client, disabledSig, "");
        vm.prank(curation);
        reg.setModelEnabled(1, true);

        // every refusal above was against the base commitment, and it is still unposted — only
        // the inclusive-ceiling case landed a row, and it used a `c` of its own
        assertFalse(jr.getJob(keccak256(abi.encodePacked(client, o.c))).found);
    }

    // Gates 2-6 are each exercised above with a VALID order signature, so every one of those cases
    // would survive gate 7 (InvalidOrderSignature) being hoisted above them: a good signature simply
    // passes it. The README publishes the ladder as part of the contract, so it has to be pinned from
    // the other side too — each order below trips its own gate AND carries a signature from the wrong
    // key, and must still answer its own gate rather than InvalidOrderSignature.
    // R1: every signature is hoisted to the line before `vm.expectRevert`, because OrderSig reads the
    // typehash and the domain separator off the contract.
    function test_post_gates_two_through_six_precede_the_signature_check() public {
        Order memory o = baseOrder();
        o.slaSecs = 1234;
        bytes memory badSla = OrderSig.signOrder(vm, 0xBAD, jr, o);
        vm.expectRevert(JobRegistry.SlaNotAllowed.selector);
        jr.post(o, client, badSla, "");

        o = baseOrder();
        o.expiresAt = uint64(block.timestamp);
        bytes memory badNow = OrderSig.signOrder(vm, 0xBAD, jr, o);
        vm.expectRevert(JobRegistry.AlreadyExpired.selector);
        jr.post(o, client, badNow, "");

        o = baseOrder();
        o.expiresAt = uint64(block.timestamp + 86401);
        bytes memory badFar = OrderSig.signOrder(vm, 0xBAD, jr, o);
        vm.expectRevert(JobRegistry.ExpiryTooFar.selector);
        jr.post(o, client, badFar, "");

        o = baseOrder();
        o.modelId = 9;
        bytes memory badModel = OrderSig.signOrder(vm, 0xBAD, jr, o);
        vm.expectRevert(JobRegistry.UnknownModel.selector);
        jr.post(o, client, badModel, "");

        o = baseOrder();
        bytes memory badDisabled = OrderSig.signOrder(vm, 0xBAD, jr, o);
        vm.prank(curation);
        reg.setModelEnabled(1, false);
        vm.expectRevert(JobRegistry.ModelDisabled.selector);
        jr.post(o, client, badDisabled, "");

        // and with the catalog restored the SAME bad signature now reaches gate 7, which is what
        // proves the five answers above were the earlier gates and not a coincidence
        vm.prank(curation);
        reg.setModelEnabled(1, true);
        vm.expectRevert(JobRegistry.InvalidOrderSignature.selector);
        jr.post(o, client, badDisabled, "");
        assertFalse(jr.getJob(keccak256(abi.encodePacked(client, o.c))).found);
    }

    function test_setFees_rejects_above_ten_percent() public {
        vm.prank(curation);
        vm.expectRevert(JobRegistry.FeeTooHigh.selector);
        jr.setFees(1001, 0);
    }

    function test_post_refuses_wrong_signer_and_duplicates() public {
        Order memory o = baseOrder();
        bytes memory badSig = OrderSig.signOrder(vm, 0xBAD, jr, o);
        vm.expectRevert(JobRegistry.InvalidOrderSignature.selector);
        jr.post(o, client, badSig, "");
        jr.post(o, client, OrderSig.signOrder(vm, clientPk, jr, o), "");
        // gate 7 runs BEFORE gate 8: a bad signature against an already-posted jobId must still
        // answer InvalidOrderSignature. Without this case both gates survive a swap, because the
        // two cases either side of it only ever trip one of them.
        bytes memory badDupSig = OrderSig.signOrder(vm, 0xBAD, jr, o);
        vm.expectRevert(JobRegistry.InvalidOrderSignature.selector);
        jr.post(o, client, badDupSig, "");
        bytes memory dupSig = OrderSig.signOrder(vm, clientPk, jr, o);
        vm.expectRevert(JobRegistry.DuplicateJob.selector);
        jr.post(o, client, dupSig, "");
    }

    /// `taskCid` is NOT in `ORDER_TYPEHASH`, so the digest a client signs is independent of it: the
    /// coordinator pins the payload and the storage service mints the name, which the client cannot
    /// know when it signs. One signature, byte for byte, must therefore post under two different
    /// CIDs — and the CID the relayer supplied is the one that lands on the row.
    function test_one_order_signature_posts_under_two_different_task_cids() public {
        Order memory o = baseOrder();
        bytes memory sig = OrderSig.signOrder(vm, clientPk, jr, o); // signed while the CID is unknown
        o.taskCid = bytes("bafy-minted-by-the-storage-service");
        jr.post(o, client, sig, "");
        assertEq(jr.getJob(keccak256(abi.encodePacked(client, o.c))).taskCid, o.taskCid);

        // and again with a different `c` (a second job) and a wholly different CID under its own
        // signature-over-the-same-fields, so the independence is not an artefact of one value
        Order memory p = baseOrder();
        p.c = keccak256("second-commitment");
        bytes memory pSig = OrderSig.signOrder(vm, clientPk, jr, p);
        p.taskCid = bytes("bafy-completely-other");
        jr.post(p, client, pSig, "");
        assertEq(jr.getJob(keccak256(abi.encodePacked(client, p.c))).taskCid, p.taskCid);
    }

    /// The counterpart the change must NOT touch: `c` — the keccak of the ciphertext — is still
    /// signed, and it is what binds the payload now that `taskCid` does not. Swapping it under a
    /// valid signature is refused, so nothing about content integrity moved to the CID.
    function test_c_still_binds_the_payload_under_a_valid_order_signature() public {
        Order memory o = baseOrder();
        bytes memory sig = OrderSig.signOrder(vm, clientPk, jr, o);
        // a SECOND `baseOrder()`, not `= o`: assigning one memory struct to another copies the
        // reference, so mutating `tampered` would silently mutate `o` and the honest post below
        // would be posting the tampered order too
        Order memory tampered = baseOrder();
        tampered.c = keccak256("a different ciphertext entirely");
        vm.expectRevert(JobRegistry.InvalidOrderSignature.selector);
        jr.post(tampered, client, sig, "");
        assertFalse(jr.getJob(keccak256(abi.encodePacked(client, tampered.c))).found);
        jr.post(o, client, sig, ""); // the untampered order still lands
        assertTrue(jr.getJob(keccak256(abi.encodePacked(client, o.c))).found);
    }

    function test_expired_open_job_reads_cancelled_expired() public {
        Order memory o = baseOrder();
        bytes32 jobId = keccak256(abi.encodePacked(client, o.c));
        jr.post(o, client, OrderSig.signOrder(vm, clientPk, jr, o), "");
        vm.warp(o.expiresAt); // exactly at expiry the job is still Open — the boundary is strict
        assertEq(jr.getJob(jobId).state, 0);
        vm.warp(o.expiresAt + 1);
        JobView memory v = jr.getJob(jobId);
        assertEq(v.state, 3); // Cancelled at read time
        assertEq(v.endedBecause, 5); // expired — computed, never stored
        // proof it is derived, not persisted: winding the clock back restores Open
        vm.warp(o.expiresAt - 1);
        assertEq(jr.getJob(jobId).state, 0);
        assertEq(jr.getJob(jobId).endedBecause, 0);
    }

    // the signing helpers read these typehashes off the contract, so a wrong type string would
    // round-trip through every other test. This is the only check that an external client can
    // reproduce the digest — two later plans sign against these values.
    function test_job_op_typehashes_are_byte_exact() public view {
        // NEITHER CID IS A MEMBER: `taskCid`/`resultCid` are submitted, stored and logged, but the
        // coordinator learns each name from the storage service after the actor has already signed,
        // so neither can be attested. `c` is what binds the order's payload and it is still here.
        assertEq(
            jr.ORDER_TYPEHASH(),
            keccak256(
                "Order(bytes32 c,uint32 modelId,uint32 slaSecs,uint128 rateIn,uint128 rateOut,uint32 unitsIn,uint32 unitsOut,uint32 designated,uint64 expiresAt)"
            )
        );
        assertEq(jr.CLAIM_TYPEHASH(), keccak256("Claim(bytes32 jobId,uint64 issuedAt)"));
        assertEq(jr.SETTLE_TYPEHASH(), keccak256("Settle(bytes32 jobId,uint32 completionTok,uint64 issuedAt)"));
        assertEq(jr.FAIL_TYPEHASH(), keccak256("Fail(bytes32 jobId,uint64 issuedAt)"));
        assertEq(jr.CANCEL_TYPEHASH(), keccak256("Cancel(bytes32 jobId,uint64 issuedAt)"));
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
        // job ops verify against THIS registry's domain, never the provider registry's
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
        emit JobRegistry.FeesChanged(100, 30_000);
        vm.expectEmit(false, false, false, true);
        emit JobRegistry.TreasuryChanged(tre);
        JobRegistry fresh = new JobRegistry(reg, IUSDC(makeAddr("usdc")), curation, tre);
        assertTrue(fresh.allowedSla(3600));
        assertTrue(fresh.allowedSla(86400));
        assertFalse(fresh.allowedSla(1800));
        assertEq(fresh.feeBps(), 100);
        assertEq(fresh.gasFee(), 30_000);
        assertEq(fresh.treasury(), tre);
        assertEq(fresh.curation(), curation);
        assertEq(address(fresh.registry()), address(reg));
        assertEq(address(fresh.usdc()), makeAddr("usdc"));
        assertEq(fresh.activeJobs(1), 0); // claim maintains this; nothing is in flight yet
    }

    function test_config_setters_are_curation_only() public {
        vm.expectRevert(JobRegistry.NotCuration.selector);
        jr.setFees(1, 1);
        vm.expectRevert(JobRegistry.NotCuration.selector);
        jr.setSlaAllowed(60, true);
        vm.expectRevert(JobRegistry.NotCuration.selector);
        jr.setTreasury(address(1));
        assertEq(jr.feeBps(), 100);
        assertEq(jr.gasFee(), 30_000);
        assertFalse(jr.allowedSla(60));
    }

    function test_config_setters_emit_and_persist() public {
        vm.prank(curation);
        vm.expectEmit(false, false, false, true);
        emit JobRegistry.FeesChanged(1000, 5);
        jr.setFees(1000, 5); // 1000 bps is the inclusive ceiling
        assertEq(jr.feeBps(), 1000);
        assertEq(jr.gasFee(), 5);

        vm.prank(curation);
        vm.expectEmit(false, false, false, true);
        emit JobRegistry.TreasuryChanged(address(0xFEE));
        jr.setTreasury(address(0xFEE));
        assertEq(jr.treasury(), address(0xFEE));
    }

    function test_setSlaAllowed_extends_and_revokes_an_sla() public {
        Order memory o = baseOrder();
        o.slaSecs = 1800;
        bytes memory beforeSig = OrderSig.signOrder(vm, clientPk, jr, o);
        vm.expectRevert(JobRegistry.SlaNotAllowed.selector);
        jr.post(o, client, beforeSig, "");

        vm.prank(curation);
        vm.expectEmit(false, false, false, true);
        emit JobRegistry.SlaAllowedChanged(1800, true);
        jr.setSlaAllowed(1800, true);
        assertTrue(jr.allowedSla(1800));
        jr.post(o, client, OrderSig.signOrder(vm, clientPk, jr, o), "");

        // revoking gates future posts only — a landed job keeps its SLA
        vm.prank(curation);
        jr.setSlaAllowed(1800, false);
        assertFalse(jr.allowedSla(1800));
        JobView memory v = jr.getJob(keccak256(abi.encodePacked(client, o.c)));
        assertTrue(v.found);
        assertEq(v.slaSecs, 1800);
    }

    function test_post_refuses_a_zero_recovered_signer() public {
        Order memory o = baseOrder();
        vm.expectRevert(JobRegistry.InvalidOrderSignature.selector);
        jr.post(o, client, "", ""); // empty: length check
        vm.expectRevert(JobRegistry.InvalidOrderSignature.selector);
        jr.post(o, client, new bytes(64), ""); // 64 bytes: length check
        vm.expectRevert(JobRegistry.InvalidOrderSignature.selector);
        jr.post(o, client, new bytes(65), ""); // 65 zero bytes: ecrecover answers address(0)
        // and a zero owner must never authorize itself off a malformed signature
        vm.expectRevert(JobRegistry.InvalidOrderSignature.selector);
        jr.post(o, address(0), new bytes(65), "");
        assertFalse(jr.getJob(keccak256(abi.encodePacked(client, o.c))).found);
        assertFalse(jr.getJob(keccak256(abi.encodePacked(address(0), o.c))).found);
    }

    function test_getJob_maps_every_field_of_the_row() public {
        Order memory o = baseOrder();
        o.designated = 7; // never registered: post must not call a _rec-gated view on it
        bytes32 jobId = keccak256(abi.encodePacked(client, o.c));
        vm.expectEmit(true, true, true, true);
        emit JobRegistry.Posted(
            jobId,
            1,
            7,
            client,
            o.c,
            o.expiresAt,
            3600,
            o.rateIn,
            o.rateOut,
            o.unitsIn,
            o.unitsOut,
            jr.gasFee(),
            o.taskCid
        );
        jr.post(o, client, OrderSig.signOrder(vm, clientPk, jr, o), "");
        JobView memory v = jr.getJob(jobId);
        assertTrue(v.found);
        assertEq(v.jobId, jobId);
        assertEq(v.owner, client);
        assertEq(v.c, o.c);
        assertEq(v.state, 0);
        assertEq(v.endedBecause, 0);
        assertEq(v.providerId, 0); // claim sets this; designated is immutable after post
        assertEq(v.designated, 7);
        assertEq(v.modelId, 1);
        assertEq(v.rateIn, 30_000);
        assertEq(v.rateOut, 90_000);
        assertEq(v.unitsIn, 1000);
        assertEq(v.unitsOut, 2000);
        assertEq(v.completionTok, 0);
        assertEq(v.slaSecs, 3600);
        assertEq(v.expiresAt, o.expiresAt);
        assertEq(v.claimedAt, 0);
        assertEq(v.taskCid, o.taskCid);
        assertEq(v.resultCid, bytes(""));
    }

    function _harness() internal returns (JobRowHarness) {
        return new JobRowHarness(reg, IUSDC(makeAddr("usdc")), curation, makeAddr("treasury3"));
    }

    function test_post_snapshots_gasFee_and_stores_the_authorization_signature() public {
        JobRowHarness h = _harness();
        vm.prank(curation);
        h.setFees(250, 12345);
        Order memory o = baseOrder();
        bytes32 jobId = keccak256(abi.encodePacked(client, o.c));
        bytes memory authSig = hex"c0ffee";
        h.post(o, client, OrderSig.signOrder(vm, clientPk, h, o), authSig);
        JobRegistry.Job memory r = h.row(jobId);
        assertEq(r.gasFeeSnap, 12345); // claim pulls cap + the gas fee AS OF post
        assertEq(r.authSig, authSig); // claim consumes and deletes it
        // the seats Tasks 5-8 write into all start zeroed
        assertEq(r.state, 0);
        assertEq(r.endedBecause, 0);
        assertEq(r.providerId, 0);
        assertEq(r.claimedAt, 0);
        assertEq(r.cap, 0);
        assertEq(r.completionTok, 0);
        assertEq(r.resultCid, bytes(""));
        // a later GAS fee change must not disturb an already-posted row. feeBps stays at the 250
        // this test posted under: only the snapshotted half is under test here.
        vm.prank(curation);
        h.setFees(250, 999);
        assertEq(h.row(jobId).gasFeeSnap, 12345);
    }

    function test_read_time_expiry_only_rewrites_an_Open_row() public {
        JobRowHarness h = _harness();
        Order memory o = baseOrder();
        bytes32 jobId = keccak256(abi.encodePacked(client, o.c));
        h.post(o, client, OrderSig.signOrder(vm, clientPk, h, o), "");
        vm.warp(o.expiresAt + 1);
        // Claimed: escrow is funded and the SLA, not the order expiry, ends the job
        h.forceState(jobId, 1, ENDED_NONE);
        assertEq(h.getJob(jobId).state, 1);
        assertEq(h.getJob(jobId).endedBecause, ENDED_NONE);
        // Settled: a resolved row must never re-read as expired
        h.forceState(jobId, 2, ENDED_SETTLED);
        assertEq(h.getJob(jobId).state, 2);
        assertEq(h.getJob(jobId).endedBecause, ENDED_SETTLED);
        // Cancelled: the STORED cause supersedes the read-time 5
        h.forceState(jobId, 3, ENDED_CANCELLED);
        assertEq(h.getJob(jobId).state, 3);
        assertEq(h.getJob(jobId).endedBecause, ENDED_CANCELLED);
    }
}

// reads the stored row (the only way to assert the gasFee snapshot and the parked authorization
// signature before Task 5's claim consumes them) and forces a non-Open state, which nothing in
// Task 4 can otherwise produce — claim/settle/fail/cancel land in Tasks 5-8
contract JobRowHarness is JobRegistry {
    constructor(ProviderRegistry registry_, IUSDC usdc_, address curation_, address treasury_)
        JobRegistry(registry_, usdc_, curation_, treasury_)
    {}

    function row(bytes32 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }

    function forceState(bytes32 jobId, uint8 state, uint8 endedBecause) external {
        jobs[jobId].state = state;
        jobs[jobId].endedBecause = endedBecause;
    }
}
