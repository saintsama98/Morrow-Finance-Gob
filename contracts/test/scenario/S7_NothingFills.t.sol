// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: S7: nothing fills.
// @author adiii.eth

pragma solidity 0.8.34;

import {ScenarioBase} from "./ScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesState} from "../../src/interfaces/iSeries.sol";

contract S7_NothingFillsTest is ScenarioBase {
    address seniorDepositor = makeAddr("seniorDepositor");
    address juniorDepositor = makeAddr("juniorDepositor");

    function test_S7_nothingFills_cancelsAndReturnsFullCash() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 1_000_000e6);

        (uint256 seniorIdleBefore, uint256 juniorIdleBefore) = (core.idle(true), core.idle(false));

        (address seriesAddr,) = _openSeries(400_000e6, 100_000e6, block.timestamp + 30 days);
        creditSeries series = creditSeries(seriesAddr);
        assertEq(series.totalFilled(), 0, "nothing has been taken yet");
        assertEq(core.idle(true), seniorIdleBefore - 400_000e6, "senior idle must drop by exactly S while deploying");
        assertEq(core.idle(false), juniorIdleBefore - 100_000e6, "junior idle must drop by exactly J while deploying");

        _cancel(seriesAddr);

        assertEq(uint8(series.state()), uint8(SeriesState.CANCELED), "an unfilled series must cancel, not settle");
        assertEq(core.idle(true), seniorIdleBefore, "senior idle must return to exactly what it was before opening");
        assertEq(core.idle(false), juniorIdleBefore, "junior idle must return to exactly what it was before opening");
        assertEq(usdc.balanceOf(seriesAddr), 0, "the series must hold no residual usdc after cancellation");
    }
}
