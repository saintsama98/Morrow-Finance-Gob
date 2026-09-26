// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: S9: fees at their caps, no double counting, exact conservation.
// @author adiii.eth

pragma solidity 0.8.34;

import {ScenarioBase} from "./ScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesState} from "../../src/interfaces/iSeries.sol";
import {seriesMath} from "../../src/libraries/seriesMath.sol";

contract S9_FeesAtCapsTest is ScenarioBase {
    address borrower = makeAddr("borrower");
    address seniorDepositor = makeAddr("seniorDepositor");
    address juniorDepositor = makeAddr("juniorDepositor");

    uint256 internal constant MAX_CONTINUOUS_FEE = 317097919;

    function test_S9_feesAtCaps_noDoubleCount_exactConservation() public {
        registry.setDefaultContinuousFee(MAX_CONTINUOUS_FEE);

        address curator = registry.CURATOR();
        vm.prank(curator);
        core.proposePolicyChange(keccak256("thetaWad"), 0.2e18);
        vm.warp(block.timestamp + core.CURATOR_TIMELOCK());
        core.executePolicyChange(keccak256("thetaWad"));

        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 1_000_000e6);

        uint256 maturity = block.timestamp + 90 days;
        (address seriesAddr,) = _openSeriesWithTheta(700_000e6, 150_000e6, maturity, 0.2e18);
        _registerAndFill(seriesAddr, maturity, 800_000e6, borrower);
        _finalize(seriesAddr);
        creditSeries series = creditSeries(seriesAddr);

        assertLt(
            series.faceNetAtFinalize(),
            series.faceGross(),
            "F_net must be strictly less than F: Midnight's continuous fee crystallized a positive amount"
        );

        uint256 seniorClaim = series.seniorClaim();
        uint256 juniorDeployed = series.juniorDeployed();
        bytes32 marketId = _marketIdOf(series);

        vm.warp(maturity + 1);
        series.startSettlement();

        uint128 debtOwed = registry.midnight().debt(marketId, borrower);
        _repay(maturity, borrower, uint256(debtOwed));

        uint256 received = series.collect(0);
        assertTrue(series.resolved(0));

        series.settle();
        assertEq(uint8(series.state()), uint8(SeriesState.SETTLED));

        (uint256 expectedXs, uint256 expectedXj, uint256 expectedFee) =
            seriesMath.waterfall(received, seniorClaim, juniorDeployed, 0.2e18);
        assertGt(expectedFee, 0, "sanity: a 0.20e18 theta on a clean settlement must recognize a positive fee");
        assertEq(series.paidS(), expectedXs, "senior payout must match seriesMath.waterfall at the 0.20e18 cap");
        assertEq(series.paidJ(), expectedXj, "junior payout must match seriesMath.waterfall at the 0.20e18 cap");
        assertEq(series.feeAccounted(), expectedFee, "recognized fee must match seriesMath.waterfall exactly");

        assertEq(
            series.paidS() + series.paidJ() + series.feeAccounted(),
            received,
            "senior + junior + fee must exactly conserve cumulative proceeds, nothing left over or double counted"
        );

        uint256 feeRecipientBalanceBefore = usdc.balanceOf(registry.FEE_RECIPIENT());
        series.claimFee();
        uint256 feeRecipientBalanceAfterFirst = usdc.balanceOf(registry.FEE_RECIPIENT());
        assertEq(
            feeRecipientBalanceAfterFirst - feeRecipientBalanceBefore,
            expectedFee,
            "the first claimFee() must pay out exactly the recognized fee"
        );
        series.claimFee();
        uint256 feeRecipientBalanceAfterSecond = usdc.balanceOf(registry.FEE_RECIPIENT());
        assertEq(
            feeRecipientBalanceAfterSecond, feeRecipientBalanceAfterFirst, "a second claimFee() must move zero assets"
        );
        assertEq(series.feeClaimed(), series.feeAccounted(), "feeClaimed must settle exactly at feeAccounted, no more");
    }
}
