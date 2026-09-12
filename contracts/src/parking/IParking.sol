// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @dev Adapter interface for idle capital, section 3.2/4. One parking adapter is shared by every depositor
/// (the core's books, and each series while DEPLOYING); it tracks each depositor's own balance internally, so
/// "the series parks cash in its own parking position" (section 8.2) just means the series is one of the
/// adapter's depositors, keyed by `msg.sender`.
interface IParking {
    function deposit(uint256 assets) external;

    /// @dev Withdraws from the caller's own balance, previously deposited by the caller.
    function withdraw(uint256 assets, address to) external;

    /// @dev The caller-specified account's current withdrawable value, in assets.
    function totalAssets(address account) external view returns (uint256);
}
