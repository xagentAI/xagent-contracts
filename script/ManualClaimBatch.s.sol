// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {XAgentAirdrop} from "../src/XAgentAirdrop.sol";

/// @notice Generates a two-step Safe{Wallet} Transaction Builder JSON at
/// `broadcast/xagent-airdrop-manual-claim.json` for a Manual Settlement above `maxClaimAmount[token]`:
///   1) `IERC20(token).transfer(recipient, amount - fee)`
///   2) `XAgentAirdrop(airdrop).settleManualClaim(claimId, claimant, recipient, token, amount, fee)`
///
/// Required env:
///   XAGENT_AIRDROP_ADDRESS
///   MANUAL_CLAIM_ID
///   MANUAL_CLAIMANT
///   MANUAL_RECIPIENT
///   MANUAL_TOKEN
///   MANUAL_GROSS_AMOUNT
///   MANUAL_FEE (at most `quoteFee(token, grossAmount)`; may be waived)
contract ManualClaimBatch is Script {
    string internal constant OUTPUT_PATH = "broadcast/xagent-airdrop-manual-claim.json";

    function run() external {
        address airdropAddr = vm.envAddress("XAGENT_AIRDROP_ADDRESS");
        uint256 claimId = vm.envUint("MANUAL_CLAIM_ID");
        address claimant = vm.envAddress("MANUAL_CLAIMANT");
        address recipient = vm.envAddress("MANUAL_RECIPIENT");
        address token = vm.envAddress("MANUAL_TOKEN");
        uint256 grossAmount = vm.envUint("MANUAL_GROSS_AMOUNT");
        uint256 fee = vm.envUint("MANUAL_FEE");

        require(
            airdropAddr != address(0) && claimant != address(0) && recipient != address(0) && token != address(0),
            "zero address"
        );
        require(grossAmount > fee, "net amount is zero");

        if (airdropAddr.code.length > 0) {
            XAgentAirdrop airdrop = XAgentAirdrop(airdropAddr);
            require(!airdrop.isClaimed(claimId), "claimId already claimed");
            (uint256 maxAllowedFee,) = airdrop.quoteFee(token, grossAmount);
            require(fee <= maxAllowedFee, "fee exceeds the token's Fee Rate");
        }

        uint256 netAmount = grossAmount - fee;
        bytes memory transferData = abi.encodeCall(IERC20.transfer, (recipient, netAmount));
        bytes memory settleData =
            abi.encodeCall(XAgentAirdrop.settleManualClaim, (claimId, claimant, recipient, token, grossAmount, fee));

        string memory json = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(block.chainid),
            '","meta":{"name":"XAgentAirdrop Manual Settlement #',
            vm.toString(claimId),
            '","txBuilderVersion":"1.17.0"},"transactions":[',
            '{"to":"',
            vm.toString(token),
            '","value":"0","data":"',
            vm.toString(transferData),
            '","operation":0},',
            '{"to":"',
            vm.toString(airdropAddr),
            '","value":"0","data":"',
            vm.toString(settleData),
            '","operation":0}',
            "]}"
        );

        vm.writeFile(OUTPUT_PATH, json);
        console2.log("Manual Claim ID:", claimId);
        console2.log("Gross Amount:", grossAmount);
        console2.log("Claim Fee (retained in Safe):", fee);
        console2.log("Net Amount (transferred to recipient):", netAmount);
        console2.log("Wrote Safe Transaction Builder batch:", OUTPUT_PATH);
    }
}
