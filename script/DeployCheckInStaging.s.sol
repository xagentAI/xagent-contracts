// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CheckIn} from "../src/CheckIn.sol";
import {CheckInStaging} from "../src/CheckInStaging.sol";

contract DeployCheckInStaging is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address xpoint = vm.envAddress("XPOINT_ADDRESS");
        address signer = vm.envAddress("CHECKIN_SIGNER");

        vm.startBroadcast(deployerPk);

        CheckInStaging impl = new CheckInStaging();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(CheckIn.initialize, (xpoint, signer, vm.addr(deployerPk))));

        vm.stopBroadcast();

        CheckInStaging checkIn = CheckInStaging(payable(address(proxy)));
        console2.log("CheckInStaging implementation:", address(impl));
        console2.log("CheckInStaging proxy:", address(proxy));
        console2.log("Owner:", checkIn.owner());
        console2.log("Signer:", checkIn.signer());
        console2.log("XPoint:", address(checkIn.xpoint()));
    }
}
