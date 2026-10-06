// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the ERC-20 surface Morrow calls on USDC and on parking venues.
// @author adiii.eth

pragma solidity 0.8.34;

/// @notice Minimal ERC-20.
interface iErc20Like {
    /// @notice Token balance of an account.
    function balanceOf(address account) external view returns (uint256);
    /// @notice Transfers tokens from the caller.
    function transfer(address to, uint256 amount) external returns (bool);
    /// @notice Transfers tokens using an allowance.
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    /// @notice Sets an allowance.
    function approve(address spender, uint256 amount) external returns (bool);
}
