// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: S6: micro fill below kMin, pass-through payouts pro rata.
// @author adiii.eth

pragma solidity 0.8.34;

import {ScenarioBase} from "./ScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesState} from "../../src/interfaces/iSeries.sol";
import {seriesMath} from "../../src/libraries/seriesMath.sol";

contract S6_MicroFillPassThroughTest is ScenarioBase {
    address borrower = makeAddr("borrower");
    address seniorDepositor = makeAddr("seniorDepositor");
    address juniorDepositor = makeAddr("juniorDepositor");

    function test_S6_microFillBelowKMin_passThroughPayoutsProRata() public {
        _juniorDeposit(juniorDepositor, 500_000e6);
        _seniorDeposit(seniorDepositor, 500_000e6);

        uint256 maturity = block.timestamp + 90 days;
        (address seriesAddr,) = _openSeries(100_000e6, 20_000e6, maturity);
        _registerAndFill(seriesAddr, maturity, 30_000e6, borrower);
        _finalize(seriesAddr);
        creditSeries series = creditSeries(seriesAddr);

        assertTrue(series.passThrough(), "a fill below kMin must set the pass-through flag at finalize");
        uint256 seniorDeployed = series.seniorDeployed();
        uint256 totalFilled = series.totalFilled();
        assertLt(
            totalFilled, 50_000e6, "sanity: the fill must actually be below kMin for this scenario to mean anything"
        );

        vm.warp(maturity + 1);
        series.startSettlement();

        bytes32 marketId = _marketIdOf(series);
        uint128 debtOwed = registry.midnight().debt(marketId, borrower);
        _repay(maturity, borrower, uint256(debtOwed));

        uint256 received = series.collect(0);
        assertTrue(series.resolved(0));

        series.settle();
        assertEq(uint8(series.state()), uint8(SeriesState.SETTLED));

        (uint256 expectedXs, uint256 expectedXj) =
            seriesMath.waterfallPassThrough(received, seniorDeployed, totalFilled);
        assertEq(series.paidS(), expectedXs, "senior's pass-through payout must match seriesMath.waterfallPassThrough");
        assertEq(series.paidJ(), expectedXj, "junior's pass-through payout must match seriesMath.waterfallPassThrough");
        assertEq(series.feeAccounted(), 0, "pass-through mode charges no operator fee at all");
        assertGt(received, totalFilled, "sanity: interest must have accrued so the pass-through split is non-trivial");
    }
}
