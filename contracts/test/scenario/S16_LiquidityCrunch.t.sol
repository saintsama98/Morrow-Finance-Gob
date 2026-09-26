// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: S16: the Morpho vault stops paying out; what still works and what waits.
// @author adiii.eth

pragma solidity 0.8.34;

import {Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {Midnight} from "@morpho-org/midnight/src/Midnight.sol";
import {MorphoScenarioBase} from "./MorphoScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {morphoParking} from "../../src/parking/morphoParking.sol";
import {SeriesState} from "../../src/interfaces/iSeries.sol";

contract S16_LiquidityCrunchTest is MorphoScenarioBase {
    address borrower = makeAddr("borrower");
    address seniorA = makeAddr("seniorA");
    address seniorB = makeAddr("seniorB");
    address juniorDepositor = makeAddr("juniorDepositor");

    function test_S16_exitFillsOnlyWhatIsLiquid_thenCompletes() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        uint256 sharesA = _seniorDeposit(seniorA, 500_000e6);
        _seniorDeposit(seniorB, 500_000e6);

        vault.setLiquidityCap(0);
        uint256 liquid = core.parkingLiquidity();
        assertLt(liquid, 500_000e6, "sanity: only the buffer is liquid, less than the exit");

        vm.prank(seniorA);
        uint256 requestId = seniorVault.requestRedeem(sharesA, seniorA, seniorA);
        vm.prank(registry.CURATOR());
        seniorVault.closeEpoch();
        vm.prank(registry.CURATOR());
        seniorVault.fulfill(requestId, type(uint128).max);

        (,, uint256 filledInCrunch, uint256 assetsInCrunch,,) = seniorVault.epochs(requestId);
        assertGt(filledInCrunch, 0, "the liquid buffer is used");
        assertLt(filledInCrunch, sharesA, "the fill is partial, not a revert");
        assertLe(assetsInCrunch, liquid, "never more than was liquid");

        vault.setLiquidityCap(type(uint256).max);
        vm.prank(registry.CURATOR());
        seniorVault.fulfill(requestId, type(uint128).max);
        (,, uint256 filledAfter,,,) = seniorVault.epochs(requestId);
        assertEq(filledAfter, sharesA, "the exit completes once liquidity returns");

        vm.prank(seniorA);
        uint256 paid = seniorVault.redeem(sharesA, seniorA, seniorA);
        assertApproxEqAbs(paid, 500_000e6, 2, "the exiter is paid in full");
        _assertBooksReconcile();
    }

    function test_S16_seriesOpenCancelFinalizeAndSettle_withoutAnyLiquidity() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorA, 1_000_000e6);
        vault.setLiquidityCap(0);

        (address canceled,) = _openSeries(700_000e6, 150_000e6, block.timestamp + 60 days);
        _cancel(canceled);
        assertApproxEqAbs(core.idle(true), 1_000_000e6, 2, "senior idle back in full");
        assertApproxEqAbs(core.idle(false), 1_000_000e6, 2, "junior idle back in full");

        uint256 maturity = block.timestamp + 90 days;
        (address seriesAddr,) = _openSeries(700_000e6, 150_000e6, maturity);
        vault.setLiquidityCap(type(uint256).max);
        _registerAndFill(seriesAddr, maturity, 800_000e6, borrower);

        vault.setLiquidityCap(0);
        uint256 seniorBefore = core.seniorAssets();
        _finalize(seriesAddr);
        creditSeries series = creditSeries(seriesAddr);
        vm.warp(maturity + 1);
        series.startSettlement();
        _repay(maturity, borrower, _debtOf(_marketIdOf(series), borrower));
        series.collect(0);
        series.settle();

        assertEq(uint8(series.state()), uint8(SeriesState.SETTLED), "settlement completes in the crunch");
        assertGt(core.seniorAssets(), seniorBefore, "the books were paid");
        _assertBooksReconcile();
    }

    function test_S16_bidFillIsBoundedByLiquidity_andResumesAfter() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorA, 1_000_000e6);

        uint256 maturity = block.timestamp + 90 days;
        (address seriesAddr,) = _openSeries(700_000e6, 150_000e6, maturity);
        creditSeries series = creditSeries(seriesAddr);
        (Offer memory offer, bytes memory ratifierData) = _registerBid(seriesAddr, maturity, 800_000e6, borrower);

        vault.setLiquidityCap(0);
        uint256 bound = series.buyerAssetsBound(bytes32(0), offer.market, address(0), abi.encode(uint256(0)));
        assertEq(bound, mparking.liquidity(), "the bound is what parking can pay out right now");
        assertLt(bound, 800_000e6, "sanity: less than the take below needs");

        Midnight midnight = registry.midnight();
        vm.prank(borrower);
        vm.expectPartialRevert(morphoParking.Illiquid.selector);
        midnight.take(offer, ratifierData, 800_000e6, borrower, borrower, address(0), "");

        vault.setLiquidityCap(type(uint256).max);
        assertEq(
            series.buyerAssetsBound(bytes32(0), offer.market, address(0), abi.encode(uint256(0))),
            850_000e6,
            "with the vault liquid again, the bound is the series' remaining allocation"
        );
        _take(offer, ratifierData, 800_000e6, borrower);
        assertGt(series.totalFilled(), 0, "the same take succeeds once liquidity returns");
    }
}
