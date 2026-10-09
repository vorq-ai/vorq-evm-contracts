// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {AskRegistry} from "../src/AskRegistry.sol";
import {IUSDC, JobRegistry} from "../src/JobRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";

interface IToken {
    function name() external view returns (string memory);
    function version() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @notice Deploys the three registries against an existing USDC, seeds curation and capacity so a
/// job can be posted, claimed and settled immediately, and writes every address a consumer needs to
/// `out-addresses/addresses.json`. Funding the client is not this script's job: on a fork the
/// bootstrap mints, on a real network a faucet does.
contract Deploy is Script {
    string internal constant MODEL_NAME = "deepseek-ai/deepseek-v4-pro:fp8";
    uint32 internal constant CAPACITY_CEILING = 16;
    uint32 internal constant CAPACITY_REQUESTED = 8;
    uint16 internal constant SEED_REPUTATION = 1000;
    /// @dev `{1 active, 2 revoked}` is the setAllowlistEntry status vocabulary; the chain checks none
    uint8 internal constant ALLOWLIST_ACTIVE = 1;
    bytes internal constant MOCK_CVM_IMAGE = "vorq-mock-cvm-image-v1";
    string internal constant OUT_PATH = "./out-addresses/addresses.json";

    /// @dev one memory struct instead of twenty stack locals (R19)
    struct Ctx {
        uint256 deployerPk;
        uint256 curationPk;
        uint256 providerPk;
        uint256 clientPk;
        address usdc;
        address deployer;
        address treasury;
        address curation;
        address providerOperator;
        address client;
        ProviderRegistry reg;
        JobRegistry jr;
        AskRegistry ar;
        uint32 providerId;
    }

    function run() external {
        Ctx memory c = _config();
        require(c.usdc.code.length > 0, "Deploy: no code at USDC - wrong network or wrong address");

        _deploy(c);
        _seedCuration(c);
        // The one wiring nothing else notices. Only `applyReputationDelta` reads the allowlist, so a
        // miss leaves `post` and `claim` working and escrow funding normally, while `submitAndSettle`
        // and `reclaim` revert and `fail` succeeds only inside its 300 s grace window — every claimed
        // job's escrow unresolvable until it is repaired. It IS repairable now (curation authorizes
        // the right address), which is what makes a redeploy a cutover rather than a stranding, but a
        // deploy that ships mis-wired still strands every job posted before anyone notices. The
        // JobRegistry cannot self-check at construction (each needs the other's address), so the
        // assertion belongs here, on the deploy that owns both.
        require(c.reg.isJobRegistry(address(c.jr)), "Deploy: registry is not wired to this JobRegistry");
        _grantCapacity(c);

        // reputation sits at its 1000 ceiling, so effectiveCap collapses to min(requested, ceiling)
        require(c.reg.effectiveCap(c.providerId) == CAPACITY_REQUESTED, "Deploy: unexpected effective capacity");

        _writeAddresses(c);
    }

    function _config() private view returns (Ctx memory c) {
        // every key is required: a deploy that forgot one must fail, never run under a default
        c.deployerPk = vm.envUint("DEPLOYER_PK");
        c.curationPk = vm.envUint("CURATION_PK");
        c.providerPk = vm.envUint("PROVIDER_PK");
        c.clientPk = vm.envUint("CLIENT_PK");
        c.usdc = vm.envAddress("USDC");
        c.deployer = vm.addr(c.deployerPk);
        c.treasury = vm.addr(vm.envUint("TREASURY_PK"));
        c.curation = vm.addr(c.curationPk);
        c.providerOperator = vm.addr(c.providerPk);
        c.client = vm.addr(c.clientPk);
    }

    function _deploy(Ctx memory c) private {
        vm.startBroadcast(c.deployerPk);
        c.reg = new ProviderRegistry(c.curation);
        c.jr = new JobRegistry(c.reg, IUSDC(c.usdc), c.curation, c.treasury);
        c.ar = new AskRegistry(c.reg);
        vm.stopBroadcast();
    }

    /// @dev No `vm.prank` anywhere in this script — a prank does not change the sender of a
    /// broadcast transaction. Switching sender means stopping and restarting the broadcast.
    function _seedCuration(Ctx memory c) private {
        vm.startBroadcast(c.curationPk);
        c.reg.setJobRegistry(address(c.jr), true);
        require(c.reg.registerModel(MODEL_NAME) == 1, "Deploy: model catalog was not fresh");
        // the first operator on a stand is vetted by definition, so it registers at full reputation
        c.providerId = c.reg.register(c.providerOperator, CAPACITY_CEILING, true, SEED_REPUTATION);
        require(c.providerId == 1, "Deploy: provider registry was not fresh");
        c.reg.setAllowlistEntry(_allowlistKey(), ALLOWLIST_ACTIVE, _allowlistEntry());
        vm.stopBroadcast();
    }

    /// @dev `requestCapacity` is signature-authorised: the provider operator signs it and the
    /// relayer sends it, which is how every protocol op travels.
    function _grantCapacity(Ctx memory c) private {
        // cast is lossless: a uint64 unix timestamp does not overflow until the year 2554
        uint64 issuedAt = uint64(block.timestamp);
        bytes32 structHash = keccak256(abi.encode(c.reg.REQUEST_CAPACITY_TYPEHASH(), CAPACITY_REQUESTED, issuedAt));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(c.providerPk, keccak256(abi.encodePacked("\x19\x01", c.reg.DOMAIN_SEPARATOR(), structHash)));

        vm.startBroadcast(c.deployerPk);
        c.reg.requestCapacity(CAPACITY_REQUESTED, issuedAt, abi.encodePacked(r, s, v));
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

    function _writeAddresses(Ctx memory c) private {
        string memory domain = "tokenDomain";
        vm.serializeString(domain, "name", IToken(c.usdc).name());
        string memory domainJson = vm.serializeString(domain, "version", IToken(c.usdc).version());

        string memory obj = "addresses";
        vm.serializeUint(obj, "chainId", block.chainid);
        // a lower bound for the indexer's cold-start replay: the block this script simulated at
        vm.serializeUint(obj, "deployBlock", block.number);
        vm.serializeAddress(obj, "usdc", c.usdc);
        vm.serializeUint(obj, "paymentTokenDecimals", IToken(c.usdc).decimals());
        vm.serializeString(obj, "tokenDomain", domainJson);
        vm.serializeAddress(obj, "providerRegistry", address(c.reg));
        vm.serializeAddress(obj, "jobRegistry", address(c.jr));
        vm.serializeAddress(obj, "askRegistry", address(c.ar));
        vm.serializeAddress(obj, "curation", c.curation);
        vm.serializeAddress(obj, "treasury", c.treasury);
        vm.serializeAddress(obj, "providerOperator", c.providerOperator);
        vm.serializeAddress(obj, "client", c.client);
        string memory json = vm.serializeAddress(obj, "deployer", c.deployer);
        vm.writeJson(json, OUT_PATH);
    }
}
