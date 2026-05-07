// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {
    ERC20PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/// @title XPoint
/// @notice Upgradeable XAgent points token with role-based controls.
/// @dev Transfer policy supports whitelist mode, blacklist checks, and pausing.
contract XPoint is
    Initializable,
    UUPSUpgradeable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PermitUpgradeable,
    ERC20PausableUpgradeable,
    Ownable2StepUpgradeable,
    AccessControlUpgradeable
{
    // ---------------------------------------------------------------------
    // Roles
    // ---------------------------------------------------------------------

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    mapping(address account => bool isBlocked) private _blacklist;
    mapping(address account => bool isAllowed) private _whitelist;

    bool public whitelistModeEnabled;
    uint256 public maxSupply;

    uint256[40] private __gap;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error LengthMismatch();
    error MaxSupplyExceeded();
    error MaxSupplyBelowCurrent();
    error Blacklisted(address account);
    error NotWhitelisted(address from, address to);
    error RenounceDisabled();
    error DefaultAdminManagedByOwnerOnly();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Minted(address indexed to, uint256 amount);
    event MaxSupplyUpdated(uint256 oldMaxSupply, uint256 newMaxSupply);
    event BlacklistUpdated(address indexed account, bool isBlacklisted);
    event WhitelistUpdated(address indexed account, bool isWhitelisted);
    event WhitelistModeUpdated(bool enabled);

    // ---------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        address owner_,
        address operator_,
        address pauser_,
        uint256 maxSupply_,
        bool whitelistModeEnabled_
    ) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();

        address effectiveOperator = operator_ == address(0) ? owner_ : operator_;
        address effectivePauser = pauser_ == address(0) ? owner_ : pauser_;

        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __Pausable_init();
        __ERC20Pausable_init();
        __AccessControl_init();
        __Ownable2Step_init();
        __Ownable_init(owner_);

        _grantRole(OPERATOR_ROLE, effectiveOperator);
        _grantRole(PAUSER_ROLE, effectivePauser);

        maxSupply = maxSupply_;
        whitelistModeEnabled = whitelistModeEnabled_;
    }

    // ---------------------------------------------------------------------
    // Minting
    // ---------------------------------------------------------------------

    /// @notice Mint XPoint to one recipient.
    function mint(
        address to,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) {
        _mintWithSupplyChecks(to, amount);
    }

    /// @notice Mint XPoint to many recipients.
    function mintBatch(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyRole(MINTER_ROLE) {
        uint256 length = recipients.length;
        if (length != amounts.length) revert LengthMismatch();

        for (uint256 i = 0; i < length; ++i) {
            _mintWithSupplyChecks(recipients[i], amounts[i]);
        }
    }

    /// @notice Set max supply. 0 means uncapped.
    function setMaxSupply(
        uint256 newMaxSupply
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMaxSupply != 0 && newMaxSupply < totalSupply()) revert MaxSupplyBelowCurrent();

        emit MaxSupplyUpdated(maxSupply, newMaxSupply);
        maxSupply = newMaxSupply;
    }

    // ---------------------------------------------------------------------
    // Operator controls
    // ---------------------------------------------------------------------

    function addToBlacklist(
        address account
    ) external onlyRole(OPERATOR_ROLE) {
        _setBlacklist(account, true);
    }

    function removeFromBlacklist(
        address account
    ) external onlyRole(OPERATOR_ROLE) {
        _setBlacklist(account, false);
    }

    function addToBlacklistBatch(
        address[] calldata accounts
    ) external onlyRole(OPERATOR_ROLE) {
        uint256 length = accounts.length;
        for (uint256 i = 0; i < length; ++i) {
            _setBlacklist(accounts[i], true);
        }
    }

    function addToWhitelist(
        address account
    ) external onlyRole(OPERATOR_ROLE) {
        _setWhitelist(account, true);
    }

    function removeFromWhitelist(
        address account
    ) external onlyRole(OPERATOR_ROLE) {
        _setWhitelist(account, false);
    }

    function addToWhitelistBatch(
        address[] calldata accounts
    ) external onlyRole(OPERATOR_ROLE) {
        uint256 length = accounts.length;
        for (uint256 i = 0; i < length; ++i) {
            _setWhitelist(accounts[i], true);
        }
    }

    function setWhitelistMode(
        bool enabled
    ) external onlyRole(OPERATOR_ROLE) {
        whitelistModeEnabled = enabled;
        emit WhitelistModeUpdated(enabled);
    }

    // ---------------------------------------------------------------------
    // Pauser controls
    // ---------------------------------------------------------------------

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function isBlacklisted(
        address account
    ) external view returns (bool) {
        return _blacklist[account];
    }

    function isWhitelisted(
        address account
    ) external view returns (bool) {
        return _whitelist[account];
    }

    // ---------------------------------------------------------------------
    // Role-management policy
    // ---------------------------------------------------------------------

    /// @dev DEFAULT_ADMIN_ROLE is managed exclusively via owner transfer.
    function grantRole(
        bytes32 role,
        address account
    ) public override onlyRole(getRoleAdmin(role)) {
        if (role == DEFAULT_ADMIN_ROLE) revert DefaultAdminManagedByOwnerOnly();
        super.grantRole(role, account);
    }

    /// @dev DEFAULT_ADMIN_ROLE is managed exclusively via owner transfer.
    function revokeRole(
        bytes32 role,
        address account
    ) public override onlyRole(getRoleAdmin(role)) {
        if (role == DEFAULT_ADMIN_ROLE) revert DefaultAdminManagedByOwnerOnly();
        super.revokeRole(role, account);
    }

    /// @dev DEFAULT_ADMIN_ROLE cannot be renounced to avoid orphaning admin.
    function renounceRole(
        bytes32 role,
        address callerConfirmation
    ) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert DefaultAdminManagedByOwnerOnly();
        super.renounceRole(role, callerConfirmation);
    }

    /// @dev Ownership renounce is disabled by design.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------
    // Internal hooks
    // ---------------------------------------------------------------------

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20Upgradeable, ERC20PausableUpgradeable) {
        if (_blacklist[from]) revert Blacklisted(from);
        if (_blacklist[to]) revert Blacklisted(to);

        // Mints and burns bypass whitelist mode.
        if (whitelistModeEnabled && from != address(0) && to != address(0)) {
            if (!_whitelist[from] && !_whitelist[to]) revert NotWhitelisted(from, to);
        }

        super._update(from, to, value);
    }

    function _authorizeUpgrade(
        address
    ) internal override onlyOwner {}

    /// @dev Keep owner as the sole DEFAULT_ADMIN_ROLE holder.
    function _transferOwnership(
        address newOwner
    ) internal override {
        address oldOwner = owner();
        super._transferOwnership(newOwner);

        if (oldOwner != address(0)) {
            _revokeRole(DEFAULT_ADMIN_ROLE, oldOwner);
        }
        if (newOwner != address(0)) {
            _grantRole(DEFAULT_ADMIN_ROLE, newOwner);
        }
    }

    function _mintWithSupplyChecks(
        address to,
        uint256 amount
    ) internal {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 cap = maxSupply;
        if (cap != 0 && totalSupply() + amount > cap) revert MaxSupplyExceeded();

        _mint(to, amount);
        emit Minted(to, amount);
    }

    function _setBlacklist(
        address account,
        bool isBlocked
    ) internal {
        if (account == address(0)) revert ZeroAddress();
        _blacklist[account] = isBlocked;
        emit BlacklistUpdated(account, isBlocked);
    }

    function _setWhitelist(
        address account,
        bool isAllowed
    ) internal {
        if (account == address(0)) revert ZeroAddress();
        _whitelist[account] = isAllowed;
        emit WhitelistUpdated(account, isAllowed);
    }
}
