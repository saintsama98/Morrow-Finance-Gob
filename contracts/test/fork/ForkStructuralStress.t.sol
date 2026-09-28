// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: fork groups D and E: a collateral de-peg the oracle cannot see, backstop on versus off across two
// live series, and donations during stress, all on live Base markets.
// @author adiii.eth

pragma solidity 0.8.34;

import {console} from "forge-std/console.sol";
import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {ForkBase, iChainlinkFeed} from "./ForkBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesState} from "../../src/interfaces/iSeries.sol";
import {iErc20Like} from "../../src/interfaces/iErc20Like.sol";

contract ForkStructuralStressTest is ForkBase {
    address internal bob = makeAddr("bob");
    address internal dora = makeAddr("dora");

    function _cb86(uint256 maturity) internal pure returns (Market memory) {
        return _cbMarket(0.86e18, maturity, 3_000_000_000);
    }

    function _defaultWithoutLiquidator(creditSeries s) internal {
        _toSettling(s);
        vm.warp(s.T() + s.D_WRITE_OFF());
        _collectAll(s);
        vm.prank(keeper);
        s.writeOff();
    }

    function test_cbbtcDepeg_oracleBlind_defaultWritesOff_juniorFirst_gateCloses() public {
        _fundBooks(1_000_000e6, 400_000e6);
        Market memory m = _cb86(OCT_30);
        (creditSeries s,) = _openSingle(m, 400_000e6, 100_000e6);
        _borrow(s, 0, m, 300_000e6, bob, 80);
        _finalizeByKeeper(s);
        uint256 juniorIdleBefore = core.idle(false);

        (, int256 btc,,,) = iChainlinkFeed(BTC_USD_FEED).latestRoundData();
        vm.mockCall(
            BTC_USD_FEED,
            abi.encodeWithSelector(iChainlinkFeed.latestRoundData.selector),
            abi.encode(uint80(1), btc, block.timestamp, block.timestamp, uint80(1))
        );
        assertTrue(midnight.isHealthy(m, s.marketIds()[0], bob), "the oracle still sees a healthy borrower");

        _defaultWithoutLiquidator(s);
        _checkStructure();

        assertTrue(s.writtenOff(0), "the market is written off");
        assertEq(s.paidJ(), 0, "junior is wiped before senior takes any loss");
        assertLt(s.paidS(), s.seniorClaim(), "a full default reaches senior once junior is gone");
        assertFalse(core.stressGateOpen(), "senior deposits close while the loss is unresolved");
        assertGt(core.backstopPaid(address(s)), 0, "the backstop draws on junior idle for senior");
        assertLt(core.idle(false), juniorIdleBefore, "the backstop is paid from junior idle");
        console.log("senior claim / paid:", s.seniorClaim(), s.paidS());
        console.log("backstop paid from junior idle:", core.backstopPaid(address(s)));
    }

    function _twoSeriesWithLossOnFirst(bool backstopOn)
        internal
        returns (creditSeries lossy, creditSeries healthy, uint256 healthySLeg, uint256 healthyJLeg)
    {
        _fundBooks(1_000_000e6, 400_000e6);
        if (!backstopOn) {
            vm.prank(CURATOR);
            core.disableBackstop();
        }
        Market memory oct = _cb86(OCT_30);
        Market memory nov = _cb86(NOV_27);
        (lossy,) = _openSingle(oct, 200_000e6, 50_000e6);
        (healthy,) = _openSingle(nov, 200_000e6, 50_000e6);
        _borrow(lossy, 0, oct, 150_000e6, bob, 80);
        _borrow(healthy, 0, nov, 150_000e6, dora, 80);
        _finalizeByKeeper(lossy);
        _finalizeByKeeper(healthy);
        (healthySLeg, healthyJLeg,) = healthy.navs();
        _defaultWithoutLiquidator(lossy);
        _checkStructure();
    }

    function test_backstopOff_otherSeriesLegsUntouched() public {
        (creditSeries lossy, creditSeries healthy, uint256 sLeg, uint256 jLeg) = _twoSeriesWithLossOnFirst(false);
        (uint256 sNow, uint256 jNow,) = healthy.navs();
        assertEq(core.backstopPaid(address(lossy)), 0, "no backstop when disabled");
        assertGe(sNow, sLeg, "the healthy series' senior leg is untouched");
        assertGe(jNow, jLeg, "the healthy series' junior leg is untouched");
    }

    function test_backstopOn_juniorIdleCoversSeniorShortfall() public {
        (creditSeries lossy, creditSeries healthy, uint256 sLeg, uint256 jLeg) = _twoSeriesWithLossOnFirst(true);
        (uint256 sNow, uint256 jNow,) = healthy.navs();
        assertGt(core.backstopPaid(address(lossy)), 0, "the backstop pays the senior shortfall");
        assertGe(sNow, sLeg, "the healthy series' legs are still untouched inside the series");
        assertGe(jNow, jLeg, "the backstop moves idle, not another series' legs");
    }

    function test_donationsDuringStress_neverMoveTheBooks() public {
        _fundBooks(1_000_000e6, 400_000e6);
        Market memory m = _cb86(OCT_30);
        (creditSeries s,) = _openSingle(m, 400_000e6, 100_000e6);
        _borrow(s, 0, m, 300_000e6, bob, 80);
        _finalizeByKeeper(s);
        uint256 seniorBefore = core.seniorAssets();
        uint256 juniorBefore = core.juniorAssets();
        uint256 seniorPps = seniorVault.pricePerShareWad();

        _fund(USDC, address(core), 50_000e6);
        _fund(USDC, address(seniorVault), 50_000e6);
        _fund(USDC, address(juniorVault), 50_000e6);

        assertEq(core.seniorAssets(), seniorBefore, "a donation to the core does not change the senior book");
        assertEq(core.juniorAssets(), juniorBefore, "a donation to the core does not change the junior book");
        assertEq(seniorVault.pricePerShareWad(), seniorPps, "vault donations cannot move the share price");

        _toSettling(s);
        _repayAll(m, s.marketIds()[0], bob);
        vm.warp(s.T() + 1);
        _collectAll(s);
        vm.prank(keeper);
        s.settle();
        assertEq(s.paidS(), s.seniorClaim(), "settlement unaffected by donations");
    }
}
