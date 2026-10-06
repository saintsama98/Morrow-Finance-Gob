// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: adapter interface for parking idle capital between deployments.
// @author adiii.eth

pragma solidity 0.8.34;

/// @notice Where idle cash waits between series; one account per core and per series.
interface iParking {
    /// @notice Parks assets for the caller.
    function deposit(uint256 assets) external;

    /// @notice Withdraws the caller's assets to an address.
    function withdraw(uint256 assets, address to) external;

    /// @notice Moves part of the caller's position to another account.
    function transferPosition(address to, uint256 assets) external;

    /// @notice Value of an account's position.
    function totalAssets(address account) external view returns (uint256);

    /// @notice Assets an account can withdraw now.
    function maxWithdraw(address account) external view returns (uint256);
}
