// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {IUSDC, JobRegistry} from "../src/JobRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";

/// @notice Deploys a JobRegistry beside an existing ProviderRegistry — the upgrade path for a
/// JobRegistry change, since the registries are immutable. The ProviderRegistry, the AskRegistry,
/// the catalog and the providers stay. Curation then authorises the new address with
/// `setJobRegistry(new, true)`, and de-authorises the old one once the coordinator reads the new.
/// Writes `out-addresses/job-registry.json`: the address, its domain separator and deploy block.
contract DeployJobRegistry is Script {
    string internal constant OUT_PATH = "./out-addresses/job-registry.json";

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        ProviderRegistry reg = ProviderRegistry(vm.envAddress("PROVIDER_REGISTRY"));
        address usdc = vm.envAddress("USDC");
        address curation = vm.envAddress("CURATION");
        address treasury = vm.envAddress("TREASURY");
        require(usdc.code.length > 0, "DeployJobRegistry: no code at USDC");
        require(address(reg).code.length > 0, "DeployJobRegistry: no code at PROVIDER_REGISTRY");
        // the new registry answers to the same curation as the registry it plugs into
        require(reg.curation() == curation, "DeployJobRegistry: CURATION is not the ProviderRegistry's curation");

        vm.startBroadcast(pk);
        JobRegistry jr = new JobRegistry(reg, IUSDC(usdc), curation, treasury);
        vm.stopBroadcast();

        string memory obj = "jobRegistry";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeUint(obj, "deployBlock", block.number);
        vm.serializeBytes32(obj, "jobRegistryDomainSeparator", jr.DOMAIN_SEPARATOR());
        string memory json = vm.serializeAddress(obj, "jobRegistry", address(jr));
        vm.writeJson(json, OUT_PATH);
    }
}
