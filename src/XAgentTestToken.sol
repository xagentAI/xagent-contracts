// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title XAgentTestToken
/// @notice Testnet-only ERC-20 with an open faucet `mint`, used to exercise `XAgentAirdrop` and backend
/// integrations without real assets. The constructor refuses to deploy outside the allowlisted test chains.
contract XAgentTestToken is ERC20 {
    uint8 public constant MAX_DECIMALS = 18;

    /// @notice Upper bound on a single `mint` (1e9 whole tokens) so no caller can push `totalSupply` to overflow.
    uint256 public immutable MAX_MINT_PER_CALL;

    uint8 private immutable _DECIMALS;

    error UnsupportedChain(uint256 chainId);
    error InvalidDecimals(uint8 decimals);
    error MintAmountTooLarge(uint256 amount, uint256 maxAmount);

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        if (!_isTestChain(block.chainid)) revert UnsupportedChain(block.chainid);
        if (decimals_ > MAX_DECIMALS) revert InvalidDecimals(decimals_);

        _DECIMALS = decimals_;
        MAX_MINT_PER_CALL = 1_000_000_000 * 10 ** uint256(decimals_);
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    /// @notice Faucet: anyone may mint up to `MAX_MINT_PER_CALL` to any address.
    function mint(
        address to,
        uint256 amount
    ) external {
        if (amount > MAX_MINT_PER_CALL) revert MintAmountTooLarge(amount, MAX_MINT_PER_CALL);
        _mint(to, amount);
    }

    function _isTestChain(
        uint256 chainId
    ) private pure returns (bool) {
        return chainId == 31_337 // Anvil / forge test
            || chainId == 11_155_111 // Ethereum Sepolia
            || chainId == 421_614 // Arbitrum Sepolia
            || chainId == 1952; // X Layer testnet
    }
}
