// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

// Morrow Finance — adapter interface for parking idle capital between deployments.
// @author adiii.eth

/// @notice Adapter interface for idle capital. One adapter is shared by every depositor (the core's books and
/// each series while deploying); it tracks each depositor's own balance internally, keyed by caller address.
interface IParking {
    /// @notice Deposits `assets` from the caller into the caller's own tracked balance.
    function deposit(uint256 assets) external;

    /// @notice Withdraws `assets` from the caller's own balance to `to`.
    function withdraw(uint256 assets, address to) external;

    /// @notice The given account's current withdrawable value, in assets.
    function totalAssets(address account) external view returns (uint256);
}
