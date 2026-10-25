// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Script, console2} from "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {UsageAttestation} from "../src/UsageAttestation.sol";

/// @notice Deploys UsageAttestation (implementation + ERC1967 UUPS proxy) with owner = broadcasting account.
/// Requires `--ffi` so openzeppelin-foundry-upgrades can run upgrade-safety validation.
contract DeployUsageAttestation is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        vm.startBroadcast(deployerPk);

        address proxy =
            Upgrades.deployUUPSProxy("UsageAttestation.sol", abi.encodeCall(UsageAttestation.initialize, (deployer)));

        vm.stopBroadcast();

        address impl = Upgrades.getImplementationAddress(proxy);
        UsageAttestation registry = UsageAttestation(proxy);
        console2.log("UsageAttestation implementation:", impl);
        console2.log("UsageAttestation proxy:", proxy);
        console2.log("Owner:", registry.owner());
    }
}
