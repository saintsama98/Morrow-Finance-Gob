// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: S8: one-block oracle manipulation, loss realized junior first.
// @author adiii.eth

pragma solidity 0.8.34;

import {ScenarioBase} from "./ScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";

contract S8_OracleManipulationTest is ScenarioBase {
    address borrower = makeAddr("borrower");
    address seniorDepositor = makeAddr("seniorDepositor");
    address juniorDepositor = makeAddr("juniorDepositor");

    function test_S8_oneBlockOracleManipulation_juniorAbsorbsFirst_onlySyncTouched() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 1_000_000e6);

        uint256 maturity = block.timestamp + 90 days;
        (address seriesAddr,) = _openSeries(700_000e6, 300_000e6, maturity);
        _registerAndFill(seriesAddr, maturity, 800_000e6, borrower);
        _finalize(seriesAddr);
        creditSeries series = creditSeries(seriesAddr);

        uint256 seniorPriceBefore = seniorVault.pricePerShareWad();
        uint256 juniorPriceBefore = juniorVault.pricePerShareWad();
        (, uint256 navJBefore,) = series.navs();

        _crashOracle(4_000);
        _liquidate(maturity, borrower);
        series.navsSynced();

        uint256 seniorPriceAfter = seniorVault.pricePerShareWad();
        uint256 juniorPriceAfter = juniorVault.pricePerShareWad();
        (, uint256 navJAfter,) = series.navs();

        assertLt(navJAfter, navJBefore, "the series' junior NAV must absorb the manipulation's realized loss");
        assertLt(juniorPriceAfter, juniorPriceBefore, "junior's vault price must step down at the sync that follows");
        assertGt(navJAfter, 0, "the 0.30 cushion must be wide enough that junior is not wiped by this crash");
        assertGe(
            seniorPriceAfter,
            seniorPriceBefore,
            "senior must never be depressed by a loss that stays inside junior's cushion -- loss hits junior first"
        );

        _restoreOracle();
        series.navsSynced();
        uint256 juniorPriceAfterRestore = juniorVault.pricePerShareWad();
        assertLe(
            juniorPriceAfterRestore,
            juniorPriceBefore,
            "restoring the oracle must not erase a loss already realized through liquidation"
        );
    }
}
