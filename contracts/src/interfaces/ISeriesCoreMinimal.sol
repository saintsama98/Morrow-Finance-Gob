// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @dev Only what Series needs to call on the core (section 14, section 3.1's sentinel role). The full
/// SeriesCore (section 20) is built in M5; this lets Series be built and tested against a stub now.
interface ISeriesCoreMinimal {
    function receiveReturn(uint256 toSenior, uint256 toJunior) external;
    function receivePayout(uint256 toSenior, uint256 toJunior) external;
    function sentinel() external view returns (address);
}
