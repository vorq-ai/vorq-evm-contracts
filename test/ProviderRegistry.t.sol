// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {RegSig} from "./utils/RegSig.sol";
import {ZeroSignerRegistry} from "./utils/TestDoubles.sol";

contract ProviderRegistryTest is Test {
    ProviderRegistry reg;
    address curation = makeAddr("curation");
    address opA;
    uint256 opAPk;
    address opB;
    uint256 opBPk;

    function setUp() public {
        (opA, opAPk) = makeAddrAndKey("opA");
        (opB, opBPk) = makeAddrAndKey("opB");
        reg = new ProviderRegistry(curation);
        vm.prank(curation);
        reg.setJobRegistry(address(this), true); // test acts as JobRegistry
    }

    function test_register_assigns_sequential_ids_and_seeds_reputation() public {
        vm.prank(curation);
        uint32 a = reg.register(opA, 16, true, 200);
        vm.prank(curation);
        uint32 b = reg.register(opB, 4, true, 1000);
        assertEq(a, 1);
        assertEq(b, 2);
        assertEq(reg.idOf(opA), 1);
        // each record carries the seed ITS registration named, not a value shared by the contract
        assertEq(reg.reputationOf(1), 200);
        assertEq(reg.reputationOf(2), 1000);
    }

    function test_registerSeedsTheReputationItIsGiven() public {
        vm.expectEmit(true, false, false, true);
        emit ProviderRegistry.ReputationChanged(1, 1000);
        vm.prank(curation);
        uint32 id = reg.register(opA, 16, true, 1000);
        assertEq(reg.reputationOf(id), 1000);
        assertEq(reg.effectiveCap(id), 1); // capacityRequested is still 0
    }

    function test_registerClampsTheSeedLikeSetReputation() public {
        vm.prank(curation);
        uint32 lo = reg.register(opA, 16, true, 0);
        vm.prank(curation);
        uint32 hi = reg.register(opB, 16, true, 65535);
        assertEq(reg.reputationOf(lo), 100);
        assertEq(reg.reputationOf(hi), 1000);
    }

    function test_register_refuses_duplicate_operator_and_non_curation() public {
        vm.prank(curation);
        reg.register(opA, 1, true, 1000);
        vm.prank(curation);
        vm.expectRevert(ProviderRegistry.DuplicateOperator.selector);
        reg.register(opA, 1, true, 1000);
        vm.expectRevert(ProviderRegistry.NotCuration.selector);
        reg.register(opB, 1, true, 1000);
    }

    function test_register_refuses_the_zero_operator() public {
        vm.prank(curation);
        vm.expectRevert(ProviderRegistry.ZeroOperator.selector);
        reg.register(address(0), 1, true, 1000);
        assertEq(reg.nextProviderId(), 1); // no id was burned
    }

    function test_register_emits_registered_then_listed_then_capacity_then_reputation() public {
        // the four-event order is a wire contract for every later log consumer: the indexer's
        // ProviderRegistered insert lands first and the three that follow overwrite its columns
        vm.expectEmit(address(reg));
        emit ProviderRegistry.ProviderRegistered(1, opA);
        vm.expectEmit(address(reg));
        emit ProviderRegistry.ListedChanged(1, false);
        vm.expectEmit(address(reg));
        emit ProviderRegistry.CapacityChanged(1, 7, 0);
        vm.expectEmit(address(reg));
        emit ProviderRegistry.ReputationChanged(1, 700);
        vm.prank(curation);
        reg.register(opA, 7, false, 700);
    }

    function test_setOperator_remaps_idOf_and_keeps_the_id() public {
        vm.prank(curation);
        uint32 id = reg.register(opA, 1, true, 1000);
        vm.prank(curation);
        reg.setOperator(id, opB);
        assertEq(reg.idOf(opA), 0);
        assertEq(reg.idOf(opB), id);
        assertEq(reg.operatorOf(id), opB);
    }

    function test_setOperator_refuses_the_zero_operator() public {
        vm.prank(curation);
        uint32 id = reg.register(opA, 1, true, 1000);
        vm.prank(curation);
        vm.expectRevert(ProviderRegistry.ZeroOperator.selector);
        reg.setOperator(id, address(0));
        // the record survives intact — a zeroed operator would be unrecoverable
        assertEq(reg.operatorOf(id), opA);
        assertEq(reg.idOf(opA), id);
        assertEq(reg.idOf(address(0)), 0);
    }

    function test_setOperator_refuses_an_operator_already_bound_to_another_provider() public {
        vm.prank(curation);
        uint32 a = reg.register(opA, 16, true, 1000);
        vm.prank(curation);
        uint32 b = reg.register(opB, 4, true, 1000);
        // the rotation branch of the DuplicateOperator guard: register's branch cannot reach it,
        // because register never has an old mapping to delete
        vm.prank(curation);
        vm.expectRevert(ProviderRegistry.DuplicateOperator.selector);
        reg.setOperator(a, opB);
        // the guard fires BEFORE `delete idOf[r.operator]`, so neither record moved — without that
        // ordering provider a would end up unreachable while opB still resolved to b
        assertEq(reg.operatorOf(a), opA);
        assertEq(reg.idOf(opA), a);
        assertEq(reg.operatorOf(b), opB);
        assertEq(reg.idOf(opB), b);
        // and a no-op rotation onto a provider's OWN current operator is refused by the same guard
        vm.prank(curation);
        vm.expectRevert(ProviderRegistry.DuplicateOperator.selector);
        reg.setOperator(a, opA);
        assertEq(reg.idOf(opA), a);
    }

    function test_provider_setters_are_curation_only() public {
        vm.prank(curation);
        uint32 id = reg.register(opA, 16, true, 200);
        uint64 t = uint64(block.timestamp);
        reg.requestCapacity(16, t, RegSig.signCapacity(vm, opAPk, reg, 16, t));
        assertEq(reg.effectiveCap(id), 3); // 200 * min(16, 16) / 1000

        // this contract is the wired jobRegistry, NOT curation: the modifier reads msg.sender, and
        // reputation standing confers nothing on the curation surface
        vm.expectRevert(ProviderRegistry.NotCuration.selector);
        reg.setOperator(id, opB);
        vm.expectRevert(ProviderRegistry.NotCuration.selector);
        reg.setListed(id, false);
        vm.expectRevert(ProviderRegistry.NotCuration.selector);
        reg.setCapacityCeiling(id, 1);
        vm.expectRevert(ProviderRegistry.NotCuration.selector);
        reg.setReputation(id, 1000);

        // nothing landed: each assertion is the one a successful call would have broken
        assertEq(reg.operatorOf(id), opA);
        assertEq(reg.idOf(opB), 0);
        assertTrue(reg.isListed(id));
        assertEq(reg.reputationOf(id), 200);
        assertEq(reg.effectiveCap(id), 3); // a ceiling of 1 would have collapsed this to the floor
    }

    function test_operator_listed_and_capacity_changes_emit_their_wire_events() public {
        // Plan 2's indexer consumes these three, and each is the only trace its setter leaves
        vm.prank(curation);
        uint32 id = reg.register(opA, 16, true, 1000);

        vm.expectEmit(address(reg));
        emit ProviderRegistry.OperatorChanged(id, opB);
        vm.prank(curation);
        reg.setOperator(id, opB);

        vm.expectEmit(address(reg));
        emit ProviderRegistry.ListedChanged(id, false);
        vm.prank(curation);
        reg.setListed(id, false);

        // the operator rotated, so the capacity op is authored by the NEW key; the event reports the
        // live ceiling alongside the requested figure, which is why both are in it
        uint64 t = uint64(block.timestamp);
        bytes memory sig = RegSig.signCapacity(vm, opBPk, reg, 9, t);
        vm.expectEmit(address(reg));
        emit ProviderRegistry.CapacityChanged(id, 16, 9);
        reg.requestCapacity(9, t, sig);
    }

    function test_requestCapacity_refuses_a_zero_recovered_signer() public {
        vm.prank(curation);
        uint32 id = reg.register(opA, 16, true, 1000);
        uint64 t1 = uint64(block.timestamp);
        // no signature at all, and a wrong-length one: _recover answers address(0)
        bytes memory empty = "";
        vm.expectRevert(ProviderRegistry.NotAProvider.selector);
        reg.requestCapacity(10, t1, empty);
        bytes memory short = new bytes(64);
        vm.expectRevert(ProviderRegistry.NotAProvider.selector);
        reg.requestCapacity(10, t1, short);
        // right length, all zeros: ecrecover itself yields address(0), so only the
        // explicit zero-signer guard stands between this call and authorization
        bytes memory zeros = new bytes(65);
        vm.expectRevert(ProviderRegistry.NotAProvider.selector);
        reg.requestCapacity(10, t1, zeros);
        // nothing landed
        assertEq(reg.lastCapacityAt(id), 0);
        assertEq(reg.effectiveCap(id), 1);
    }

    // the zero-signer guard is defense in depth: register/setOperator make idOf[address(0)]
    // unreachable through the public API, so the guard is only observable on a record forced
    // into the state a future change might allow.
    function test_zero_signer_is_refused_even_when_a_record_maps_the_zero_address() public {
        ZeroSignerRegistry h = new ZeroSignerRegistry(curation);
        vm.prank(curation);
        uint32 id = h.register(opA, 16, true, 1000);
        h.forceZeroSignerRecord(id);
        assertEq(h.idOf(address(0)), id);
        bytes memory zeros = new bytes(65); // ecrecover answers address(0)
        vm.expectRevert(ProviderRegistry.NotAProvider.selector);
        h.requestCapacity(10, uint64(block.timestamp), zeros);
        assertEq(h.lastCapacityAt(id), 0);
    }

    function test_effectiveCap_formula() public {
        vm.prank(curation);
        uint32 id = reg.register(opA, 16, true, 200);
        uint64 t1 = uint64(block.timestamp);
        reg.requestCapacity(10, t1, RegSig.signCapacity(vm, opAPk, reg, 10, t1)); // any sender — the signature is the authority
        // max(1, 200*min(10,16)/1000) = 2
        assertEq(reg.effectiveCap(id), 2);
        vm.prank(curation);
        reg.setReputation(id, 1000);
        assertEq(reg.effectiveCap(id), 10);
        reg.requestCapacity(0, t1 + 1, RegSig.signCapacity(vm, opAPk, reg, 0, t1 + 1)); // strictly monotonic issuedAt
        assertEq(reg.effectiveCap(id), 1); // floor is always 1
    }

    function test_effectiveCap_does_not_truncate_at_uint32_max() public {
        uint32 max = type(uint32).max;
        vm.prank(curation);
        uint32 id = reg.register(opA, max, true, 1000);
        uint64 t1 = uint64(block.timestamp);
        reg.requestCapacity(max, t1, RegSig.signCapacity(vm, opAPk, reg, max, t1));
        assertEq(reg.effectiveCap(id), max); // 1000 * (2**32-1) / 1000 fits uint32 exactly
    }

    function test_requestCapacity_signature_rules() public {
        vm.prank(curation);
        reg.register(opA, 16, true, 200);
        uint64 t1 = uint64(block.timestamp);
        reg.requestCapacity(10, t1, RegSig.signCapacity(vm, opAPk, reg, 10, t1));
        assertEq(reg.lastCapacityAt(1), t1);
        // replay and equal issuedAt refused — latest-wins state needs strict ordering
        bytes memory replay = RegSig.signCapacity(vm, opAPk, reg, 10, t1);
        vm.expectRevert(ProviderRegistry.StaleOp.selector);
        reg.requestCapacity(10, t1, replay);
        // far-future issuedAt refused (skew ceiling: now + 3600)
        uint64 tFar = uint64(block.timestamp) + 3601;
        bytes memory farSig = RegSig.signCapacity(vm, opAPk, reg, 1, tFar);
        vm.expectRevert(ProviderRegistry.StaleOp.selector);
        reg.requestCapacity(1, tFar, farSig);
        // unregistered signer refused
        bytes memory strangerSig = RegSig.signCapacity(vm, opBPk, reg, 1, t1 + 2);
        vm.expectRevert(ProviderRegistry.NotAProvider.selector);
        reg.requestCapacity(1, t1 + 2, strangerSig);
        // tampered payload fails recovery to the operator
        bytes memory tamperedSig = RegSig.signCapacity(vm, opAPk, reg, 1, t1 + 3);
        vm.expectRevert(ProviderRegistry.NotAProvider.selector);
        reg.requestCapacity(99, t1 + 3, tamperedSig);
        // the refused ops left no trace: floor and requested capacity are untouched
        assertEq(reg.lastCapacityAt(1), t1);
        assertEq(reg.effectiveCap(1), 2);
    }

    function test_requestCapacity_at_the_skew_ceiling_is_accepted() public {
        vm.prank(curation);
        uint32 id = reg.register(opA, 16, true, 1000);
        uint64 tEdge = uint64(block.timestamp) + 3600; // ceiling is inclusive
        reg.requestCapacity(5, tEdge, RegSig.signCapacity(vm, opAPk, reg, 5, tEdge));
        assertEq(reg.lastCapacityAt(id), tEdge);
    }

    function test_reputation_delta_clamps_and_is_jobRegistry_only() public {
        vm.prank(curation);
        uint32 id = reg.register(opA, 1, true, 200);
        reg.applyReputationDelta(id, -40); // 200 -> 160
        assertEq(reg.reputationOf(id), 160);
        reg.applyReputationDelta(id, -1000);
        assertEq(reg.reputationOf(id), 100); // clamp floor
        vm.prank(curation);
        reg.setReputation(id, 998);
        reg.applyReputationDelta(id, 5);
        assertEq(reg.reputationOf(id), 1000); // clamp ceiling
        vm.prank(opA);
        vm.expectRevert(ProviderRegistry.NotJobRegistry.selector);
        reg.applyReputationDelta(id, 5);
    }

    function test_setReputation_clamps_curation_input() public {
        vm.prank(curation);
        uint32 id = reg.register(opA, 1, true, 1000);
        vm.prank(curation);
        reg.setReputation(id, 0);
        assertEq(reg.reputationOf(id), 100);
        vm.prank(curation);
        reg.setReputation(id, 65535);
        assertEq(reg.reputationOf(id), 1000);
    }

    function test_setListed_and_setCapacityCeiling_keep_requested_capacity() public {
        vm.prank(curation);
        uint32 id = reg.register(opA, 16, true, 200);
        uint64 t1 = uint64(block.timestamp);
        reg.requestCapacity(10, t1, RegSig.signCapacity(vm, opAPk, reg, 10, t1));
        vm.prank(curation);
        reg.setListed(id, false);
        assertFalse(reg.isListed(id));
        vm.expectEmit(address(reg));
        emit ProviderRegistry.CapacityChanged(id, 4, 10); // requested survives a ceiling change
        vm.prank(curation);
        reg.setCapacityCeiling(id, 4);
        assertEq(reg.effectiveCap(id), 1); // 200*min(10,4)/1000 = 0 -> floor 1
    }

    function test_setJobRegistry_is_curation_only() public {
        ProviderRegistry fresh = new ProviderRegistry(curation);
        vm.expectRevert(ProviderRegistry.NotCuration.selector);
        fresh.setJobRegistry(address(1), true);
        vm.prank(curation);
        fresh.setJobRegistry(address(1), true);
        assertTrue(fresh.isJobRegistry(address(1)));
    }

    /// The cutover case the allowlist exists for. A JobRegistry is immutable and holds no durable
    /// state, so it is serviced by redeploying rather than upgrading — and for the ~48h a v1 takes
    /// to drain, BOTH registries must be able to apply reputation for their own in-flight jobs. A
    /// single repointable address could not express that overlap.
    function test_two_authorized_job_registries_both_apply_reputation() public {
        ProviderRegistry fresh = new ProviderRegistry(curation);
        address v1 = makeAddr("jobRegistryV1");
        address v2 = makeAddr("jobRegistryV2");
        vm.startPrank(curation);
        fresh.setJobRegistry(v1, true);
        fresh.setJobRegistry(v2, true);
        uint32 id = fresh.register(makeAddr("operator"), 4, true, 200);
        vm.stopPrank();

        vm.prank(v1);
        fresh.applyReputationDelta(id, 5);
        vm.prank(v2);
        fresh.applyReputationDelta(id, 5);

        assertEq(fresh.reputationOf(id), 210); // seed 200, both deltas landed
    }

    function test_a_revoked_job_registry_can_no_longer_apply_reputation() public {
        ProviderRegistry fresh = new ProviderRegistry(curation);
        address old = makeAddr("drainedRegistry");
        vm.startPrank(curation);
        fresh.setJobRegistry(old, true);
        uint32 id = fresh.register(makeAddr("operator"), 4, true, 200);
        vm.stopPrank();

        vm.prank(old);
        fresh.applyReputationDelta(id, 5);
        assertEq(fresh.reputationOf(id), 205);

        vm.prank(curation);
        fresh.setJobRegistry(old, false);

        vm.prank(old);
        vm.expectRevert(ProviderRegistry.NotJobRegistry.selector);
        fresh.applyReputationDelta(id, 5);
        assertEq(fresh.reputationOf(id), 205, "the revoked registry changed nothing");
    }

    function test_unknown_provider_id_is_refused_by_views_and_setters() public {
        vm.expectRevert(ProviderRegistry.UnknownProviderId.selector);
        reg.operatorOf(7);
        vm.expectRevert(ProviderRegistry.UnknownProviderId.selector);
        reg.effectiveCap(7);
        vm.prank(curation);
        vm.expectRevert(ProviderRegistry.UnknownProviderId.selector);
        reg.setListed(7, true);
        vm.expectRevert(ProviderRegistry.UnknownProviderId.selector);
        reg.applyReputationDelta(7, 5);
    }

    function test_domain_separator_binds_name_version_chain_and_this_contract() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(reg.EIP712_NAME())),
                keccak256("2"),
                block.chainid,
                address(reg)
            )
        );
        assertEq(reg.DOMAIN_SEPARATOR(), expected);
        assertEq(reg.REQUEST_CAPACITY_TYPEHASH(), keccak256("RequestCapacity(uint32 n,uint64 issuedAt)"));
    }
}
