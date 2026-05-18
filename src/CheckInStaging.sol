// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {CheckIn} from "./CheckIn.sol";

/// @title CheckInStaging
/// @notice Mainnet staging variant of CheckIn with isolated EIP-712 domain.
contract CheckInStaging is CheckIn {
    function _domainName() internal pure override returns (string memory) {
        return "XAgentCheckInStaging";
    }
}
