// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: I12: once a series is funded, every later step completes with only an unprivileged keeper acting.
// @author adiii.eth

pragma solidity 0.8.34;

import {ScenarioBase} from "./ScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesState} from "../../src/interfaces/iSeries.sol";

contract S18_KeeperOnlyLifecycleTest is ScenarioBase {
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address juniorLender = makeAddr("juniorLender");
    address borrower = makeAddr("borrower");

    uint256 maturity;
    creditSeries series;
    bytes32 marketId;

    function _fundedSeries() internal returns (uint256 seniorShares, uint256 juniorShares) {
        juniorShares = _juniorDeposit(juniorLender, 400_000e6);
        seniorShares = _seniorDeposit(alice, 1_000_000e6);
        maturity = block.timestamp + 30 days;
        (address seriesAddr, bytes32 id) = _openSeries(400_000e6, 100_000e6, maturity);
        series = creditSeries(seriesAddr);
        marketId = id;
        _registerAndFill(seriesAddr, maturity, 300_000e6, borrower);
    }

    function _keeperDrivesToSettlement() internal {
        vm.warp(uint256(series.T_DEPLOY_END()) + 1);
        vm.prank(keeper);
        series.finalize();
        assertEq(uint8(series.state()), uint8(SeriesState.LOCKED), "keeper finalizes after the deploy window");

        vm.prank(keeper);
        series.sync(0);

        vm.warp(maturity);
        vm.prank(keeper);
        series.startSettlement();
        assertEq(uint8(series.state()), uint8(SeriesState.SETTLING), "keeper starts settlement at maturity");
    }

    function _keeperExitsSenior(uint256 shares) internal returns (uint256 paid) {
        vm.prank(alice);
        uint256 id = seniorVault.requestRedeem(shares, alice, alice);
        vm.warp(block.timestamp + seniorVault.MAX_EPOCH_DURATION());
        vm.prank(keeper);
        seniorVault.closeEpoch();
        vm.warp(block.timestamp + seniorVault.FILL_GRACE());
        vm.prank(keeper);
        seniorVault.fulfill(id, type(uint128).max);
        uint256 claimable = seniorVault.claimableRedeemRequest(id, alice);
        vm.prank(alice);
        paid = seniorVault.redeem(claimable, alice, alice);
    }

    function _keeperExitsJunior(uint256 shares) internal returns (uint256 paid) {
        vm.prank(juniorLender);
        uint256 id = juniorVault.requestRedeem(shares, juniorLender, juniorLender);
        vm.warp(block.timestamp + juniorVault.MAX_EPOCH_DURATION());
        vm.prank(keeper);
        juniorVault.closeRedeemEpoch();
        vm.warp(block.timestamp + juniorVault.FILL_GRACE());
        vm.prank(keeper);
        juniorVault.fulfillRedeem(id, type(uint128).max);
        uint256 claimable = juniorVault.claimableRedeemRequest(id, juniorLender);
        if (claimable == 0) return 0;
        vm.prank(juniorLender);
        paid = juniorVault.redeem(claimable, juniorLender, juniorLender);
    }

    function test_repaidSeries_keeperOnly_settlesAndPaysBothExits() public {
        (uint256 seniorShares, uint256 juniorShares) = _fundedSeries();
        _keeperDrivesToSettlement();

        _repay(maturity, borrower, _debtOf(marketId, borrower));
        vm.warp(maturity + 1);
        vm.prank(keeper);
        series.collect(0);
        vm.prank(keeper);
        series.settle();
        assertEq(uint8(series.state()), uint8(SeriesState.SETTLED), "keeper settles once the market is resolved");
        assertGt(series.paidS(), 0, "senior was paid through the waterfall");
        assertEq(core.liveSeriesCount(), 0, "the settled series leaves the live set");

        uint256 seniorPaid = _keeperExitsSenior(seniorShares / 2);
        assertGt(seniorPaid, 0, "a keeper-only senior exit pays out");

        uint256 juniorPaid = _keeperExitsJunior(juniorShares / 10);
        assertGt(juniorPaid, 0, "a keeper-only junior exit pays out");
    }

    function test_settledSeries_leavesLiveSet_andKeepsSeniorDepositsOpen() public {
        _fundedSeries();
        _keeperDrivesToSettlement();
        _repay(maturity, borrower, _debtOf(marketId, borrower));
        vm.warp(maturity + 1);
        vm.prank(keeper);
        series.collect(0);
        vm.prank(keeper);
        series.settle();

        assertEq(core.liveSeriesCount(), 0, "a fully repaid, settled series must leave the live set");
        assertTrue(core.stressGateOpen(), "a clean settlement must not close the stress gate");
        assertGt(seniorVault.maxDeposit(alice), 0, "senior deposits stay open after a clean settlement");
    }

    function test_unrepaidSeries_keeperOnly_writesOffAndStillPaysSeniorExit() public {
        (uint256 seniorShares,) = _fundedSeries();
        _keeperDrivesToSettlement();

        vm.warp(maturity + series.D_WRITE_OFF());
        vm.prank(keeper);
        series.writeOff();
        assertEq(uint8(series.state()), uint8(SeriesState.SETTLED), "keeper writes off after the delay");
        assertTrue(series.writtenOff(0), "the unresolved market is written off");

        uint256 seniorPaid = _keeperExitsSenior(seniorShares / 10);
        assertGt(seniorPaid, 0, "senior exits still complete with only a keeper acting");
    }
}
