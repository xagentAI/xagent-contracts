// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";

contract EIP1153SmokeTarget {
    bool private transient _flag;

    function probe() external returns (bool) {
        _flag = true;
        bool ok = _flag;
        _flag = false;
        return ok;
    }
}

contract SmokeEIP1153 is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPk);

        EIP1153SmokeTarget target = new EIP1153SmokeTarget();
        bool ok = target.probe();

        vm.stopBroadcast();

        console2.log("EIP-1153 smoke target:", address(target));
        console2.log("Probe result:", ok);
    }
}
