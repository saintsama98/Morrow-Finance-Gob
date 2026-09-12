// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @dev Only what Series needs to call on the core. The full
/// This lets Series be built and tested against a stub.
interface ISeriesCoreMinimal {
    function receiveReturn(uint256 toSenior, uint256 toJunior) external;
    function receivePayout(uint256 toSenior, uint256 toJunior) external;
    function sentinel() external view returns (address);
}
