// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {RegSig} from "./utils/RegSig.sol";
import {ZeroSignerRegistry} from "./utils/TestDoubles.sol";

contract ProviderRegistryCurationTest is Test {
    ProviderRegistry reg;
    address curation = makeAddr("curation");
    address op;
    uint256 opPk;
    uint32 pid;

    function setUp() public {
        (op, opPk) = makeAddrAndKey("op");
        reg = new ProviderRegistry(curation);
        vm.prank(curation);
        pid = reg.register(op, 4, true, 1000);
    }

    function test_model_catalog_assigns_ids_and_allowAll_short_circuits() public {
        vm.prank(curation);
        uint32 m1 = reg.registerModel("deepseek-ai/deepseek-v4-pro:fp8");
        assertEq(m1, 1);
        assertTrue(reg.modelExists(1));
        assertFalse(reg.modelExists(2));
        assertTrue(reg.modelAllowed(pid, 1)); // registered with allowAll=true
    }

    function test_explicit_whitelist_replaces_allowAll() public {
        vm.startPrank(curation);
        uint32 m1 = reg.registerModel("a");
        uint32 m2 = reg.registerModel("b");
        uint32[] memory only = new uint32[](1);
        only[0] = m2;
        reg.setAllowedModels(pid, only, false);
        vm.stopPrank();
        assertFalse(reg.modelAllowed(pid, m1));
        assertTrue(reg.modelAllowed(pid, m2));
    }

    function test_setAllowedModels_is_full_replacement_revocation_works() public {
        vm.startPrank(curation);
        uint32 m1 = reg.registerModel("a");
        uint32 m2 = reg.registerModel("b");
        uint32[] memory only = new uint32[](1);
        only[0] = m1;
        reg.setAllowedModels(pid, only, false);
        assertTrue(reg.modelAllowed(pid, m1));
        only[0] = m2;
        reg.setAllowedModels(pid, only, false); // m1 must drop out
        vm.stopPrank();
        assertFalse(reg.modelAllowed(pid, m1));
        assertTrue(reg.modelAllowed(pid, m2));
    }

    function test_setAllowedModels_with_an_empty_list_revokes_everything() public {
        vm.startPrank(curation);
        uint32 m1 = reg.registerModel("a");
        uint32[] memory only = new uint32[](1);
        only[0] = m1;
        reg.setAllowedModels(pid, only, false);
        assertTrue(reg.modelAllowed(pid, m1));
        reg.setAllowedModels(pid, new uint32[](0), false); // the documented way to revoke everything
        assertFalse(reg.modelAllowed(pid, m1));
        reg.setAllowedModels(pid, new uint32[](0), true); // allowAll restored, short-circuits again
        vm.stopPrank();
        assertTrue(reg.modelAllowed(pid, m1));
    }

    function test_allowlist_entry_flips_status_never_deletes() public {
        // an image key is its raw sha256 measurement digest; here any digest-shaped key will do
        bytes32 key = sha256("mock-measurement");
        vm.prank(curation);
        reg.setAllowlistEntry(key, 1, hex"aabb");
        assertEq(reg.allowlistStatus(key), 1);
        vm.prank(curation);
        reg.setAllowlistEntry(key, 2, hex"aabb"); // tombstone
        assertEq(reg.allowlistStatus(key), 2);
    }

    function test_setAllowlistEntry_accepts_any_status_and_emits_the_entry() public {
        bytes32 key = sha256("mock-measurement");
        assertEq(reg.allowlistStatus(key), 0); // 0 = never listed
        vm.prank(curation);
        vm.expectEmit(true, false, false, true);
        emit ProviderRegistry.AllowlistEntrySet(key, 7, hex"c0ffee");
        reg.setAllowlistEntry(key, 7, hex"c0ffee");
        // curation is trusted: the {1 active, 2 revoked} vocabulary is a convention, not an on-chain check
        assertEq(reg.allowlistStatus(key), 7);
    }

    function test_registerModel_and_allowedModels_events_carry_the_wire_payload() public {
        vm.prank(curation);
        vm.expectEmit(true, false, false, true);
        emit ProviderRegistry.ModelRegistered(1, "a");
        reg.registerModel("a");

        vm.prank(curation);
        reg.registerModel("b");

        uint32[] memory list = new uint32[](2);
        list[0] = 2;
        list[1] = 1;
        vm.prank(curation);
        vm.expectEmit(true, false, false, true);
        // the complete new list, so a projection replaces instead of merging
        emit ProviderRegistry.AllowedModelsChanged(pid, false, list);
        reg.setAllowedModels(pid, list, false);

        vm.prank(curation);
        vm.expectEmit(true, false, false, true);
        emit ProviderRegistry.ModelEnabledChanged(2, false);
        reg.setModelEnabled(2, false);
    }

    function test_new_curation_functions_are_curation_only() public {
        uint32[] memory none = new uint32[](0);
        vm.expectRevert(ProviderRegistry.NotCuration.selector);
        reg.registerModel("a");
        vm.expectRevert(ProviderRegistry.NotCuration.selector);
        reg.setModelEnabled(1, false);
        vm.expectRevert(ProviderRegistry.NotCuration.selector);
        reg.setAllowedModels(pid, none, false);
        vm.expectRevert(ProviderRegistry.NotCuration.selector);
        reg.setAllowlistEntry(keccak256("k"), 1, hex"01");
        assertEq(reg.nextModelId(), 1); // nothing landed
        assertTrue(reg.modelAllowed(pid, 1)); // allowAll untouched
    }

    function test_modelAllowed_and_boxKeyOf_refuse_an_unknown_provider_id() public {
        vm.expectRevert(ProviderRegistry.UnknownProviderId.selector);
        reg.modelAllowed(404, 1);
        vm.expectRevert(ProviderRegistry.UnknownProviderId.selector);
        reg.boxKeyOf(404);
        uint32[] memory none = new uint32[](0);
        vm.prank(curation);
        vm.expectRevert(ProviderRegistry.UnknownProviderId.selector);
        reg.setAllowedModels(404, none, true);
    }

    function test_set_identity_typehash_is_byte_exact() public view {
        assertEq(reg.SET_IDENTITY_TYPEHASH(), keccak256("SetIdentity(bytes32 boxKey,bytes evidence,uint64 issuedAt)"));
    }

    function test_setIdentity_signed_op_stores_key_and_emits_evidence() public {
        bytes memory evidence = bytes('{"type":"mock-cvm-v1"}');
        uint64 t1 = uint64(block.timestamp);
        vm.expectEmit(true, false, false, true);
        emit ProviderRegistry.IdentityUpdated(pid, bytes32(uint256(0xBEEF)), evidence);
        // any sender lands it — the event names the SIGNER's id, gas-only relayer confers nothing
        reg.setIdentity(
            bytes32(uint256(0xBEEF)),
            evidence,
            t1,
            RegSig.signIdentity(vm, opPk, reg, bytes32(uint256(0xBEEF)), evidence, t1)
        );
        assertEq(reg.boxKeyOf(pid), bytes32(uint256(0xBEEF)));
        assertEq(reg.lastIdentityAt(pid), t1);
        vm.expectRevert(ProviderRegistry.NotAProvider.selector);
        reg.setIdentity(bytes32(0), "", t1 + 1, hex"00");
    }

    function test_setIdentity_monotonic_floor_kills_superseded_key_replay() public {
        bytes memory evA = bytes("A");
        bytes memory evB = bytes("B");
        uint64 t1 = uint64(block.timestamp);
        bytes memory sigA = RegSig.signIdentity(vm, opPk, reg, bytes32(uint256(1)), evA, t1);
        reg.setIdentity(bytes32(uint256(1)), evA, t1, sigA);
        reg.setIdentity(
            bytes32(uint256(2)), evB, t1 + 1, RegSig.signIdentity(vm, opPk, reg, bytes32(uint256(2)), evB, t1 + 1)
        );
        // THE attack this floor exists for: replaying identity A after B must not republish key 1
        vm.expectRevert(ProviderRegistry.StaleOp.selector);
        reg.setIdentity(bytes32(uint256(1)), evA, t1, sigA);
        assertEq(reg.boxKeyOf(pid), bytes32(uint256(2)));
        // floors are per-op: a capacity op does not advance the identity floor
        assertEq(reg.lastCapacityAt(pid), 0);
        // rotated-out key's op refused: idOf answers nothing for it
        vm.prank(curation);
        reg.setOperator(pid, makeAddr("newOp"));
        bytes memory sigRotatedOut = RegSig.signIdentity(vm, opPk, reg, bytes32(uint256(3)), evA, t1 + 2);
        vm.expectRevert(ProviderRegistry.NotAProvider.selector);
        reg.setIdentity(bytes32(uint256(3)), evA, t1 + 2, sigRotatedOut);
    }

    function test_setIdentity_skew_ceiling_is_inclusive() public {
        uint64 tFar = uint64(block.timestamp) + 3601;
        bytes memory farSig = RegSig.signIdentity(vm, opPk, reg, bytes32(uint256(1)), "", tFar);
        vm.expectRevert(ProviderRegistry.StaleOp.selector);
        reg.setIdentity(bytes32(uint256(1)), "", tFar, farSig);
        assertEq(reg.lastIdentityAt(pid), 0);
        uint64 tCeiling = uint64(block.timestamp) + 3600;
        reg.setIdentity(
            bytes32(uint256(2)), "", tCeiling, RegSig.signIdentity(vm, opPk, reg, bytes32(uint256(2)), "", tCeiling)
        );
        assertEq(reg.lastIdentityAt(pid), tCeiling);
        assertEq(reg.boxKeyOf(pid), bytes32(uint256(2)));
    }

    function test_identity_and_capacity_floors_are_independent() public {
        uint64 t = uint64(block.timestamp);
        // a capacity op far ahead of the identity op must not raise the identity floor
        reg.requestCapacity(3, t + 100, RegSig.signCapacity(vm, opPk, reg, 3, t + 100));
        assertEq(reg.lastCapacityAt(pid), t + 100);
        assertEq(reg.lastIdentityAt(pid), 0);
        reg.setIdentity(bytes32(uint256(7)), "", t, RegSig.signIdentity(vm, opPk, reg, bytes32(uint256(7)), "", t));
        assertEq(reg.lastIdentityAt(pid), t);
        assertEq(reg.lastCapacityAt(pid), t + 100); // and the identity op did not touch the capacity floor
        // each floor blocks only its own op
        bytes memory staleCap = RegSig.signCapacity(vm, opPk, reg, 9, t);
        vm.expectRevert(ProviderRegistry.StaleOp.selector);
        reg.requestCapacity(9, t, staleCap);
        bytes memory staleId = RegSig.signIdentity(vm, opPk, reg, bytes32(uint256(8)), "", t);
        vm.expectRevert(ProviderRegistry.StaleOp.selector);
        reg.setIdentity(bytes32(uint256(8)), "", t, staleId);
        assertEq(reg.boxKeyOf(pid), bytes32(uint256(7)));
    }

    function test_setIdentity_signature_binds_boxKey_and_evidence() public {
        bytes memory ev = bytes("evidence-A");
        uint64 t = uint64(block.timestamp);
        bytes memory sig = RegSig.signIdentity(vm, opPk, reg, bytes32(uint256(0xA1)), ev, t);
        // evidence is hashed into the struct hash per EIP-712, so swapping it recovers a stranger
        vm.expectRevert(ProviderRegistry.NotAProvider.selector);
        reg.setIdentity(bytes32(uint256(0xA1)), bytes("evidence-B"), t, sig);
        vm.expectRevert(ProviderRegistry.NotAProvider.selector);
        reg.setIdentity(bytes32(uint256(0xA2)), ev, t, sig);
        (, uint256 strangerPk) = makeAddrAndKey("stranger");
        bytes memory strangerSig = RegSig.signIdentity(vm, strangerPk, reg, bytes32(uint256(0xA1)), ev, t);
        vm.expectRevert(ProviderRegistry.NotAProvider.selector);
        reg.setIdentity(bytes32(uint256(0xA1)), ev, t, strangerSig);
        assertEq(reg.lastIdentityAt(pid), 0); // none of the three landed
        reg.setIdentity(bytes32(uint256(0xA1)), ev, t, sig); // the untampered op still lands
        assertEq(reg.boxKeyOf(pid), bytes32(uint256(0xA1)));
    }

    function test_setIdentity_refuses_a_zero_recovered_signer() public {
        uint64 t = uint64(block.timestamp);
        vm.expectRevert(ProviderRegistry.NotAProvider.selector);
        reg.setIdentity(bytes32(uint256(1)), "", t, ""); // empty: length check
        vm.expectRevert(ProviderRegistry.NotAProvider.selector);
        reg.setIdentity(bytes32(uint256(1)), "", t, new bytes(64)); // 64 bytes: length check
        vm.expectRevert(ProviderRegistry.NotAProvider.selector);
        reg.setIdentity(bytes32(uint256(1)), "", t, new bytes(65)); // 65 zero bytes: ecrecover answers address(0)
        assertEq(reg.lastIdentityAt(pid), 0);
        assertEq(reg.boxKeyOf(pid), bytes32(0));
    }

    function test_setIdentity_zero_signer_refused_even_when_a_record_maps_the_zero_address() public {
        ZeroSignerRegistry h = new ZeroSignerRegistry(curation);
        vm.prank(curation);
        uint32 id = h.register(op, 4, true, 1000);
        h.forceZeroSignerRecord(id); // the state R15's guard defends against
        assertEq(h.idOf(address(0)), id);
        // a 65-byte all-zero signature passes the length check, so ecrecover itself yields
        // address(0): the explicit guard, not idOf, is what must refuse it
        vm.expectRevert(ProviderRegistry.NotAProvider.selector);
        h.setIdentity(bytes32(uint256(9)), "", uint64(block.timestamp), new bytes(65));
        assertEq(h.lastIdentityAt(id), 0);
        assertEq(h.boxKeyOf(id), bytes32(0));
    }

    function test_model_kill_switch_flips_and_rejects_unknown_id() public {
        vm.prank(curation);
        uint32 m1 = reg.registerModel("a");
        assertTrue(reg.modelEnabled(m1)); // registerModel seeds enabled
        vm.prank(curation);
        reg.setModelEnabled(m1, false);
        assertFalse(reg.modelEnabled(m1)); // post-gating covered in Task 4 tests
        vm.prank(curation);
        vm.expectRevert(ProviderRegistry.UnknownModel.selector);
        reg.setModelEnabled(99, true);
    }
}
