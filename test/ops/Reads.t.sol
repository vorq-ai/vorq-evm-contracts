// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Reads} from "../../script/ops/Reads.s.sol";
import {AskRegistry} from "../../src/AskRegistry.sol";
import {JobRegistry} from "../../src/JobRegistry.sol";
import {ProviderRegistry} from "../../src/ProviderRegistry.sol";
import {OpsFixture} from "./OpsFixture.sol";

/// @dev binds to the live fixture instead of a committed book. The override is the whole point:
/// `vm.setEnv` would be visible to every test running in parallel in this contract and cannot be
/// unset, so a harness reaches `OpsBase` through a `virtual` hook, never through the environment.
contract ReadsHarness is Reads {
    function bind(ProviderRegistry r, JobRegistry j, AskRegistry a, address c) external {
        reg = r;
        jr = j;
        ar = a;
        curationAddr = c;
        dev = true;
    }

    /// @dev the allow-all reading is what `provider()` renders and what Task 5's diff will be
    /// built on, so it is asserted directly rather than eyeballed in a log
    function allowAllModels(uint32 id) external view returns (bool allowAll, bool decisive) {
        return _allowAllModels(id);
    }

    function _load() internal override {}
}

contract ReadsTest is OpsFixture {
    ReadsHarness internal reads;

    function setUp() public {
        _deployFixture();
        reads = new ReadsHarness();
        reads.bind(reg, jr, ar, curation);
        // `doctor` requires an enabled model, and an empty catalog is itself one of the faults it
        // reports, so the healthy fixture has to have one
        vm.prank(curation);
        reg.registerModel("m1");
    }

    function test_configReadsLiveValues() public {
        vm.prank(curation);
        jr.setFees(250, 7);
        reads.config(); // asserts by not reverting; the values are eyeballed under -vv
        assertEq(jr.feeBps(), 250);
    }

    /// @dev the footgun: `operatorOf` REVERTS on an unknown id. A read must report that as data.
    function test_unknownProviderIsAReadableRefusalNotARawRevert() public {
        vm.expectRevert(bytes("ops: unknown provider id 42"));
        reads.provider(42);
    }

    function test_providerReadsAKnownRecord() public {
        vm.prank(curation);
        uint32 id = reg.register(operator, 16, true, 1000);
        reads.provider(id);
        // capacityRequested is still 0, so granted is 0 and the cap floors at 1 — never 0
        assertEq(reg.effectiveCap(id), 1);
        assertEq(reg.operatorOf(id), operator);
    }

    /**
     * @dev `register` seeds `allowAllModels = true`, so a probe of `1..nextModelId()` renders a
     * default record as a closed set — and on an empty catalog as `(none)`, the exact inversion of
     * the truth. The sentinel read is what makes the difference visible.
     */
    function test_aDefaultRecordReadsAsAllowAllNotAClosedSet() public {
        vm.prank(curation);
        uint32 id = reg.register(operator, 16, true, 1000);

        // the chain's own answer: ids far outside the catalog are allowed, so this is allow-all
        assertTrue(reg.modelAllowed(id, type(uint32).max));
        assertTrue(reg.modelAllowed(id, reg.nextModelId()));

        (bool allowAll, bool decisive) = reads.allowAllModels(id);
        assertTrue(decisive);
        assertTrue(allowAll);
        reads.provider(id);
    }

    /// @dev the other direction: once curation writes an explicit set, one false sentinel is proof
    /// the flag is off, and only then is the probed list the complete truth
    function test_anExplicitSetReadsAsNotAllowAllAndIsThenComplete() public {
        vm.startPrank(curation);
        uint32 id = reg.register(operator, 16, true, 1000);
        reg.registerModel("m2");
        uint32[] memory only1 = new uint32[](1);
        only1[0] = 1;
        reg.setAllowedModels(id, only1, false);
        vm.stopPrank();

        assertFalse(reg.modelAllowed(id, type(uint32).max));
        assertTrue(reg.modelAllowed(id, 1));
        assertFalse(reg.modelAllowed(id, 2));

        (bool allowAll, bool decisive) = reads.allowAllModels(id);
        assertTrue(decisive);
        assertFalse(allowAll);
        reads.provider(id);
    }

    /// @dev an absent job must read as `found: false`, never as a revert
    function test_absentJobIsFoundFalse() public {
        reads.job(keccak256("nope"));
        assertEq(jr.getJob(keccak256("nope")).found, false);
    }

    function test_doctorPassesOnACorrectlyWiredFixture() public {
        reads.doctor();
    }

    function test_doctorFailsWhenTheJobRegistryIsNotAuthorised() public {
        vm.prank(curation);
        reg.setJobRegistry(address(jr), false);
        vm.expectRevert(
            bytes(
                "doctor: this JobRegistry is NOT authorised on the ProviderRegistry. submitAndSettle and "
                "reclaim revert for every claimed job until curation calls setJobRegistry(addr, true)."
            )
        );
        reads.doctor();
    }

    /// @dev a deployment that is up, wired, and cannot accept a single order
    function test_doctorFailsWhenNoSlaIsAllowed() public {
        vm.startPrank(curation);
        jr.setSlaAllowed(3600, false);
        jr.setSlaAllowed(86400, false);
        vm.stopPrank();
        vm.expectRevert(
            bytes(
                "doctor: no SLA among the probed common values is allowed, so post() reverts "
                "SlaNotAllowed for every order using one (allowedSla is a bare mapping, so a value "
                "outside the probe could still be open). Curation must call " "jobRegistry.setSlaAllowed(3600, true)."
            )
        );
        reads.doctor();
    }

    function test_doctorFailsWhenNoModelIsEnabled() public {
        vm.prank(curation);
        reg.setModelEnabled(1, false);
        vm.expectRevert(
            bytes(
                "doctor: no model in the catalog is enabled (or the catalog is empty), so post() "
                "reverts ModelDisabled for every order. Curation must call "
                "providerRegistry.registerModel(<name>) and/or setModelEnabled(<modelId>, true)."
            )
        );
        reads.doctor();
    }

    /// @dev the empty catalog is the same fault by another route, and it is the state a fresh
    /// deployment is in before anyone seeds it
    function test_doctorFailsOnAnEmptyCatalog() public {
        ReadsHarness bare = new ReadsHarness();
        ProviderRegistry reg2 = new ProviderRegistry(curation);
        vm.prank(curation);
        reg2.setJobRegistry(address(jr), true);
        bare.bind(reg2, jr, ar, curation);
        assertEq(reg2.nextModelId(), 1);
        // pinned to the same string as its three siblings: a bare expectRevert would keep passing
        // if a different guard started catching this first
        vm.expectRevert(
            bytes(
                "doctor: no model in the catalog is enabled (or the catalog is empty), so post() "
                "reverts ModelDisabled for every order. Curation must call "
                "providerRegistry.registerModel(<name>) and/or setModelEnabled(<modelId>, true)."
            )
        );
        bare.doctor();
    }
}
