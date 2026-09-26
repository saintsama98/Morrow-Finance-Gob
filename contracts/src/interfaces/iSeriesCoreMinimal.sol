// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the minimal slice of seriesCore that a creditSeries contract needs to call.
// @author adiii.eth

pragma solidity 0.8.34;

interface iSeriesCoreMinimal {
    function receiveReturn(uint256 toSenior, uint256 toJunior) external;

    function receivePayout(uint256 toSenior, uint256 toJunior) external;

    function sentinel() external view returns (address);
}
