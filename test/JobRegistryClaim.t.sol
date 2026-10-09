// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {JobRegistry, IUSDC} from "../src/JobRegistry.sol";
import "../src/Types.sol";
import {JobHarness} from "./utils/JobHarness.sol";
import {OrderSig} from "./utils/OrderSig.sol";
import {AuthSig} from "./utils/AuthSig.sol";
import {OpSig} from "./utils/OpSig.sol";
import {ZeroSignerRegistry} from "./utils/TestDoubles.sol";

contract JobRegistryClaimTest is JobHarness {
    /// @dev the payment token's own ERC-20 event, so the escrow pull is locatable in a recorded log
    bytes32 constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    uint256 internal constant REF_LOCK = 212; // cap 210 + feeCap 2 at this suite's 1% fee, gasFee 0

    /// @dev feeBps 100 — the protocol's real fee — and gasFee 0, so the reference order's claim
    /// pulls `cap + feeCap == 210 + 210*100/10000 == 210 + 2 == 212`. The gas fee is left at zero
    /// here so the pull this suite reasons about is the fee ceiling alone; the one test that cares
    /// about `gasFeeSnap` sets its own.
    function _fees() internal override {
        vm.prank(curation);
        jr.setFees(100, 0);
    }

    function _open(bytes32 c) internal view returns (Order memory o, bytes32 jobId) {
        o = Order({
            c: c,
            modelId: 1,
            slaSecs: 3600,
            rateIn: REF_RATE_IN,
            rateOut: REF_RATE_OUT,
            unitsIn: REF_UNITS_IN,
            unitsOut: REF_UNITS_OUT,
            designated: 0,
            expiresAt: uint64(block.timestamp + 3600),
            taskCid: bytes("bafy-task")
        });
        jobId = keccak256(abi.encodePacked(client, o.c));
    }

    function _claimReverts(bytes32 jobId, bytes memory reason) internal {
        uint64 t = uint64(block.timestamp);
        bytes memory sig = _claimSig(jobId);
        vm.expectRevert(reason);
        jr.claim(jobId, t, sig);
        assertEq(jr.getJob(jobId).state, 0); // still Open
        assertEq(usdc.balanceOf(address(jr)), 0);
    }

    /// @dev The parked authorization executed straight against the token, for the `REF_LOCK` pull
    /// this suite's fees produce. A TYPED call, never a hand-spelled selector string: a misspelled
    /// signature would revert for a reason of its own, and every refusal below would then pass
    /// while proving nothing. Arm `vm.expectRevert` — and any `vm.prank` — on the line before, and
    /// pre-sign `auth`, because `AuthSig` staticcalls the token and would eat an armed cheatcode.
    function _executeAuth(bytes32 jobId, uint64 expiresAt, bytes memory auth) internal {
        IUSDC(USDC).receiveWithAuthorization(client, address(jr), REF_LOCK, 0, uint256(expiresAt) + 1, jobId, auth);
    }

    // ── the happy path ────────────────────────────────────────────────────────────────────────

    function test_claim_funds_escrow_and_emits_signer_id_not_sender() public {
        (bytes32 jobId,) = postJob(0);
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signClaim(vm, opPk, jr, jobId, t);
        uint256 clientBefore = usdc.balanceOf(client);
        vm.expectEmit(true, true, false, true);
        emit JobRegistry.Claimed(jobId, pid, t);
        vm.prank(makeAddr("relayer")); // a gas-only relayer with no registry record of its own
        jr.claim(jobId, t, sig);
        assertEq(usdc.balanceOf(address(jr)), 212); // the escrow really arrived: cap 210 + feeCap 2
        assertEq(usdc.balanceOf(client), clientBefore - 212);
        assertEq(jr.capOf(jobId), 210); // the row stores the CAP; the fee ceiling rides on top
        assertEq(jr.activeJobs(pid), 1);
        JobView memory v = jr.getJob(jobId);
        assertEq(v.state, 1);
        assertEq(v.providerId, pid); // the SIGNER's id — the sender never mattered
        assertEq(v.claimedAt, t);
        assertEq(v.designated, 0);
    }

    function test_claim_sets_providerId_and_never_touches_designated() public {
        (bytes32 jobId,) = postJob(pid); // designated to this very provider
        _claim(jobId);
        JobView memory v = jr.getJob(jobId);
        assertEq(v.providerId, pid);
        assertEq(v.designated, pid); // still the order's designation, not cleared, not overwritten
        assertEq(usdc.balanceOf(address(jr)), 212);
    }

    function test_claim_pulls_cap_plus_gasFeeSnap_not_the_current_gasFee() public {
        vm.prank(curation);
        jr.setFees(100, 7);
        (bytes32 jobId,) = postJob(0); // the authorization covers cap 210 + feeCap 2 + gasFee 7
        vm.prank(curation);
        // a later GAS fee change must not move an already-posted row. feeBps stays at 100: it is
        // read live at claim, so moving it here would change the pull for a reason of its own.
        jr.setFees(100, 999);
        _claim(jobId);
        assertEq(usdc.balanceOf(address(jr)), 219); // 210 + 2 + the SNAPSHOT 7, never the live 999
        assertEq(jr.capOf(jobId), 210); // cap is the compute price; the gas fee rides alongside it
    }

    function test_claim_burns_the_authorization_nonce_and_clears_the_stored_signature() public {
        (bytes32 jobId,) = postJob(pid);
        // `jobs` is a mapping at storage slot 3; `authSig` is the 9th slot of the Job struct
        // (owner|modelId|slaSecs|designated · c · rateIn|rateOut ·
        //  unitsIn|unitsOut|completionTok|providerId|expiresAt|claimedAt ·
        //  state|endedBecause|cap · gasFeeSnap · taskCid · resultCid · authSig)
        bytes32 sigSlot = bytes32(uint256(keccak256(abi.encode(jobId, uint256(3)))) + 8);
        // self-validating probe: a 65-byte `bytes` writes 2*65+1 into its length slot, so a wrong
        // slot derivation fails HERE instead of silently passing the post-claim assertion
        assertEq(uint256(vm.load(address(jr), sigSlot)), 131);
        assertFalse(usdc.authorizationState(client, jobId));
        _claim(jobId);
        assertEq(uint256(vm.load(address(jr), sigSlot)), 0); // spent, deleted, storage refunded
        assertTrue(usdc.authorizationState(client, jobId)); // nonce == jobId, single-use on the token
    }

    function test_only_the_registry_can_execute_the_parked_authorization() public {
        (Order memory o, bytes32 jobId) = _open(keccak256("front-run"));
        bytes memory auth = AuthSig.signAuth(vm, clientPk, address(usdc), address(jr), REF_LOCK, jobId, o.expiresAt);
        jr.post(o, client, OrderSig.signOrder(vm, clientPk, jr, o), auth);
        // the signature is public in post's calldata; a stranger replaying it to the token moves nothing
        vm.expectRevert(bytes("FiatTokenV2: caller must be the payee"));
        _executeAuth(jobId, o.expiresAt, auth);
        assertFalse(usdc.authorizationState(client, jobId));
        _claim(jobId); // and the job is still claimable
        assertEq(usdc.balanceOf(address(jr)), REF_LOCK);
    }

    function test_an_authorization_for_another_job_cannot_fund_this_one() public {
        (Order memory o, bytes32 jobId) = _open(keccak256("foreign-nonce"));
        bytes memory foreign =
            AuthSig.signAuth(vm, clientPk, address(usdc), address(jr), REF_LOCK, keccak256("other-job"), o.expiresAt);
        jr.post(o, client, OrderSig.signOrder(vm, clientPk, jr, o), foreign);
        _claimReverts(jobId, bytes("FiatTokenV2: invalid signature"));
    }

    function test_an_authorization_for_the_wrong_value_cannot_fund() public {
        (Order memory o, bytes32 jobId) = _open(keccak256("wrong-value"));
        bytes memory short_ =
            AuthSig.signAuth(vm, clientPk, address(usdc), address(jr), REF_LOCK - 1, jobId, o.expiresAt);
        jr.post(o, client, OrderSig.signOrder(vm, clientPk, jr, o), short_);
        _claimReverts(jobId, bytes("FiatTokenV2: invalid signature"));
    }

    function test_an_authorization_to_another_payee_cannot_fund() public {
        (Order memory o, bytes32 jobId) = _open(keccak256("wrong-to"));
        bytes memory elsewhere =
            AuthSig.signAuth(vm, clientPk, address(usdc), makeAddr("not-the-registry"), REF_LOCK, jobId, o.expiresAt);
        jr.post(o, client, OrderSig.signOrder(vm, clientPk, jr, o), elsewhere);
        _claimReverts(jobId, bytes("FiatTokenV2: invalid signature"));
    }

    function test_the_authorization_is_dead_after_fail_and_after_reclaim() public {
        (bytes32 a, Order memory oa) = postJob(pid);
        bytes memory aAuth = AuthSig.signAuth(vm, clientPk, address(usdc), address(jr), REF_LOCK, a, oa.expiresAt);
        _claim(a);
        _fail(opPk, a);
        // the registry itself, the one account the token would accept, cannot re-fund a refunded job
        assertEq(usdc.balanceOf(address(jr)), 0); // the lock really went back
        assertTrue(usdc.authorizationState(client, a));
        vm.prank(address(jr));
        vm.expectRevert(bytes("FiatTokenV2: authorization is used or canceled"));
        _executeAuth(a, oa.expiresAt, aAuth);

        // and the same on the other refund path. This order carries the longest expiry `post`
        // allows, so the SLA deadline arrives while the authorization is still inside its own
        // window — at the reference expiry the two fall on the same second and "expired" would
        // answer first, which would say nothing about the nonce.
        (Order memory ob, bytes32 b) = _open(keccak256("dead-after-reclaim"));
        ob.expiresAt = uint64(block.timestamp + 86400); // MAX_EXPIRY, inclusive
        bytes memory bAuth = AuthSig.signAuth(vm, clientPk, address(usdc), address(jr), REF_LOCK, b, ob.expiresAt);
        jr.post(ob, client, OrderSig.signOrder(vm, clientPk, jr, ob), bAuth);
        _claim(b);
        vm.warp(block.timestamp + 3601); // strictly past claimedAt + slaSecs, so reclaim opens
        jr.reclaim(b);
        assertEq(usdc.balanceOf(address(jr)), 0);
        assertTrue(usdc.authorizationState(client, b));
        vm.prank(address(jr));
        vm.expectRevert(bytes("FiatTokenV2: authorization is used or canceled"));
        _executeAuth(b, ob.expiresAt, bAuth);
    }

    function test_claim_logs_Claimed_before_it_calls_out_to_the_token() public {
        // CEI, from the log's side. Every write of the claim frame — and its event — must precede the
        // token call, so a token that reenters with a valid settle signature cannot leave Settled
        // logged BEFORE the Claimed of the very claim that funded it. That ordering is
        // unrecoverable for a log projection, and the escrow's own gates would not catch it: the row
        // is already Claimed by then, so a reentrant claim answers NotOpen and reveals nothing.
        (bytes32 jobId,) = postJob(0);
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signClaim(vm, opPk, jr, jobId, t);
        vm.recordLogs();
        jr.claim(jobId, t, sig);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 claimedAt = type(uint256).max;
        uint256 transferAt = type(uint256).max;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(jr) && logs[i].topics[0] == JobRegistry.Claimed.selector) {
                claimedAt = i;
            }
            // the escrow arriving is the first thing the untrusted token does in this frame
            if (
                logs[i].emitter == address(usdc) && logs[i].topics[0] == TRANSFER_TOPIC
                    && transferAt == type(uint256).max
            ) {
                transferAt = i;
            }
        }
        assertTrue(claimedAt != type(uint256).max, "claim emitted no Claimed");
        assertTrue(transferAt != type(uint256).max, "the escrow pull emitted no Transfer");
        assertLt(claimedAt, transferAt, "Claimed was logged after the escrow pull - CEI is broken");
    }

    // ── the gate ladder, in order ─────────────────────────────────────────────────────────────

    function test_unknown_job_answers_UnknownJob_before_NotOpen() public {
        bytes32 ghost = keccak256("no-such-job");
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signClaim(vm, opPk, jr, ghost, t);
        // an absent row reads state 0 (Open) with expiresAt 0, so without gate 1 this would
        // answer NotOpen — the existence check has to come first
        vm.expectRevert(JobRegistry.UnknownJob.selector);
        jr.claim(ghost, t, sig);
    }

    function test_notOpen_is_checked_before_staleness() public {
        (bytes32 jobId,) = postJob(0);
        _claim(jobId);
        vm.warp(block.timestamp + 700);
        uint64 old = uint64(block.timestamp) - 601;
        bytes memory sig = OpSig.signClaim(vm, opPk, jr, jobId, old);
        vm.expectRevert(JobRegistry.NotOpen.selector); // state answer wins over the clock answer
        jr.claim(jobId, old, sig);
    }

    function test_stale_and_future_issuedAt_revert() public {
        (bytes32 jobId,) = postJob(0);
        vm.warp(block.timestamp + 700); // job still open (expiry +3600); the op is what went stale
        uint64 old = uint64(block.timestamp) - 601;
        bytes memory oldSig = OpSig.signClaim(vm, opPk, jr, jobId, old);
        vm.expectRevert(JobRegistry.StaleOp.selector);
        jr.claim(jobId, old, oldSig);
        uint64 future = uint64(block.timestamp) + 601;
        bytes memory futureSig = OpSig.signClaim(vm, opPk, jr, jobId, future);
        vm.expectRevert(JobRegistry.StaleOp.selector);
        jr.claim(jobId, future, futureSig);
        assertEq(jr.getJob(jobId).state, 0);
    }

    function test_staleness_window_is_inclusive_at_both_ends() public {
        (bytes32 a,) = postJob(0);
        (bytes32 b,) = postJob(pid); // designated to this provider, so only the clock is in play
        vm.warp(block.timestamp + 700);
        uint64 t = uint64(block.timestamp);
        uint64 oldest = t - 600;
        jr.claim(a, oldest, OpSig.signClaim(vm, opPk, jr, a, oldest)); // exactly -600 s: fresh
        uint64 newest = t + 600;
        jr.claim(b, newest, OpSig.signClaim(vm, opPk, jr, b, newest)); // exactly +600 s: fresh
        assertEq(jr.getJob(a).state, 1);
        assertEq(jr.getJob(b).state, 1);
        assertEq(jr.activeJobs(pid), 2);
    }

    function test_stale_op_is_checked_before_provider_resolution() public {
        (bytes32 jobId,) = postJob(0);
        vm.warp(block.timestamp + 700);
        uint64 old = uint64(block.timestamp) - 601;
        bytes memory strangerSig = OpSig.signClaim(vm, 0xBAD, jr, jobId, old);
        vm.expectRevert(JobRegistry.StaleOp.selector); // staleness precedes idOf
        jr.claim(jobId, old, strangerSig);
    }

    function test_claim_refuses_a_zero_recovered_signer() public {
        (bytes32 jobId,) = postJob(0);
        uint64 t = uint64(block.timestamp);
        vm.expectRevert(JobRegistry.UnknownProvider.selector);
        jr.claim(jobId, t, ""); // empty: the 65-byte length check answers address(0)
        vm.expectRevert(JobRegistry.UnknownProvider.selector);
        jr.claim(jobId, t, new bytes(64)); // 64 bytes: same
        vm.expectRevert(JobRegistry.UnknownProvider.selector);
        jr.claim(jobId, t, new bytes(65)); // 65 zero bytes: ecrecover itself answers address(0)
        assertEq(jr.getJob(jobId).state, 0);
    }

    function test_claim_refuses_a_zero_signer_even_when_a_record_maps_the_zero_address() public {
        // R15, defense in depth. Against the shared registry the explicit guard is invisible —
        // idOf[address(0)] is 0, so the provider gate answers UnknownProvider anyway. This stands
        // up a registry where the zero address IS a provider: without the guard a 65-zero-byte
        // signature authenticates as that provider and walks off with the client's escrow.
        ZeroSignerRegistry reg2 = new ZeroSignerRegistry(curation);
        JobRegistry jr2 = new JobRegistry(reg2, IUSDC(USDC), curation, treasury);
        vm.startPrank(curation);
        reg2.setJobRegistry(address(jr2), true);
        reg2.registerModel("model-a:fp8");
        uint32 pid2 = reg2.register(op, 16, true, 1000); // listed, allowAllModels, effectiveCap >= 1
        vm.stopPrank();
        reg2.forceZeroSignerRecord(pid2);

        bytes32 jobId = _postTo(jr2, USDC, keccak256("zero-signer"));
        vm.expectRevert(JobRegistry.UnknownProvider.selector);
        jr2.claim(jobId, uint64(block.timestamp), new bytes(65));
        assertEq(jr2.getJob(jobId).state, 0);
        assertEq(usdc.balanceOf(address(jr2)), 0);
    }

    function test_gate_order_unknown_then_listed_then_model_then_designated_then_capacity() public {
        (bytes32 jobId,) = postJob(0);
        uint64 t = uint64(block.timestamp);
        bytes memory strangerSig = OpSig.signClaim(vm, 0xBAD, jr, jobId, t);
        // an unregistered signer must answer UnknownProvider BEFORE any _rec-gated registry view
        // is touched — isListed/modelAllowed/effectiveCap all revert UnknownProviderId on id 0
        vm.expectRevert(JobRegistry.UnknownProvider.selector);
        jr.claim(jobId, t, strangerSig);

        uint32[] memory none = new uint32[](0);
        // unlisted AND with every model revoked: NotListed has to win
        vm.prank(curation);
        reg.setListed(pid, false);
        vm.prank(curation);
        reg.setAllowedModels(pid, none, false);
        bytes memory unlistedSig = _claimSig(jobId);
        vm.expectRevert(JobRegistry.NotListed.selector);
        jr.claim(jobId, t, unlistedSig);
        vm.prank(curation);
        reg.setListed(pid, true);

        // listed again, models still revoked, and this job is designated elsewhere:
        // ModelNotAllowed has to win over NotDesignated
        (bytes32 designatedJob,) = postJob(99);
        bytes memory revokedSig = _claimSig(designatedJob);
        vm.expectRevert(JobRegistry.ModelNotAllowed.selector);
        jr.claim(designatedJob, t, revokedSig);
        vm.prank(curation);
        reg.setAllowedModels(pid, none, true);

        // now only the designation is wrong — checked against the SIGNER's id, never msg.sender
        bytes memory desSig = _claimSig(designatedJob);
        vm.expectRevert(JobRegistry.NotDesignated.selector);
        jr.claim(designatedJob, t, desSig);

        // eight refusals, nothing landed, no escrow moved
        assertEq(jr.getJob(jobId).state, 0);
        assertEq(jr.getJob(designatedJob).state, 0);
        assertEq(usdc.balanceOf(address(jr)), 0);
        assertEq(jr.activeJobs(pid), 0);
    }

    function test_capacity_gate_uses_effectiveCap() public {
        _requestCapacity(1); // effectiveCap = 1000 * min(1, 16) / 1000 = 1
        (bytes32 a,) = postJob(0);
        _claim(a);
        assertEq(jr.activeJobs(pid), 1);

        // designation is checked BEFORE capacity: this job is over capacity too, yet the answer
        // is NotDesignated
        (bytes32 b,) = postJob(7);
        uint64 t = uint64(block.timestamp);
        bytes memory bSig = _claimSig(b);
        vm.expectRevert(JobRegistry.NotDesignated.selector);
        jr.claim(b, t, bSig);

        // an open, undesignated second job hits AtCapacity
        Order memory o = Order({
            c: keccak256("second"),
            modelId: 1,
            slaSecs: 3600,
            rateIn: 0,
            rateOut: 90_000,
            unitsIn: 0,
            unitsOut: 1000,
            designated: 0,
            expiresAt: uint64(block.timestamp + 3600),
            taskCid: bytes("bafy2")
        });
        bytes32 j2 = keccak256(abi.encodePacked(client, o.c));
        // cap = ceil(90_000 * 1000 / 1e6) = 90, and its fee ceiling floors away: 90*100/10000 = 0.
        // With this suite's gasFee 0 the pull is therefore the bare 90.
        jr.post(
            o,
            client,
            OrderSig.signOrder(vm, clientPk, jr, o),
            AuthSig.signAuth(vm, clientPk, USDC, address(jr), 90, j2, o.expiresAt)
        );
        bytes memory j2Sig = _claimSig(j2);
        vm.expectRevert(JobRegistry.AtCapacity.selector);
        jr.claim(j2, t, j2Sig);

        // the ceiling is read live, not snapshotted: granting more lets the same job through
        _requestCapacity(2);
        _claim(j2);
        assertEq(jr.activeJobs(pid), 2);
        assertEq(jr.capOf(j2), 90);
        assertEq(usdc.balanceOf(address(jr)), 302); // (210 + 2) + 90
    }

    function test_capacity_gate_precedes_the_escrow_pull() public {
        _requestCapacity(1);
        (bytes32 a,) = postJob(0);
        _claim(a);
        bytes32 b = postJobWith(keccak256("cap-vs-pull"), 30_000, 1000, 90_000, 2000, 212); // 210 + feeCap 2
        deal(USDC, client, 0); // drained, so a pull could only fail…
        uint64 t = uint64(block.timestamp);
        bytes memory sig = _claimSig(b);
        vm.expectRevert(JobRegistry.AtCapacity.selector); // ... and the gate answers first
        jr.claim(b, t, sig);
    }

    // ── expiry, replay, and the money math ────────────────────────────────────────────────────

    function test_expired_job_is_unclaimable() public {
        (bytes32 jobId, Order memory o) = postJob(0);
        vm.warp(o.expiresAt + 1);
        uint64 t = uint64(block.timestamp);
        bytes memory sig = _claimSig(jobId);
        vm.expectRevert(JobRegistry.NotOpen.selector);
        jr.claim(jobId, t, sig);
        assertEq(usdc.balanceOf(address(jr)), 0);
    }

    function test_claim_at_exactly_expiresAt_succeeds() public {
        (bytes32 jobId, Order memory o) = postJob(0);
        vm.warp(o.expiresAt); // expired means STRICTLY past expiresAt, matching getJob...
        assertEq(jr.getJob(jobId).state, 0);
        _claim(jobId); // ... and the authorization, valid through expiresAt + 1, still executes here
        assertEq(jr.getJob(jobId).state, 1);
        assertEq(usdc.balanceOf(address(jr)), 212);
    }

    function test_replay_after_landed_claim_hits_NotOpen() public {
        (bytes32 jobId,) = postJob(0);
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signClaim(vm, opPk, jr, jobId, t);
        jr.claim(jobId, t, sig);
        vm.expectRevert(JobRegistry.NotOpen.selector); // the state machine is the replay guard
        jr.claim(jobId, t, sig);
        assertEq(usdc.balanceOf(address(jr)), 212); // escrow funded exactly once
        assertEq(jr.activeJobs(pid), 1);
    }

    function test_insufficient_balance_reverts_whole_claim_leaving_job_open() public {
        (bytes32 jobId,) = postJob(0);
        deal(USDC, client, 0);
        uint64 t = uint64(block.timestamp);
        bytes memory sig = _claimSig(jobId);
        vm.expectRevert(bytes("ERC20: transfer amount exceeds balance"));
        jr.claim(jobId, t, sig);
        // chain-atomic: there is no unclaim path, so every write has to roll back with the pull
        assertEq(jr.getJob(jobId).state, 0);
        assertEq(jr.activeJobs(pid), 0);
        assertEq(usdc.balanceOf(address(jr)), 0);
        assertFalse(usdc.authorizationState(client, jobId)); // the nonce was not burned either
        // and the parked authorization survives, so the same job claims once the client is funded
        deal(USDC, client, 1e24);
        _claim(jobId);
        assertEq(usdc.balanceOf(address(jr)), 212);
    }

    function test_cap_is_ceiling_division_and_never_zero() public {
        // one atomic unit of raw cost still costs 1 after ceiling division
        bytes32 tiny = postJobWith(keccak256("cap-1"), 1, 1, 0, 0, 1);
        _claim(tiny);
        assertEq(jr.capOf(tiny), 1);
        // 1.5 * RATE_SCALE rounds UP, never down
        bytes32 ceil = postJobWith(keccak256("cap-2"), 1, 1_500_000, 0, 0, 2);
        _claim(ceil);
        assertEq(jr.capOf(ceil), 2);
        // a free order still escrows the 1-unit floor
        bytes32 free = postJobWith(keccak256("cap-0"), 0, 0, 0, 0, 1);
        _claim(free);
        assertEq(jr.capOf(free), 1);
        assertEq(usdc.balanceOf(address(jr)), 4); // 1 + 2 + 1: every fee ceiling floors to 0 at these caps
        assertEq(jr.activeJobs(pid), 3);
    }

    function test_cap_that_cannot_fit_uint128_reverts_instead_of_truncating() public {
        // post validates no rates, so an order can ask for a price Job.cap cannot represent.
        // Silently truncating it would escrow a different number than anyone computed.
        bytes32 huge = postJobWith(keccak256("cap-overflow"), type(uint128).max, type(uint32).max, 0, 0, 1);
        uint64 t = uint64(block.timestamp);
        bytes memory sig = _claimSig(huge);
        vm.expectRevert(JobRegistry.CapOverflow.selector);
        jr.claim(huge, t, sig);
        assertEq(jr.getJob(huge).state, 0);
        assertEq(usdc.balanceOf(address(jr)), 0);
    }
}
