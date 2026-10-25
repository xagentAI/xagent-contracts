// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";

import {IAllowanceModule} from "./interfaces/IAllowanceModule.sol";

/// @title XAgentAirdrop
/// @notice Non-upgradeable EIP-712 airdrop claim contract that pays Claims from its own per-token Claim Float.
/// The float is topped up from `SAFE` (the Treasury Safe) through Safe's canonical `AllowanceModule` (`v1.0.0`),
/// where this contract is a delegate, so the Period Allowance bounds how much can ever flow into the float.
/// `SAFE` holds sole administrative authority over this contract.
/// @dev Each self-service `claim` verifies a caller-bound signature, enforces the token's Per-Claim Cap and
/// requires the signed `fee` to equal the token's Fee Rate, marks `claimId` in a bitmap, and transfers the
/// Net Amount (`amount - fee`) from the float to `recipient`. The Claim Fee is never pulled out of `SAFE`.
/// When the float cannot cover a Claim, the Claim first refills it towards the token's Float Target. Claims
/// above the Per-Claim Cap are fulfilled via a direct `SAFE` multi-signature batch that pairs
/// `IERC20.transfer` with `settleManualClaim`. Only standard ERC-20 tokens are supported; fee-on-transfer and
/// rebasing tokens are not.
contract XAgentAirdrop is EIP712, Pausable, ReentrancyGuardTransient {
    using BitMaps for BitMaps.BitMap;
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Constants & immutables
    // ---------------------------------------------------------------------

    bytes32 public constant CLAIM_TYPEHASH = keccak256(
        "Claim(address claimant,address token,uint256 amount,uint256 fee,uint256 claimId,uint256 epoch,uint256 deadline)"
    );

    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard ceiling on any token's Fee Rate (`2_000` = 20%). `SAFE` cannot configure a rate above it.
    uint256 public constant FEE_BPS_LIMIT = 2000;

    /// @notice `refill` only runs once the float has dropped to this share of the Float Target (50%).
    uint256 public constant REFILL_THRESHOLD_BPS = 5000;

    /// @notice Treasury Safe that holds token reserves and administers this contract.
    address public immutable SAFE;

    /// @notice Safe canonical `AllowanceModule` (`v1.0.0`) on this chain.
    IAllowanceModule public immutable ALLOWANCE_MODULE;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice Off-chain authority whose EIP-712 signature authorizes a Claim.
    address public signer;

    /// @notice Emergency role allowed only to `pause`, `advanceEpoch`, and `returnToSafe` while paused.
    /// May be `address(0)` if unused.
    address public guardian;

    /// @notice Monotonically increasing generation bound into every signature; bumping invalidates older signatures.
    uint256 public epoch;

    /// @notice Per-token maximum Gross Amount for a single self-service `claim`. Zero disables the token.
    mapping(address token => uint256 cap) public maxClaimAmount;

    /// @notice Per-token Fee Rate in basis points of the Gross Amount (at most `FEE_BPS_LIMIT`).
    mapping(address token => uint256 bps) public feeBps;

    /// @notice Per-token Float Target: the balance a refill tops this contract's Claim Float back up to.
    mapping(address token => uint256 target) public floatTarget;

    BitMaps.BitMap private _claimed;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error OnlySafe();
    error OnlySafeOrGuardian();
    error ClaimExpired(uint256 deadline, uint256 timestamp);
    error TokenNotEnabled(address token);
    error ExceedsMaxClaimAmount(uint256 amount, uint256 maxClaimAmount);
    error FeeBpsTooHigh(uint256 feeBps, uint256 limit);
    error InvalidFloatTarget(uint256 floatTarget, uint256 maxClaimAmount);
    error FeeMismatch(uint256 fee, uint256 expectedFee);
    error FeeExceedsMax(uint256 fee, uint256 maxAllowedFee);
    error ZeroNetAmount();
    error AlreadyClaimed(uint256 claimId);
    error InvalidSignature();
    error InsufficientFloat(uint256 needed, uint256 available);
    error FloatAboveRefillThreshold(uint256 balance, uint256 threshold);
    error NothingToRefill();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Claimed(
        uint256 indexed claimId,
        address indexed claimant,
        address indexed recipient,
        address token,
        uint256 grossAmount,
        uint256 fee,
        uint256 netAmount
    );
    event ManualClaimSettled(
        uint256 indexed claimId,
        address indexed claimant,
        address indexed recipient,
        address token,
        uint256 grossAmount,
        uint256 fee,
        uint256 netAmount
    );
    event SignerUpdated(address indexed oldSigner, address indexed newSigner);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event TokenConfigured(address indexed token, uint256 maxClaimAmount, uint256 feeBps, uint256 floatTarget);
    event EpochAdvanced(uint256 indexed oldEpoch, uint256 indexed newEpoch, address indexed triggeredBy);
    event FloatRefilled(address indexed token, uint256 amount, uint256 newBalance, address indexed triggeredBy);
    event FloatReturned(address indexed token, uint256 amount, address indexed triggeredBy);
    event ETHRescued(uint256 amount);

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlySafe() {
        if (msg.sender != SAFE) revert OnlySafe();
        _;
    }

    modifier onlySafeOrGuardian() {
        if (msg.sender != SAFE && msg.sender != guardian) revert OnlySafeOrGuardian();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(
        address safe_,
        address allowanceModule_,
        address signer_,
        // forge-lint: disable-next-line(missing-zero-check)
        address guardian_
    ) EIP712("XAgentAirdrop", "1") {
        if (safe_ == address(0) || allowanceModule_ == address(0) || signer_ == address(0)) {
            revert ZeroAddress();
        }

        SAFE = safe_;
        ALLOWANCE_MODULE = IAllowanceModule(allowanceModule_);

        signer = signer_;
        guardian = guardian_;

        emit SignerUpdated(address(0), signer_);
        emit GuardianUpdated(address(0), guardian_);
    }

    // ---------------------------------------------------------------------
    // Claiming
    // ---------------------------------------------------------------------

    /// @notice Collect an authorized Claim as `msg.sender` and send the Net Amount to `recipient`.
    /// @dev `msg.sender` is the Claimant bound by the signature; `recipient` may be `msg.sender` or any
    /// non-zero address chosen by the Claimant at call time. `fee` must equal `quoteFee(token, amount)`
    /// at execution time, so a Fee Rate change invalidates signatures issued under the previous rate.
    function claim(
        address token,
        uint256 amount,
        uint256 fee,
        uint256 claimId,
        uint256 deadline,
        address payable recipient,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert ClaimExpired(deadline, block.timestamp);
        if (amount == 0) revert ZeroAmount();

        uint256 cap = maxClaimAmount[token];
        if (cap == 0) revert TokenNotEnabled(token);
        if (amount > cap) revert ExceedsMaxClaimAmount(amount, cap);

        uint256 expectedFee = _feeFor(token, amount);
        if (fee != expectedFee) revert FeeMismatch(fee, expectedFee);
        uint256 netAmount = amount - fee;
        if (netAmount == 0) revert ZeroNetAmount();

        if (_claimed.get(claimId)) revert AlreadyClaimed(claimId);

        bytes32 structHash =
            keccak256(abi.encode(CLAIM_TYPEHASH, msg.sender, token, amount, fee, claimId, epoch, deadline));
        if (ECDSA.recoverCalldata(_hashTypedDataV4(structHash), signature) != signer) {
            revert InvalidSignature();
        }

        _claimed.set(claimId);

        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 pullAmount = balance < netAmount ? _refillAmount(token, balance) : 0;
        if (balance + pullAmount < netAmount) revert InsufficientFloat(netAmount, balance + pullAmount);

        // forge-lint: disable-next-line(reentrancy-events)
        emit Claimed(claimId, msg.sender, recipient, token, amount, fee, netAmount);

        if (pullAmount != 0) _pull(token, pullAmount, balance);
        IERC20(token).safeTransfer(recipient, netAmount);
    }

    /// @notice Mark a Claim ID as collected during a direct Treasury Safe multi-signature settlement.
    /// @dev Intended to be batched via `MultiSendCallOnly` alongside `IERC20(token).transfer(recipient, netAmount)`
    /// for Claims above `maxClaimAmount[token]`; the Safe pays from its own balance, not from the Claim Float.
    /// `fee` may be waived but never exceed `quoteFee(token, amount)`. Deliberately callable while paused so the
    /// Treasury Safe can still settle manual Claims during an emergency pause. Reverts with `AlreadyClaimed` if
    /// `claimId` was already collected, rolling back the enclosing Safe batch so the transfer does not execute twice.
    function settleManualClaim(
        uint256 claimId,
        address claimant,
        address recipient,
        address token,
        uint256 amount,
        uint256 fee
    ) external nonReentrant onlySafe {
        if (claimant == address(0) || recipient == address(0) || token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 maxAllowedFee = _feeFor(token, amount);
        if (fee > maxAllowedFee) revert FeeExceedsMax(fee, maxAllowedFee);
        uint256 netAmount = amount - fee;
        if (netAmount == 0) revert ZeroNetAmount();

        if (_claimed.get(claimId)) revert AlreadyClaimed(claimId);
        _claimed.set(claimId);

        emit ManualClaimSettled(claimId, claimant, recipient, token, amount, fee, netAmount);
    }

    /// @notice Top the Claim Float of `token` back up towards its Float Target from `SAFE`.
    /// @dev Permissionless, but only once the float is at or below `REFILL_THRESHOLD_BPS` of the Float Target.
    /// Each refill either restores the target or exhausts the current Period Allowance, which keeps the number of
    /// `AllowanceModule` transfers (and its `uint16` nonce) low regardless of who calls it.
    function refill(
        address token
    ) external nonReentrant whenNotPaused returns (uint256 pulled) {
        uint256 target = floatTarget[token];
        if (target == 0) revert TokenNotEnabled(token);

        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 threshold = (target * REFILL_THRESHOLD_BPS) / BPS_DENOMINATOR;
        if (balance > threshold) revert FloatAboveRefillThreshold(balance, threshold);

        pulled = _refillAmount(token, balance);
        if (pulled == 0) revert NothingToRefill();
        _pull(token, pulled, balance);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function isClaimed(
        uint256 claimId
    ) external view returns (bool) {
        return _claimed.get(claimId);
    }

    /// @notice Claim Fee and Net Amount for a Gross Amount of `token` under its current Fee Rate.
    function quoteFee(
        address token,
        uint256 amount
    ) external view returns (uint256 fee, uint256 netAmount) {
        fee = _feeFor(token, amount);
        netAmount = amount - fee;
    }

    /// @notice Compute the EIP-712 digest that `signer` must sign for a Claim in the current `epoch`.
    function hashClaim(
        address claimant,
        address token,
        uint256 amount,
        uint256 fee,
        uint256 claimId,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash =
            keccak256(abi.encode(CLAIM_TYPEHASH, claimant, token, amount, fee, claimId, epoch, deadline));
        return _hashTypedDataV4(structHash);
    }

    // ---------------------------------------------------------------------
    // Emergency & admin
    // ---------------------------------------------------------------------

    /// @notice Pause self-service Claims and refills. Callable by `SAFE` or `guardian`.
    function pause() external onlySafeOrGuardian {
        _pause();
    }

    /// @notice Resume self-service Claims and refills. Callable only by `SAFE`.
    function unpause() external onlySafe {
        _unpause();
    }

    /// @notice Increment `epoch` by one, invalidating all outstanding signatures from previous epochs.
    /// Callable by `SAFE` or `guardian`.
    function advanceEpoch() external onlySafeOrGuardian returns (uint256 newEpoch) {
        uint256 oldEpoch = epoch;
        newEpoch = oldEpoch + 1;
        epoch = newEpoch;
        emit EpochAdvanced(oldEpoch, newEpoch, msg.sender);
    }

    function setSigner(
        address newSigner
    ) external onlySafe {
        if (newSigner == address(0)) revert ZeroAddress();
        address oldSigner = signer;
        signer = newSigner;
        emit SignerUpdated(oldSigner, newSigner);
    }

    /// @notice Set or clear (`address(0)`) the emergency guardian.
    function setGuardian(
        // forge-lint: disable-next-line(missing-zero-check)
        address newGuardian
    ) external onlySafe {
        address oldGuardian = guardian;
        guardian = newGuardian;
        emit GuardianUpdated(oldGuardian, newGuardian);
    }

    /// @notice Configure the Per-Claim Cap, Fee Rate, and Float Target of `token`.
    /// @dev `newMaxClaimAmount = 0` disables self-service Claims and requires `newFloatTarget = 0`; the Fee Rate
    /// still applies to Manual Settlement. An enabled token needs
    /// `newMaxClaimAmount <= newFloatTarget <= type(uint96).max` so one refill always covers any single Claim and
    /// fits an `AllowanceModule` transfer. The Period Allowance itself is configured on `AllowanceModule`.
    function configureToken(
        address token,
        uint256 newMaxClaimAmount,
        uint256 newFeeBps,
        uint256 newFloatTarget
    ) external onlySafe {
        if (token == address(0)) revert ZeroAddress();
        if (newFeeBps > FEE_BPS_LIMIT) revert FeeBpsTooHigh(newFeeBps, FEE_BPS_LIMIT);
        bool validTarget = newMaxClaimAmount == 0
            ? newFloatTarget == 0
            : newFloatTarget >= newMaxClaimAmount && newFloatTarget <= type(uint96).max;
        if (!validTarget) revert InvalidFloatTarget(newFloatTarget, newMaxClaimAmount);

        maxClaimAmount[token] = newMaxClaimAmount;
        feeBps[token] = newFeeBps;
        floatTarget[token] = newFloatTarget;
        emit TokenConfigured(token, newMaxClaimAmount, newFeeBps, newFloatTarget);
    }

    /// @notice Send ERC-20 tokens held by this contract (Claim Float or mistaken transfers) back to `SAFE`.
    /// @dev Callable by `SAFE` at any time, or by `guardian` only while paused, so a guardian cannot cycle the float
    /// against automatic refills.
    function returnToSafe(
        address token,
        uint256 amount
    ) external nonReentrant onlySafeOrGuardian {
        if (msg.sender != SAFE) _requirePaused();
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        emit FloatReturned(token, amount, msg.sender);
        IERC20(token).safeTransfer(SAFE, amount);
    }

    /// @notice Sweep native ETH (e.g. from `SELFDESTRUCT` prefunding) back to `SAFE`.
    function rescueETH(
        uint256 amount
    ) external onlySafe {
        if (amount == 0) revert ZeroAmount();
        emit ETHRescued(amount);
        Address.sendValue(payable(SAFE), amount);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _feeFor(
        address token,
        uint256 amount
    ) private view returns (uint256) {
        return (amount * feeBps[token]) / BPS_DENOMINATOR;
    }

    /// @dev Amount a refill may pull: the gap to the Float Target, capped by what is left of the Period Allowance.
    /// `setAllowance` lowers `amount` without resetting `spent`, so `spent` can exceed `amount` mid-period.
    function _refillAmount(
        address token,
        uint256 balance
    ) private view returns (uint256) {
        uint256 target = floatTarget[token];
        if (balance >= target) return 0;
        uint256[5] memory allowance = ALLOWANCE_MODULE.getTokenAllowance(SAFE, address(this), token);
        uint256 available = allowance[0] > allowance[1] ? allowance[0] - allowance[1] : 0;
        uint256 gap = target - balance;
        return gap < available ? gap : available;
    }

    function _pull(
        address token,
        uint256 amount,
        uint256 balanceBefore
    ) private {
        // forge-lint: disable-next-line(reentrancy-events)
        emit FloatRefilled(token, amount, balanceBefore + amount, msg.sender);
        ALLOWANCE_MODULE.executeAllowanceTransfer(
            SAFE, token, payable(address(this)), SafeCast.toUint96(amount), address(0), 0, address(this), ""
        );
    }
}
