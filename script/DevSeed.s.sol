// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";

/// @notice Development stacks only (the fork bootstrap): curation's first transactions after
/// `Deploy.s.sol`, sent from keys, so a job can be posted, claimed and settled immediately — the
/// registries wired, one model, provider id 1 at full reputation with capacity, and the MOCK CVM
/// image on the measurement allowlist. A real network sends the same calls from its curation Safe
/// and never allowlists the mock image.
contract DevSeed is Script {
    string internal constant MODEL_NAME = "deepseek-ai/deepseek-v4-pro:fp8";
    uint32 internal constant CAPACITY_CEILING = 16;
    uint32 internal constant CAPACITY_REQUESTED = 8;
    uint16 internal constant SEED_REPUTATION = 1000;
    /// @dev `{1 active, 2 revoked}` is the setAllowlistEntry status vocabulary; the chain checks none
    uint8 internal constant ALLOWLIST_ACTIVE = 1;
    bytes internal constant MOCK_CVM_IMAGE = "vorq-mock-cvm-image-v1";
    string internal constant ADDRESSES_PATH = "./out-addresses/addresses.json";

    function run() external {
        string memory book = vm.readFile(ADDRESSES_PATH);
        ProviderRegistry reg = ProviderRegistry(vm.parseJsonAddress(book, ".providerRegistry"));
        address jr = vm.parseJsonAddress(book, ".jobRegistry");
        uint256 curationPk = vm.envUint("CURATION_PK");
        uint256 providerPk = vm.envUint("PROVIDER_PK");
        uint256 relayerPk = vm.envUint("DEPLOYER_PK");
        require(vm.addr(curationPk) == reg.curation(), "DevSeed: CURATION_PK is not this deploy's curation");

        // No `vm.prank` anywhere in this script — a prank does not change the sender of a
        // broadcast transaction. Switching sender means stopping and restarting the broadcast.
        vm.startBroadcast(curationPk);
        reg.setJobRegistry(jr, true);
        require(reg.registerModel(MODEL_NAME) == 1, "DevSeed: model catalog was not fresh");
        // the first operator on a stand is vetted by definition, so it registers at full reputation
        uint32 providerId = reg.register(vm.addr(providerPk), CAPACITY_CEILING, true, SEED_REPUTATION);
        require(providerId == 1, "DevSeed: provider registry was not fresh");
        reg.setAllowlistEntry(_allowlistKey(), ALLOWLIST_ACTIVE, _allowlistEntry());
        vm.stopBroadcast();

        // The one wiring nothing else notices. Only `applyReputationDelta` reads the allowlist, so a
        // miss leaves `post` and `claim` working and escrow funding normally, while `submitAndSettle`
        // and `reclaim` revert and `fail` succeeds only inside its 300 s grace window. The JobRegistry
        // cannot self-check at construction (each needs the other's address), so it is asserted on
        // the run that wires both. A real network runs `make doctor` for the same check.
        require(reg.isJobRegistry(jr), "DevSeed: registry is not wired to this JobRegistry");

        _grantCapacity(reg, providerPk, relayerPk);
        // reputation sits at its 1000 ceiling, so effectiveCap collapses to min(requested, ceiling)
        require(reg.effectiveCap(providerId) == CAPACITY_REQUESTED, "DevSeed: unexpected effective capacity");
    }

    /// @dev `requestCapacity` is signature-authorised: the provider operator signs it and the
    /// relayer sends it, which is how every protocol op travels.
    function _grantCapacity(ProviderRegistry reg, uint256 providerPk, uint256 relayerPk) private {
        // cast is lossless: a uint64 unix timestamp does not overflow until the year 2554
        uint64 issuedAt = uint64(block.timestamp);
        bytes32 structHash = keccak256(abi.encode(reg.REQUEST_CAPACITY_TYPEHASH(), CAPACITY_REQUESTED, issuedAt));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(providerPk, keccak256(abi.encodePacked("\x19\x01", reg.DOMAIN_SEPARATOR(), structHash)));

        vm.startBroadcast(relayerPk);
        reg.requestCapacity(CAPACITY_REQUESTED, issuedAt, abi.encodePacked(r, s, v));
        vm.stopBroadcast();
    }

    /// @dev The key IS the measurement: the raw 32-byte sha256 image digest as bytes32 — no
    /// namespace prefix, no second hash. Every reader (coordinator, SDKs, e2e) passes the digest
    /// straight from the evidence it verified, so there is no derivation left to drift.
    function _allowlistKey() private pure returns (bytes32) {
        return sha256(MOCK_CVM_IMAGE);
    }

    /// @dev opaque to the chain: `setAllowlistEntry` stores only the status and carries these bytes
    /// in its event, so the entry records the measurement the key is filed under
    function _allowlistEntry() private pure returns (bytes memory) {
        return bytes(string.concat('{"kind":"cvm-image","measurement":"', _measurementHex(), '"}'));
    }

    /// @dev the digest as 64 lowercase hex, no `0x` — derived rather than pasted, so an image
    /// rename cannot leave a stale digest seeded on chain
    function _measurementHex() private pure returns (string memory) {
        return vm.replace(vm.toString(_allowlistKey()), "0x", "");
    }
}
