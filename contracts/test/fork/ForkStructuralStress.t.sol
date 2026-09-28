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

    function test_D1_cbbtcDepeg_oracleBlind_defaultWritesOff_juniorFirst_gateCloses() public {
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
        assertTrue(midnight.isHealthy(m, s.marketIds()[0], bob), "D1: the oracle still sees a healthy borrower");

        _defaultWithoutLiquidator(s);
        _checkStructure();

        assertTrue(s.writtenOff(0), "D1: the market is written off");
        assertEq(s.paidJ(), 0, "D1: junior is wiped before senior takes any loss");
        assertLt(s.paidS(), s.seniorClaim(), "D1: a full default reaches senior once junior is gone");
        assertFalse(core.stressGateOpen(), "D1: senior deposits close while the loss is unresolved");
        assertGt(core.backstopPaid(address(s)), 0, "D1: the backstop draws on junior idle for senior");
        assertLt(core.idle(false), juniorIdleBefore, "D1: the backstop is paid from junior idle");
        console.log("D1 senior claim / paid:", s.seniorClaim(), s.paidS());
        console.log("D1 backstop paid from junior idle:", core.backstopPaid(address(s)));
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

    function test_D2a_backstopOff_otherSeriesLegsUntouched() public {
        (creditSeries lossy, creditSeries healthy, uint256 sLeg, uint256 jLeg) = _twoSeriesWithLossOnFirst(false);
        (uint256 sNow, uint256 jNow,) = healthy.navs();
        assertEq(core.backstopPaid(address(lossy)), 0, "D2a: no backstop when disabled");
        assertGe(sNow, sLeg, "D2a: the healthy series' senior leg is untouched (I25)");
        assertGe(jNow, jLeg, "D2a: the healthy series' junior leg is untouched (I25)");
    }

    function test_D2b_backstopOn_juniorIdleCoversSeniorShortfall() public {
        (creditSeries lossy, creditSeries healthy, uint256 sLeg, uint256 jLeg) = _twoSeriesWithLossOnFirst(true);
        (uint256 sNow, uint256 jNow,) = healthy.navs();
        assertGt(core.backstopPaid(address(lossy)), 0, "D2b: the backstop pays the senior shortfall");
        assertGe(sNow, sLeg, "D2b: the healthy series' legs are still untouched inside the series");
        assertGe(jNow, jLeg, "D2b: the backstop moves idle, not another series' legs");
    }

    function test_E1_donationsDuringStress_neverMoveTheBooks() public {
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

        assertEq(core.seniorAssets(), seniorBefore, "E1: a donation to the core does not change the senior book");
        assertEq(core.juniorAssets(), juniorBefore, "E1: a donation to the core does not change the junior book");
        assertEq(seniorVault.pricePerShareWad(), seniorPps, "E1: vault donations cannot move the share price");

        _toSettling(s);
        _repayAll(m, s.marketIds()[0], bob);
        vm.warp(s.T() + 1);
        _collectAll(s);
        vm.prank(keeper);
        s.settle();
        assertEq(s.paidS(), s.seniorClaim(), "E1: settlement unaffected by donations");
    }
}
