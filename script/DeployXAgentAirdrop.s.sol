// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Script, console2} from "forge-std/Script.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {XAgentAirdrop} from "../src/XAgentAirdrop.sol";

interface ISafeModuleView {
    function isModuleEnabled(
        address module
    ) external view returns (bool);
}

/// @notice Deploys `XAgentAirdrop` and writes a Safe{Wallet} Transaction Builder batch JSON to
/// `broadcast/xagent-airdrop-safe-setup.json` so Treasury Safe owners can enable `AllowanceModule` (if needed),
/// register the deployed contract as a delegate, configure the Period Allowance, and configure the token's
/// Per-Claim Cap, Fee Rate, and Float Target. The Claim Float is seeded afterwards by `refill(token)` (anyone)
/// or by the first Claim.
///
/// Required env:
///   PRIVATE_KEY
///   XAGENT_AIRDROP_SAFE
///   XAGENT_AIRDROP_SIGNER
///
/// Optional env:
///   XAGENT_AIRDROP_ALLOWANCE_MODULE   (defaults to canonical v1.0.0: 0x691f59471Bfd2B7d639DCF74671a2d648ED1E331)
///   XAGENT_AIRDROP_GUARDIAN           (defaults to address(0))
///   XAGENT_AIRDROP_TOKEN              (if set, setup batch includes setAllowance + configureToken)
///   XAGENT_AIRDROP_PERIOD_ALLOWANCE   (uint96 token units; required with TOKEN)
///   XAGENT_AIRDROP_RESET_TIME_MIN     (uint16 minutes, defaults to 1440 = 24h)
///   XAGENT_AIRDROP_RESET_BASE_MIN     (uint32 minutes, defaults to 0)
///   XAGENT_AIRDROP_MAX_CLAIM_AMOUNT   (uint256 token units; required with TOKEN)
///   XAGENT_AIRDROP_FEE_BPS            (Fee Rate in bps, defaults to 100 = 1%, at most FEE_BPS_LIMIT = 2000)
///   XAGENT_AIRDROP_FLOAT_TARGET       (token units; required with TOKEN, MAX_CLAIM_AMOUNT <= target <= uint96 max)
contract DeployXAgentAirdrop is Script {
    address internal constant DEFAULT_ALLOWANCE_MODULE = 0x691f59471Bfd2B7d639DCF74671a2d648ED1E331;
    uint256 internal constant DEFAULT_FEE_BPS = 100;
    uint256 internal constant DEFAULT_RESET_TIME_MIN = 1440;
    string internal constant OUTPUT_PATH = "broadcast/xagent-airdrop-safe-setup.json";

    function run() external returns (XAgentAirdrop airdrop) {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address safe = vm.envAddress("XAGENT_AIRDROP_SAFE");
        address allowanceModule = vm.envOr("XAGENT_AIRDROP_ALLOWANCE_MODULE", DEFAULT_ALLOWANCE_MODULE);
        address signer = vm.envAddress("XAGENT_AIRDROP_SIGNER");
        address guardian = vm.envOr("XAGENT_AIRDROP_GUARDIAN", address(0));

        vm.startBroadcast(deployerPk);
        airdrop = new XAgentAirdrop(safe, allowanceModule, signer, guardian);
        vm.stopBroadcast();

        console2.log("XAgentAirdrop:", address(airdrop));
        console2.log("Treasury Safe:", airdrop.SAFE());
        console2.log("AllowanceModule:", address(airdrop.ALLOWANCE_MODULE()));
        console2.log("Signer:", airdrop.signer());
        console2.log("Guardian:", airdrop.guardian());

        _writeSafeSetupBatch(safe, allowanceModule, airdrop);
    }

    function _writeSafeSetupBatch(
        address safe,
        address allowanceModule,
        XAgentAirdrop airdrop
    ) internal {
        bool moduleAlreadyEnabled = false;
        if (safe.code.length > 0) {
            try ISafeModuleView(safe).isModuleEnabled(allowanceModule) returns (bool enabled) {
                moduleAlreadyEnabled = enabled;
            } catch {}
        }

        string memory txs = "";
        if (!moduleAlreadyEnabled) {
            bytes memory enableData = abi.encodeWithSignature("enableModule(address)", allowanceModule);
            txs = _appendTx(txs, safe, enableData);
        }

        bytes memory addDelegateData = abi.encodeWithSignature("addDelegate(address)", address(airdrop));
        txs = _appendTx(txs, allowanceModule, addDelegateData);

        address token = vm.envOr("XAGENT_AIRDROP_TOKEN", address(0));
        if (token != address(0)) {
            uint96 periodAllowance = SafeCast.toUint96(vm.envUint("XAGENT_AIRDROP_PERIOD_ALLOWANCE"));
            uint16 resetTimeMin = SafeCast.toUint16(vm.envOr("XAGENT_AIRDROP_RESET_TIME_MIN", DEFAULT_RESET_TIME_MIN));
            uint32 resetBaseMin = SafeCast.toUint32(vm.envOr("XAGENT_AIRDROP_RESET_BASE_MIN", uint256(0)));
            uint256 maxClaimAmount = vm.envUint("XAGENT_AIRDROP_MAX_CLAIM_AMOUNT");
            uint256 feeBps = vm.envOr("XAGENT_AIRDROP_FEE_BPS", DEFAULT_FEE_BPS);
            uint256 floatTarget = vm.envUint("XAGENT_AIRDROP_FLOAT_TARGET");

            // Fail here rather than inside the Safe batch, where `configureToken` would revert the whole batch.
            require(feeBps <= airdrop.FEE_BPS_LIMIT(), "fee bps above FEE_BPS_LIMIT");
            require(maxClaimAmount > 0, "max claim amount is zero");
            require(floatTarget >= maxClaimAmount && floatTarget <= type(uint96).max, "invalid float target");

            bytes memory setAllowanceData = abi.encodeWithSignature(
                "setAllowance(address,address,uint96,uint16,uint32)",
                address(airdrop),
                token,
                periodAllowance,
                resetTimeMin,
                resetBaseMin
            );
            txs = _appendTx(txs, allowanceModule, setAllowanceData);

            bytes memory configureData =
                abi.encodeCall(XAgentAirdrop.configureToken, (token, maxClaimAmount, feeBps, floatTarget));
            txs = _appendTx(txs, address(airdrop), configureData);

            console2.log("Token:", token);
            console2.log("Period Allowance:", periodAllowance);
            console2.log("Per-Claim Cap:", maxClaimAmount);
            console2.log("Fee Rate (bps):", feeBps);
            console2.log("Float Target:", floatTarget);
        }

        string memory json = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(block.chainid),
            '","meta":{"name":"XAgentAirdrop Safe Setup","txBuilderVersion":"1.17.0"},"transactions":[',
            txs,
            "]}"
        );
        vm.writeFile(OUTPUT_PATH, json);
        console2.log("Wrote Safe Transaction Builder batch:", OUTPUT_PATH);
    }

    function _appendTx(
        string memory existing,
        address to,
        bytes memory data
    ) internal pure returns (string memory) {
        string memory entry =
            string.concat('{"to":"', vm.toString(to), '","value":"0","data":"', vm.toString(data), '","operation":0}');
        if (bytes(existing).length == 0) return entry;
        return string.concat(existing, ",", entry);
    }
}
