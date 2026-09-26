// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: S1: bad debt small enough for junior's own cushion to absorb.
// @author adiii.eth

pragma solidity 0.8.34;

import {ScenarioBase} from "./ScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";

contract S1_SmallBadDebtTest is ScenarioBase {
    address borrower = makeAddr("borrower");
    address seniorDepositor = makeAddr("seniorDepositor");
    address juniorDepositor = makeAddr("juniorDepositor");

    function test_S1_smallBadDebt_juniorAbsorbs_seniorUntouched() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 1_000_000e6);

        uint256 maturity = block.timestamp + 90 days;
        (address seriesAddr,) = _openSeries(700_000e6, 200_000e6, maturity);
        _registerAndFill(seriesAddr, maturity, 800_000e6, borrower);
        _finalize(seriesAddr);
        creditSeries series = creditSeries(seriesAddr);

        uint256 seniorPriceBefore = seniorVault.pricePerShareWad();
        uint256 juniorPriceBefore = juniorVault.pricePerShareWad();

        vm.warp(block.timestamp + 20 days);
        _crashOracle(2_700);
        _liquidate(maturity, borrower);

        series.navsSynced();

        uint256 seniorPriceAfter = seniorVault.pricePerShareWad();
        uint256 juniorPriceAfter = juniorVault.pricePerShareWad();

        assertLt(juniorPriceAfter, juniorPriceBefore, "junior price must step down once the loss is synced");
        assertGe(
            seniorPriceAfter,
            seniorPriceBefore,
            "senior price must never be depressed by a loss junior's cushion fully absorbs"
        );

        _restoreOracle();
    }
}
