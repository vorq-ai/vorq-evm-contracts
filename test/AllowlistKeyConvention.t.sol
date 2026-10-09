// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

/**
 * The allowlist key convention, pinned.
 *
 * `allowlistStatus` is a `mapping(bytes32 => uint8)` and the contract never says what a key
 * means. The convention — an image's key IS its measurement, the raw 32-byte sha256 image
 * digest as bytes32, no namespace prefix and no second hash — is shared by the deploy script,
 * the coordinator (`src/escrow/attest.ts`) and the e2e suite. A divergence produces **no error
 * anywhere** — it produces a node reading a permanently absent entry, indistinguishable from
 * "curation never listed this". So the digests are pinned against literals rather than
 * re-derived, because a test that recomputed the recipe would agree with any recipe.
 */
contract AllowlistKeyConventionTest is Test {
    /// @dev the devnet provider CVM image — the key `Deploy.s.sol` seeds
    bytes32 internal constant CVM_IMAGE_KEY = 0x3456994b572f1de0ba1b0ab60ef75683822414c5317b6dbbbea50d203bd5d75d;
    /// @dev the coordinator's own image — the digest `vorq-coordinator-node`'s escrow tests pin
    /// for the same name; if either side changes, this is where it is noticed
    bytes32 internal constant COORDINATOR_IMAGE_KEY =
        0x11ed7897eb27a6c940cf571f40a0c6d7203b3e05dfe448462042a62e2472cb89;

    string internal constant CVM_IMAGE_MEASUREMENT = "3456994b572f1de0ba1b0ab60ef75683822414c5317b6dbbbea50d203bd5d75d";

    function test_theKeyIsTheRawSha256Digest() public pure {
        assertEq(sha256("vorq-mock-cvm-image-v1"), CVM_IMAGE_KEY);
        assertEq(sha256("vorq-mock-coordinator-image-v1"), COORDINATOR_IMAGE_KEY);
    }

    /// @dev the measurement a node announces (64 lowercase hex, no `0x`) round-trips to the key
    function test_theHexMeasurementRoundTripsToTheKey() public pure {
        assertEq(vm.parseBytes32(string.concat("0x", CVM_IMAGE_MEASUREMENT)), CVM_IMAGE_KEY);
        assertEq(vm.replace(vm.toString(CVM_IMAGE_KEY), "0x", ""), CVM_IMAGE_MEASUREMENT);
    }

    /**
     * The entry travels only in the event, but it records the measurement its key is filed
     * under. Its `kind` matters as much as its measurement: clients match only `image` and
     * `cvm-image`, and refuse a measurement if *any* entry carrying it is revoked. An entry
     * written under a kind they do not match is invisible to them.
     */
    function test_theEntryRecordsItsMeasurement() public pure {
        assertEq(
            string.concat('{"kind":"cvm-image","measurement":"', CVM_IMAGE_MEASUREMENT, '"}'),
            '{"kind":"cvm-image","measurement":"3456994b572f1de0ba1b0ab60ef75683822414c5317b6dbbbea50d203bd5d75d"}'
        );
    }
}
