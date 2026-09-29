// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title UsageAttestation
/// @notice Permissionless registry of AI usage attestations. The account is always `msg.sender`, and every
/// attestation is marked as an estimate (`BASIS_ESTIMATED`). Figures are not checked against any meter.
/// History lives only in `UsageAttested` events; storage keeps per-account totals and the replay set.
contract UsageAttestation is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice Basis flag emitted with every attestation: the token counts are estimates.
    uint8 public constant BASIS_ESTIMATED = 1;

    // ---------------------------------------------------------------------
    // Storage (ERC-7201)
    // ---------------------------------------------------------------------

    struct AccountUsage {
        uint256 totalInputTokens;
        uint256 totalOutputTokens;
        uint64 attestationCount;
        uint64 lastAttestedAt;
    }

    /// @custom:storage-location erc7201:xagent.storage.UsageAttestation
    struct UsageAttestationStorage {
        mapping(address account => AccountUsage) usage;
        mapping(address account => mapping(bytes32 usageRef => bool)) usedUsageRefs;
    }

    // keccak256(abi.encode(uint256(keccak256("xagent.storage.UsageAttestation")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant USAGE_ATTESTATION_STORAGE_LOCATION =
        0xe7f7ea612a38e43d2e9490926649065efb3b5f8909427011f51b84286b834700;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroUsageRef();
    error UsageRefAlreadyUsed(address account, bytes32 usageRef);
    error ZeroTokenCounts();
    error ZeroAgentId();
    error ZeroModelId();
    error ZeroAddress();
    error RenounceDisabled();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event UsageAttested(
        address indexed account,
        bytes32 indexed usageRef,
        bytes32 agentId,
        bytes32 modelId,
        uint256 inputTokens,
        uint256 outputTokens,
        uint8 basis
    );
    event ETHRescued(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    // ---------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner
    ) external initializer {
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __Pausable_init();
    }

    // ---------------------------------------------------------------------
    // External
    // ---------------------------------------------------------------------

    /// @notice Record an estimated AI usage attestation for `msg.sender`.
    /// @dev First write per `(msg.sender, usageRef)` wins. One of the token counts may be zero, not both.
    function attestUsage(
        bytes32 agentId,
        bytes32 modelId,
        uint256 inputTokens,
        uint256 outputTokens,
        bytes32 usageRef
    ) external whenNotPaused {
        if (usageRef == bytes32(0)) revert ZeroUsageRef();
        if (agentId == bytes32(0)) revert ZeroAgentId();
        if (modelId == bytes32(0)) revert ZeroModelId();
        if (inputTokens == 0 && outputTokens == 0) revert ZeroTokenCounts();

        UsageAttestationStorage storage $ = _getStorage();
        if ($.usedUsageRefs[msg.sender][usageRef]) revert UsageRefAlreadyUsed(msg.sender, usageRef);
        $.usedUsageRefs[msg.sender][usageRef] = true;

        AccountUsage storage usage = $.usage[msg.sender];
        usage.totalInputTokens += inputTokens;
        usage.totalOutputTokens += outputTokens;
        usage.attestationCount += 1;
        // uint64 seconds does not overflow for ~5.8e11 years.
        // forge-lint: disable-next-line(unsafe-typecast)
        usage.lastAttestedAt = uint64(block.timestamp);

        emit UsageAttested(msg.sender, usageRef, agentId, modelId, inputTokens, outputTokens, BASIS_ESTIMATED);
    }

    function attestationCount(
        address account
    ) external view returns (uint256) {
        return _getStorage().usage[account].attestationCount;
    }

    function totalInputTokens(
        address account
    ) external view returns (uint256) {
        return _getStorage().usage[account].totalInputTokens;
    }

    function totalOutputTokens(
        address account
    ) external view returns (uint256) {
        return _getStorage().usage[account].totalOutputTokens;
    }

    function lastAttestedAt(
        address account
    ) external view returns (uint256) {
        return _getStorage().usage[account].lastAttestedAt;
    }

    function isUsageRefUsed(
        address account,
        bytes32 usageRef
    ) external view returns (bool) {
        return _getStorage().usedUsageRefs[account][usageRef];
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function rescueETH(
        address payable to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        Address.sendValue(to, amount);
        emit ETHRescued(to, amount);
    }

    function rescueERC20(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _authorizeUpgrade(
        address
    ) internal override onlyOwner {}

    function _getStorage() private pure returns (UsageAttestationStorage storage $) {
        assembly {
            $.slot := USAGE_ATTESTATION_STORAGE_LOCATION
        }
    }
}
