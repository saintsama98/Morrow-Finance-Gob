// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: S0: two series three weeks apart, both settle clean.
// @author adiii.eth

pragma solidity 0.8.34;

import {ScenarioBase} from "./ScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesState} from "../../src/interfaces/iSeries.sol";
import {seriesMath} from "../../src/libraries/seriesMath.sol";

contract S0_BaselineTest is ScenarioBase {
    address borrowerA = makeAddr("borrowerA");
    address borrowerB = makeAddr("borrowerB");
    address seniorDepositor = makeAddr("seniorDepositor");
    address juniorDepositor = makeAddr("juniorDepositor");

    function test_S0_twoSeriesStaggeredMaturities_bothSettleClean() public {
        _juniorDeposit(juniorDepositor, 5_000_000e6);
        _seniorDeposit(seniorDepositor, 5_000_000e6);

        uint256 pricePerShareSeniorBefore = seniorVault.pricePerShareWad();
        uint256 pricePerShareJuniorBefore = juniorVault.pricePerShareWad();

        uint256 maturityA = block.timestamp + 30 days;
        uint256 maturityB = block.timestamp + 51 days;

        (address seriesA,) = _openSeries(800_000e6, 150_000e6, maturityA);
        _registerAndFill(seriesA, maturityA, 900_000e6, borrowerA);
        _finalize(seriesA);

        (address seriesB,) = _openSeries(800_000e6, 150_000e6, maturityB);
        _registerAndFill(seriesB, maturityB, 900_000e6, borrowerB);
        _finalize(seriesB);

        _settleCleanly(seriesA, maturityA, borrowerA);

        uint256 pricePerShareSeniorMid = seniorVault.pricePerShareWad();
        uint256 pricePerShareJuniorMid = juniorVault.pricePerShareWad();
        assertGt(pricePerShareSeniorMid, pricePerShareSeniorBefore, "senior price must grow after series A settles");
        assertGt(pricePerShareJuniorMid, pricePerShareJuniorBefore, "junior price must grow after series A settles");

        _settleCleanly(seriesB, maturityB, borrowerB);

        uint256 pricePerShareSeniorAfter = seniorVault.pricePerShareWad();
        uint256 pricePerShareJuniorAfter = juniorVault.pricePerShareWad();
        assertGt(
            pricePerShareSeniorAfter, pricePerShareSeniorMid, "senior price must grow again after series B settles"
        );
        assertGt(
            pricePerShareJuniorAfter, pricePerShareJuniorMid, "junior price must grow again after series B settles"
        );
    }

    function _settleCleanly(address seriesAddr, uint256 maturity, address borrower) internal {
        creditSeries series = creditSeries(seriesAddr);
        uint256 seniorClaim = series.seniorClaim();
        uint256 juniorDeployed = series.juniorDeployed();

        vm.warp(maturity + 1);
        series.startSettlement();
        assertEq(uint8(series.state()), uint8(SeriesState.SETTLING));

        uint128 debtOwed = registry.midnight().debt(_marketIdOf(series), borrower);
        usdc.mint(borrower, uint256(debtOwed));
        vm.startPrank(borrower);
        usdc.approve(address(registry.midnight()), uint256(debtOwed));
        registry.midnight().repay(registry.marketFor(maturity), debtOwed, borrower, address(0), "");
        vm.stopPrank();

        uint256 received = series.collect(0);
        assertTrue(series.resolved(0), "market must be resolved once repaid and settlement has begun");

        series.settle();
        assertEq(uint8(series.state()), uint8(SeriesState.SETTLED));

        (uint256 expectedXs, uint256 expectedXj, uint256 expectedFee) =
            seriesMath.waterfall(received, seniorClaim, juniorDeployed, 0.1e18);
        assertEq(series.paidS(), expectedXs, "cumulative senior payout must match seriesMath.waterfall");
        assertEq(series.paidJ(), expectedXj, "cumulative junior payout must match seriesMath.waterfall");
        assertLe(series.paidS(), seniorClaim, "senior payout must never exceed its frozen claim");
        assertGt(expectedFee, 0, "a clean no-loss settlement should recognize a positive operator fee");
    }
}
