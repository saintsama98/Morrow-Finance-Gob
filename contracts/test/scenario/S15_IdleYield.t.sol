// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: S15: idle cash earns in Morpho, and the yield reaches the right people.
// @author adiii.eth

pragma solidity 0.8.34;

import {MorphoScenarioBase} from "./MorphoScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {seriesMath} from "../../src/libraries/seriesMath.sol";
import {wadMath} from "../../src/libraries/wadMath.sol";

contract S15_IdleYieldTest is MorphoScenarioBase {
    using wadMath for uint256;

    address borrower = makeAddr("borrower");
    address seniorDepositor = makeAddr("seniorDepositor");
    address juniorDepositor = makeAddr("juniorDepositor");

    function test_S15_idleYield_raisesBothBookPricesByTheSamePercentage() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 2_000_000e6);

        uint256 seniorIdleBefore = core.idle(true);
        uint256 juniorIdleBefore = core.idle(false);
        uint256 seniorPriceBefore = seniorVault.pricePerShareWad();
        uint256 juniorPriceBefore = juniorVault.pricePerShareWad();

        vault.accrueBps(500);

        assertApproxEqAbs(core.idle(true), seniorIdleBefore * 10_450 / 10_000, 2, "senior idle +4.5%");
        assertApproxEqAbs(core.idle(false), juniorIdleBefore * 10_450 / 10_000, 2, "junior idle +4.5%");
        assertGt(seniorVault.pricePerShareWad(), seniorPriceBefore, "senior price rises");
        assertGt(juniorVault.pricePerShareWad(), juniorPriceBefore, "junior price rises");
        assertApproxEqRel(
            seniorVault.pricePerShareWad().wDivDown(seniorPriceBefore),
            juniorVault.pricePerShareWad().wDivDown(juniorPriceBefore),
            1e12,
            "idle yield is not tranched: both prices rise by the same percentage"
        );
        _assertBooksReconcile();
    }

    function test_S15_yieldOnDeployingCash_isSplitByJuniorShareAtFinalize() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 1_000_000e6);

        uint256 maturity = block.timestamp + 90 days;
        (address seriesAddr,) = _openSeries(700_000e6, 150_000e6, maturity);
        _registerAndFill(seriesAddr, maturity, 150_000e6, borrower);
        creditSeries series = creditSeries(seriesAddr);

        vault.accrueBps(300);
        uint256 balanceAtFinalize = mparking.totalAssets(seriesAddr);

        vm.recordLogs();
        _finalize(seriesAddr);
        (uint256 toSenior, uint256 toJunior) = _decodeReturnReceived();

        uint256 returnS = 700_000e6 - series.seniorDeployed();
        uint256 returnJ = 150_000e6 - series.juniorDeployed();
        assertGt(balanceAtFinalize, returnS + returnJ, "the parked cash earned while the series deployed");

        uint256 extra = balanceAtFinalize - (returnS + returnJ);
        uint256 aWad = uint256(150_000e6).wDivDown(uint256(850_000e6));
        uint256 extraS = extra.mulDivDown(1e18 - aWad, 1e18);
        assertEq(toSenior, returnS + extraS, "senior gets its undeployed cash plus (1 - a) of the yield");
        assertEq(toJunior, returnJ + (extra - extraS), "junior gets its undeployed cash plus a of the yield");
        _assertBooksReconcile();
    }

    function test_S15_yieldOnCollectedCash_goesThroughTheWaterfall() public {
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

        vault.accrueBps(200);
        uint256 proceeds = mparking.totalAssets(seriesAddr);
        assertGt(proceeds, received, "collected cash earned before settlement");

        series.settle();

        (uint256 xs, uint256 xj, uint256 fee) =
            seriesMath.waterfall(proceeds, series.seniorClaim(), series.juniorDeployed(), 0.1e18);
        assertEq(series.paidS(), xs, "senior paid per the waterfall on proceeds including parking yield");
        assertEq(series.paidJ(), xj, "junior paid the residual");
        assertEq(series.feeAccounted(), fee);
        assertEq(series.paidS(), series.seniorClaim(), "a profitable series pays senior its full claim first");
        _assertBooksReconcile();
    }
}
