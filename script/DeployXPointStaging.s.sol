// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {XPoint} from "../src/XPoint.sol";
import {XPointStaging} from "../src/XPointStaging.sol";

contract DeployXPointStaging is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        string memory tokenName = vm.envString("XPOINT_NAME");
        string memory tokenSymbol = vm.envString("XPOINT_SYMBOL");
        uint256 maxSupply = vm.envUint("XPOINT_MAX_SUPPLY");

        address operator = vm.envOr("XPOINT_OPERATOR", vm.addr(deployerPk));
        address pauser = vm.envOr("XPOINT_PAUSER", vm.addr(deployerPk));
        bool whitelistMode = vm.envOr("XPOINT_WHITELIST_MODE", false);

        vm.startBroadcast(deployerPk);

        XPointStaging impl = new XPointStaging();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                XPoint.initialize,
                (tokenName, tokenSymbol, vm.addr(deployerPk), operator, pauser, maxSupply, whitelistMode)
            )
        );

        vm.stopBroadcast();

        XPointStaging token = XPointStaging(address(proxy));
        console2.log("XPointStaging implementation:", address(impl));
        console2.log("XPointStaging proxy:", address(proxy));
        console2.log("Owner:", token.owner());
        console2.log("Operator:", operator);
        console2.log("Pauser:", pauser);
        console2.log("Whitelist mode:", whitelistMode);
        console2.log("Max supply:", maxSupply);
    }
}
