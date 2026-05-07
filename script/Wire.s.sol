// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {XPoint} from "../src/XPoint.sol";

contract Wire is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address xpoint = vm.envAddress("XPOINT_ADDRESS");
        address checkIn = vm.envAddress("CHECKIN_ADDRESS");
        bool whitelistCheckIn = vm.envOr("WHITELIST_CHECKIN", true);

        vm.startBroadcast(deployerPk);

        XPoint token = XPoint(xpoint);
        token.grantRole(token.MINTER_ROLE(), checkIn);
        console2.log("Granted MINTER_ROLE to CheckIn:", checkIn);

        if (whitelistCheckIn) {
            token.addToWhitelist(checkIn);
            console2.log("Added CheckIn to whitelist:", checkIn);
        }

        vm.stopBroadcast();
    }
}
