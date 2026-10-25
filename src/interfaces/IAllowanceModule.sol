// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @notice Minimal interface for Safe's canonical `AllowanceModule` (`v1.0.0`,
/// `0x691f59471Bfd2B7d639DCF74671a2d648ED1E331`).
/// @dev In `AllowanceModule.sol`, the first argument of `executeAllowanceTransfer` is typed `ISafe`,
/// which encodes identically to `address` in the ABI. When `signature` has zero length,
/// `AllowanceModule` authenticates the transfer against `msg.sender` as the delegate.
interface IAllowanceModule {
    function executeAllowanceTransfer(
        address safe,
        address token,
        address payable to,
        uint96 amount,
        address paymentToken,
        uint96 payment,
        address delegate,
        bytes memory signature
    ) external;

    /// @return allowance `[amount, spent, resetTimeMin, lastResetMin, nonce]`
    function getTokenAllowance(
        address safe,
        address delegate,
        address token
    ) external view returns (uint256[5] memory allowance);
}
