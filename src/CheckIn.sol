// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IXPoint} from "./interfaces/IXPoint.sol";

/// @title CheckIn
/// @notice Signature-authorized check-in mint flow for XPoint rewards.
contract CheckIn is Initializable, UUPSUpgradeable, EIP712Upgradeable, Ownable2StepUpgradeable, PausableUpgradeable {
    using BitMaps for BitMaps.BitMap;
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Reentrancy guard (transient storage)
    // ---------------------------------------------------------------------

    bool transient _locked;

    modifier nonReentrant() {
        if (_locked) revert ReentrancyGuardReentrantCall();
        _locked = true;
        _;
        _locked = false;
    }

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    bytes32 private constant CHECKIN_TYPEHASH =
        keccak256("CheckIn(address account,uint256 amount,uint256 claimId,uint256 deadline)");

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    IXPoint public xpoint;
    address public signer;
    BitMaps.BitMap private _claimed;

    uint256[46] private __gap;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error CheckInExpired();
    error AlreadyCheckedIn();
    error InvalidSignature();
    error ReentrancyGuardReentrantCall();
    error ETHTransferFailed();
    error RenounceDisabled();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event CheckedIn(uint256 indexed claimId, address indexed account, uint256 amount);
    event SignerUpdated(address indexed oldSigner, address indexed newSigner);
    event XPointUpdated(address indexed oldToken, address indexed newToken);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event ETHRescued(address indexed to, uint256 amount);

    // ---------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address xpoint_,
        address signer_,
        address owner_
    ) external initializer {
        if (xpoint_ == address(0) || signer_ == address(0) || owner_ == address(0)) revert ZeroAddress();

        __EIP712_init("XAgentCheckIn", "1");
        __Pausable_init();
        __Ownable2Step_init();
        __Ownable_init(owner_);

        xpoint = IXPoint(xpoint_);
        signer = signer_;
    }

    // ---------------------------------------------------------------------
    // External
    // ---------------------------------------------------------------------

    /// @notice Reward caller by claim signature.
    function checkIn(
        uint256 amount,
        uint256 claimId,
        uint256 deadline,
        bytes calldata signature
    ) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert CheckInExpired();
        if (_claimed.get(claimId)) revert AlreadyCheckedIn();

        bytes32 structHash = keccak256(abi.encode(CHECKIN_TYPEHASH, msg.sender, amount, claimId, deadline));
        bytes32 digest = _hashTypedDataV4(structHash);
        if (ECDSA.recoverCalldata(digest, signature) != signer) revert InvalidSignature();

        _claimed.set(claimId);
        xpoint.mint(msg.sender, amount);

        emit CheckedIn(claimId, msg.sender, amount);
    }

    function isClaimed(
        uint256 claimId
    ) external view returns (bool) {
        return _claimed.get(claimId);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setSigner(
        address newSigner
    ) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        emit SignerUpdated(signer, newSigner);
        signer = newSigner;
    }

    function setXPoint(
        address newXPoint
    ) external onlyOwner {
        if (newXPoint == address(0)) revert ZeroAddress();
        emit XPointUpdated(address(xpoint), newXPoint);
        xpoint = IXPoint(newXPoint);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    function rescueETH(
        address payable to
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = address(this).balance;
        (bool success,) = to.call{value: amount}("");
        if (!success) revert ETHTransferFailed();
        emit ETHRescued(to, amount);
    }

    receive() external payable {}

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _authorizeUpgrade(
        address
    ) internal override onlyOwner {}
}
