// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: S12: a loss realized between epoch close and fulfillment prices at the lower value.
// @author adiii.eth

pragma solidity 0.8.34;

import {ScenarioBase} from "./ScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {epochMath} from "../../src/libraries/epochMath.sol";

contract S12_RedemptionQueuedLossBeforeFulfillmentTest is ScenarioBase {
    address borrower = makeAddr("borrower");
    address seniorDepositor = makeAddr("seniorDepositor");
    address juniorDepositor = makeAddr("juniorDepositor");

    function test_S12_lossBetweenCloseAndFulfill_pricedAtLowerPostLossValue() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 1_000_000e6);

        uint256 maturity = block.timestamp + 90 days;
        (address seriesAddr,) = _openSeries(700_000e6, 150_000e6, maturity);
        _registerAndFill(seriesAddr, maturity, 800_000e6, borrower);
        _finalize(seriesAddr);
        creditSeries series = creditSeries(seriesAddr);

        uint256 sharesToRedeem = seniorVault.balanceOf(seniorDepositor) / 10;
        vm.prank(seniorDepositor);
        uint256 requestId = seniorVault.requestRedeem(sharesToRedeem, seniorDepositor, seniorDepositor);

        vm.prank(registry.CURATOR());
        seniorVault.closeEpoch();
        (,,,, uint256 ppsCloseWad,) = seniorVault.epochs(requestId);

        _crashOracle(4_000);
        _liquidate(maturity, borrower);
        series.navsSynced();

        uint256 ppsNowWad = seniorVault.pricePerShareWad();
        assertLt(
            ppsNowWad, ppsCloseWad, "sanity: the loss realized between close and fulfill must depress the live price"
        );

        vm.prank(registry.CURATOR());
        seniorVault.fulfill(requestId, type(uint128).max);

        (,, uint256 sharesFulfilled, uint256 assetsFulfilled,,) = seniorVault.epochs(requestId);
        assertEq(sharesFulfilled, sharesToRedeem, "sanity: this fill must be complete, well inside idle");

        uint256 expectedAssetsAtPostLossPrice = epochMath.assetsForShares(sharesToRedeem, ppsNowWad);
        uint256 assetsAtStalePrice = epochMath.assetsForShares(sharesToRedeem, ppsCloseWad);

        assertEq(
            assetsFulfilled,
            expectedAssetsAtPostLossPrice,
            "the fill must use the post-loss live price (the min rule), not the stale pre-loss snapshot"
        );
        assertLt(
            assetsFulfilled,
            assetsAtStalePrice,
            "the redeemer must receive strictly less than the stale pre-loss snapshot would have paid"
        );

        _restoreOracle();
    }
}
