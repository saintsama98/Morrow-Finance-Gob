// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the ERC-4626 surface Morrow calls on the Morpho vault behind parking.
// @author adiii.eth

pragma solidity 0.8.34;

/// @notice Minimal ERC-4626.
interface iErc4626Like {
    /// @notice Underlying asset.
    function asset() external view returns (address);
    /// @notice Share balance of an account.
    function balanceOf(address account) external view returns (uint256);
    /// @notice Deposits assets for shares.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    /// @notice Withdraws assets by burning shares.
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    /// @notice Assets a share amount redeems for.
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    /// @notice Assets an owner can withdraw now.
    function maxWithdraw(address owner) external view returns (uint256);
    /// @notice Assets a receiver can deposit now.
    function maxDeposit(address receiver) external view returns (uint256);
}
