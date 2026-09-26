// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: S2: bad debt severe enough to wipe junior and impair senior.
// @author adiii.eth

pragma solidity 0.8.34;

import {ScenarioBase} from "./ScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";

contract S2_JuniorWipeTest is ScenarioBase {
    address borrower = makeAddr("borrower");
    address seniorDepositor = makeAddr("seniorDepositor");
    address juniorDepositor = makeAddr("juniorDepositor");

    function test_S2_severeBadDebt_juniorWiped_seniorImpaired_stressGateCloses() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 1_000_000e6);

        uint256 maturity = block.timestamp + 90 days;
        (address seriesAddr,) = _openSeries(700_000e6, 150_000e6, maturity);
        _registerAndFill(seriesAddr, maturity, 800_000e6, borrower);
        _finalize(seriesAddr);
        creditSeries series = creditSeries(seriesAddr);

        assertTrue(core.stressGateOpen(), "stress gate must start open");

        uint256 seniorPriceBefore = seniorVault.pricePerShareWad();

        vm.warp(block.timestamp + 20 days);
        _crashOracle(4_000);
        _liquidate(maturity, borrower);

        series.navsSynced();

        (, uint256 navJAfter,) = series.navs();
        uint256 seniorPriceAfter = seniorVault.pricePerShareWad();

        assertEq(navJAfter, 0, "junior's NAV in this series must be fully wiped by a loss exceeding its cushion");
        assertLt(seniorPriceAfter, seniorPriceBefore, "senior price must drop once the shortfall spills past junior");
        assertFalse(core.stressGateOpen(), "stress gate must close once this series' junior NAV is wiped");

        vm.prank(seniorDepositor);
        vm.expectRevert();
        seniorVault.deposit(1, seniorDepositor);

        _restoreOracle();
    }
}
