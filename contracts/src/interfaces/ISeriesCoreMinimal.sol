// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the minimal slice of SeriesCore that a CreditSeries contract needs to call.
// @author adiii.eth

pragma solidity 0.8.34;

/// @notice The part of the core a series calls.
interface ISeriesCoreMinimal {
    /// @notice Credits undeployed cash returned by a series.
    function receiveReturn(uint256 toSenior, uint256 toJunior) external;

    /// @notice Credits a waterfall payout from a series.
    function receivePayout(uint256 toSenior, uint256 toJunior) external;

    /// @notice Current sentinel.
    function sentinel() external view returns (address);
}
