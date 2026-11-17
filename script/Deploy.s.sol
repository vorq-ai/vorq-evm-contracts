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

/// @notice Deploys the three registries against an existing USDC and writes every address a
/// consumer needs to `out-addresses/addresses.json`. Nothing else: curation and treasury are
/// addresses here, never keys, so curation can be a Safe — it is `immutable` in both registries.
/// Wiring the registries (`setJobRegistry`), the catalog and the providers are curation's own
/// transactions afterwards; on the fork, `DevSeed.s.sol` sends them.
contract Deploy is Script {
    string internal constant OUT_PATH = "./out-addresses/addresses.json";

    /// @dev one memory struct instead of a dozen stack locals (R19)
    struct Ctx {
        uint256 deployerPk;
        address usdc;
        address deployer;
        address treasury;
        address curation;
        ProviderRegistry reg;
        JobRegistry jr;
        AskRegistry ar;
    }

    function run() external {
        Ctx memory c = _config();
        require(c.usdc.code.length > 0, "Deploy: no code at USDC - wrong network or wrong address");
        _deploy(c);
        _writeAddresses(c);
    }

    function _config() private view returns (Ctx memory c) {
        // every input is required: a deploy that forgot one must fail, never run under a default
        c.deployerPk = vm.envUint("DEPLOYER_PK");
        c.usdc = vm.envAddress("USDC");
        c.curation = vm.envAddress("CURATION");
        c.treasury = vm.envAddress("TREASURY");
        c.deployer = vm.addr(c.deployerPk);
    }

    function _deploy(Ctx memory c) private {
        vm.startBroadcast(c.deployerPk);
        c.reg = new ProviderRegistry(c.curation);
        c.jr = new JobRegistry(c.reg, IUSDC(c.usdc), c.curation, c.treasury);
        c.ar = new AskRegistry(c.reg);
        vm.stopBroadcast();
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
        string memory json = vm.serializeAddress(obj, "deployer", c.deployer);
        vm.writeJson(json, OUT_PATH);
    }
}
