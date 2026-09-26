// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: S3: maturity wall, half the borrowers overdue, auctions clear with no loss.
// @author adiii.eth

pragma solidity 0.8.34;

import {ScenarioBase} from "./ScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesState} from "../../src/interfaces/iSeries.sol";
import {seriesMath} from "../../src/libraries/seriesMath.sol";

contract S3_MaturityWallTest is ScenarioBase {
    address borrowerA = makeAddr("borrowerA");
    address borrowerB = makeAddr("borrowerB");
    address seniorDepositor = makeAddr("seniorDepositor");
    address juniorDepositor = makeAddr("juniorDepositor");

    function test_S3_maturityWall_overdueAuctionRecoversInFull_noLoss() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 1_000_000e6);

        uint256 maturity = block.timestamp + 90 days;
        (address seriesAddr,) = _openSeries(700_000e6, 150_000e6, maturity);
        _registerAndFill(seriesAddr, maturity, 440_000e6, borrowerA);
        _registerAndFill(seriesAddr, maturity, 360_000e6, borrowerB);
        _finalize(seriesAddr);
        creditSeries series = creditSeries(seriesAddr);

        uint256 seniorClaim = series.seniorClaim();
        uint256 juniorDeployed = series.juniorDeployed();
        bytes32 marketId = _marketIdOf(series);

        vm.warp(maturity + 1);
        series.startSettlement();
        assertEq(uint8(series.state()), uint8(SeriesState.SETTLING));

        uint128 debtA = registry.midnight().debt(marketId, borrowerA);
        _repay(maturity, borrowerA, uint256(debtA));

        vm.warp(block.timestamp + 3 days);
        _liquidateOverdueFull(maturity, borrowerB);
        assertEq(_debtOf(marketId, borrowerB), 0, "borrower B's debt must be fully cleared by the overdue liquidation");

        uint256 received = series.collect(0);
        assertTrue(series.resolved(0), "market must be resolved once both borrowers are cleared");

        series.settle();
        assertEq(uint8(series.state()), uint8(SeriesState.SETTLED));

        (uint256 expectedXs, uint256 expectedXj, uint256 expectedFee) =
            seriesMath.waterfall(received, seniorClaim, juniorDeployed, 0.1e18);
        assertEq(series.paidS(), expectedXs, "cumulative senior payout must match seriesMath.waterfall");
        assertEq(series.paidJ(), expectedXj, "cumulative junior payout must match seriesMath.waterfall");
        assertEq(series.paidS(), seniorClaim, "an overdue auction that recovers in full must leave senior whole");
        assertGt(expectedFee, 0, "a clean maturity-wall resolution should still recognize a positive operator fee");
    }
}
