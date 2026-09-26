// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: S4: stuck market, written off then repaid late, recovery flows senior first.
// @author adiii.eth

pragma solidity 0.8.34;

import {ScenarioBase} from "./ScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesState} from "../../src/interfaces/iSeries.sol";
import {seriesMath} from "../../src/libraries/seriesMath.sol";

contract S4_StuckMarketTest is ScenarioBase {
    address borrower = makeAddr("borrower");
    address seniorDepositor = makeAddr("seniorDepositor");
    address juniorDepositor = makeAddr("juniorDepositor");

    function test_S4_stuckMarket_writeOffThenLateRepayment_seniorFirst_gateReopens() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 1_000_000e6);

        uint256 maturity = block.timestamp + 90 days;
        (address seriesAddr,) = _openSeries(700_000e6, 150_000e6, maturity);
        _registerAndFill(seriesAddr, maturity, 800_000e6, borrower);
        _finalize(seriesAddr);
        creditSeries series = creditSeries(seriesAddr);

        uint256 seniorClaim = series.seniorClaim();
        uint256 juniorDeployed = series.juniorDeployed();
        bytes32 marketId = _marketIdOf(series);

        vm.warp(maturity + 1);
        series.startSettlement();

        vm.warp(maturity + series.D_WRITE_OFF());
        series.writeOff();
        assertEq(uint8(series.state()), uint8(SeriesState.SETTLED));
        assertTrue(series.writtenOff(0), "the unresolved market must be marked written off");
        assertFalse(series.resolved(0), "written-off credit is kept, not resolved, until actually recovered");

        assertFalse(core.stressGateOpen(), "stress gate must close while written-off credit is still outstanding");
        usdc.mint(seniorDepositor, 1);
        vm.prank(seniorDepositor);
        usdc.approve(address(seniorVault), 1);
        vm.prank(seniorDepositor);
        vm.expectRevert();
        seniorVault.deposit(1, seniorDepositor);

        vm.warp(block.timestamp + 10 days);
        uint128 debtOwed = registry.midnight().debt(marketId, borrower);
        _repay(maturity, borrower, uint256(debtOwed));

        uint256 received = series.collect(0);
        assertTrue(series.resolved(0), "the market must resolve once the full late repayment is collected");

        (uint256 expectedXs,, uint256 expectedFee) = seriesMath.waterfall(received, seniorClaim, juniorDeployed, 0.1e18);
        assertEq(series.paidS(), expectedXs, "the recovery must pay senior first, per the cumulative waterfall");
        assertGe(expectedFee, 0);

        assertTrue(core.stressGateOpen(), "stress gate must reopen once the written-off credit is fully recovered");
        _seniorDeposit(seniorDepositor, 1);
    }
}
