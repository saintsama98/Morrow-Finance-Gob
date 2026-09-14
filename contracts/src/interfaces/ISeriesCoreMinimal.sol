// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

// Morrow Finance — the minimal slice of SeriesCore that a Series contract needs to call.
// @author adiii.eth

/// @notice Only what a series needs to call back on the core.
interface ISeriesCoreMinimal {
    /// @notice Returns undeployed capital to the books at finalize or cancel.
    function receiveReturn(uint256 toSenior, uint256 toJunior) external;

    /// @notice Pushes a waterfall payout delta to the books, on every rerun including zero-delta ones.
    function receivePayout(uint256 toSenior, uint256 toJunior) external;

    /// @notice The address allowed to cancel an unfilled series.
    function sentinel() external view returns (address);
}
