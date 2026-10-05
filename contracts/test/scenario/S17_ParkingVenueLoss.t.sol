// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: S17: the Morpho vault takes a loss; who bears it, and nothing freezes.
// @author adiii.eth

pragma solidity 0.8.34;

import {MorphoScenarioBase} from "./MorphoScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesState} from "../../src/interfaces/iSeries.sol";
import {seriesMath} from "../../src/libraries/seriesMath.sol";
import {wadMath} from "../../src/libraries/wadMath.sol";

contract S17_ParkingVenueLossTest is MorphoScenarioBase {
    using wadMath for uint256;

    address borrower = makeAddr("borrower");
    address seniorDepositor = makeAddr("seniorDepositor");
    address juniorDepositor = makeAddr("juniorDepositor");

    function test_S17_lossOnIdle_fallsOnJuniorFirst() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 2_000_000e6);

        uint256 seniorIdleBefore = core.idle(true);
        uint256 juniorIdleBefore = core.idle(false);

        vault.loseBps(1_000);

        assertApproxEqAbs(core.idle(true), seniorIdleBefore, 2, "senior idle untouched");
        assertApproxEqAbs(core.idle(false), juniorIdleBefore - 270_000e6, 2, "junior idle absorbs the whole 270k loss");
        _assertBooksReconcile();
    }

    function test_S17_lossOnCollectedCash_stillPaysSeniorFirst() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 1_000_000e6);

        uint256 maturity = block.timestamp + 90 days;
        (address seriesAddr,) = _openSeries(700_000e6, 150_000e6, maturity);
        _registerAndFill(seriesAddr, maturity, 800_000e6, borrower);
        _finalize(seriesAddr);
        creditSeries series = creditSeries(seriesAddr);

        vm.warp(maturity + 1);
        series.startSettlement();
        _repay(maturity, borrower, _debtOf(_marketIdOf(series), borrower));
        uint256 received = series.collect(0);

        vault.loseBps(3_000);
        uint256 proceeds = mparking.totalAssets(seriesAddr);
        assertLt(proceeds, received, "the venue loss reached the collected cash");

        series.settle();
        (uint256 xs, uint256 xj,) =
            seriesMath.waterfall(proceeds, series.seniorClaim(), series.juniorDeployed(), 0.1e18);
        assertEq(series.paidS(), xs, "senior is paid first out of the reduced proceeds");
        assertEq(series.paidJ(), xj, "junior takes what is left");
        assertLt(series.paidS(), series.seniorClaim(), "a loss this large reaches senior's claim");
        _assertBooksReconcile();
    }

    function test_S17_lossBelowAlreadyPaid_neverFreezesLaterCollects() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 1_000_000e6);

        uint256 maturity = block.timestamp + 90 days;
        (address seriesAddr,) = _openSeries(700_000e6, 150_000e6, maturity);
        _registerAndFill(seriesAddr, maturity, 800_000e6, borrower);
        _finalize(seriesAddr);
        creditSeries series = creditSeries(seriesAddr);
        bytes32 marketId = _marketIdOf(series);

        vm.warp(maturity + 1);
        series.startSettlement();
        _repay(maturity, borrower, _debtOf(marketId, borrower) - 1e6);
        series.collect(0);
        vm.warp(maturity + series.D_WRITE_OFF());
        series.writeOff();
        assertFalse(series.resolved(0), "sanity: 1 USDC of credit is still outstanding");
        assertGt(series.feeAccounted(), 1e6, "sanity: an unclaimed fee larger than the outstanding 1 USDC is parked");

        uint256 paidSBefore = series.paidS();
        uint256 paidJBefore = series.paidJ();
        uint256 feeBefore = series.feeAccounted();

        vault.loseBps(5_000);

        _repay(maturity, borrower, _debtOf(marketId, borrower));
        series.collect(0);

        assertTrue(series.resolved(0), "the market resolves");
        assertEq(uint8(series.state()), uint8(SeriesState.SETTLED));
        assertEq(series.paidS(), paidSBefore, "senior's paid amount never goes down");
        assertEq(series.paidJ(), paidJBefore, "junior waits at what it was already paid");
        assertEq(series.feeAccounted(), feeBefore, "the recognized fee never goes down");

        uint256 parked = mparking.totalAssets(seriesAddr);
        assertLt(parked, feeBefore, "sanity: less is parked than the recognized fee");
        uint256 recipientBefore = usdc.balanceOf(registry.FEE_RECIPIENT());
        series.claimFee();
        assertApproxEqAbs(usdc.balanceOf(registry.FEE_RECIPIENT()) - recipientBefore, parked, 1);
        _assertBooksReconcile();
    }
}
