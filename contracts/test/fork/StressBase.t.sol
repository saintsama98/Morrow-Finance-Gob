// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: stress harness on the Base fork: liquidator models (instant, profit and capacity bound, latency,
// absent, cascade), borrower populations, deterministic loss injection and per-step structural checks.
// @author adiii.eth

pragma solidity 0.8.34;

import {console} from "forge-std/console.sol";
import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {ORACLE_PRICE_SCALE} from "@morpho-org/midnight/src/libraries/ConstantsLib.sol";
import {ForkBase, iChainlinkFeed, iPriceOracle} from "./ForkBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesState} from "../../src/interfaces/iSeries.sol";
import {iErc20Like} from "../../src/interfaces/iErc20Like.sol";

abstract contract StressBase is ForkBase {
    enum Liquidator {
        Instant,
        ProfitCapacity,
        Latency,
        Absent,
        Cascade
    }

    struct Path {
        uint256[] elapsed;
        uint256[] ratio;
    }

    Liquidator internal liqMode;
    uint256 internal liqLatency;
    uint256 internal liqCapacity = 2;
    uint256 internal depthUsd = 50_000_000e6;
    uint256 internal lastLiqAt;

    creditSeries[] internal seriesSet;
    Market[] internal mkts;
    bytes32[] internal mktIds;
    address[] internal borrowers;
    uint256[] internal borrowerMkt;

    int256 internal btcBase;
    int256 internal ethBase;
    uint256 internal btcOverlay = WAD;
    uint256 internal ethOverlay = WAD;
    uint256 internal btcRatio = WAD;
    uint256 internal ethRatio = WAD;
    uint80 internal roundCounter = 1;

    uint256 internal liquidations;
    uint256 internal unprofitableSkips;
    uint256 internal navSDropsWithJuniorLeft;
    mapping(address => uint256) internal lastNavS;

    function _setLiquidator(Liquidator mode, uint256 latency) internal {
        liqMode = mode;
        liqLatency = latency;
    }

    function _captureBases() internal {
        (, btcBase,,,) = iChainlinkFeed(BTC_USD_FEED).latestRoundData();
        (, ethBase,,,) = iChainlinkFeed(ETH_USD_FEED).latestRoundData();
        _fund(USDC, keeper, 20_000_000e6);
        vm.prank(keeper);
        iErc20Like(USDC).approve(MIDNIGHT, type(uint256).max);
    }

    function _pushFeed(address feed, int256 base, uint256 ratio, uint256 overlay) internal {
        int256 answer = base * int256(ratio * overlay / WAD) / int256(WAD);
        if (answer <= 0) answer = 1;
        roundCounter++;
        vm.mockCall(
            feed,
            abi.encodeWithSelector(iChainlinkFeed.latestRoundData.selector),
            abi.encode(roundCounter, answer, block.timestamp, block.timestamp, roundCounter)
        );
    }

    function _setBtc(uint256 ratio) internal {
        btcRatio = ratio;
        _pushFeed(BTC_USD_FEED, btcBase, btcRatio, btcOverlay);
    }

    function _setEth(uint256 ratio) internal {
        ethRatio = ratio;
        _pushFeed(ETH_USD_FEED, ethBase, ethRatio, ethOverlay);
    }

    function _addBorrowers(creditSeries s, uint256 mi, uint256 i, uint256 units, uint256[] memory healths) internal {
        for (uint256 h = 0; h < healths.length; h++) {
            address b = makeAddr(
                string.concat("b-", vm.toString(address(s)), "-", vm.toString(i), "-", vm.toString(healths[h]))
            );
            _borrow(s, i, mkts[mi], units, b, healths[h]);
            borrowers.push(b);
            borrowerMkt.push(mi);
        }
    }

    uint256 internal cbbtcDepegBps;

    function _collateralValue(Market memory m, uint256 amount) internal view returns (uint256) {
        return amount * iPriceOracle(m.collateralParams[0].oracle).price() / ORACLE_PRICE_SCALE;
    }

    function _realValue(Market memory m, uint256 amount) internal view returns (uint256 v) {
        v = _collateralValue(m, amount);
        if (m.collateralParams[0].token == CBBTC && cbbtcDepegBps > 0) v = v * (10_000 - cbbtcDepegBps) / 10_000;
    }

    function _tryLiquidate(uint256 k) internal returns (bool ok) {
        Market memory m = mkts[borrowerMkt[k]];
        bytes32 id = mktIds[borrowerMkt[k]];
        address b = borrowers[k];
        address token = m.collateralParams[0].token;
        uint256 usdcBefore = iErc20Like(USDC).balanceOf(keeper);
        uint256 collBefore = iErc20Like(token).balanceOf(keeper);
        uint256 snap = vm.snapshotState();

        uint256 posted = midnight.collateral(id, b, 0);
        vm.prank(keeper);
        (ok,) = MIDNIGHT.call(abi.encodeCall(midnight.liquidate, (m, 0, posted, 0, b, false, keeper, address(0), "")));
        if (!ok) {
            vm.prank(keeper);
            (ok,) = MIDNIGHT.call(
                abi.encodeCall(
                    midnight.liquidate, (m, 0, 0, midnight.debt(id, b) / 2, b, false, keeper, address(0), "")
                )
            );
        }
        if (!ok) {
            vm.deleteStateSnapshot(snap);
            return false;
        }

        if (liqMode == Liquidator.ProfitCapacity || liqMode == Liquidator.Cascade) {
            uint256 paid = usdcBefore - iErc20Like(USDC).balanceOf(keeper);
            uint256 seizedValue = _realValue(m, iErc20Like(token).balanceOf(keeper) - collBefore);
            uint256 slip = seizedValue * 1e4 / depthUsd;
            uint256 realized = seizedValue * (1e4 - (slip > 5000 ? 5000 : slip)) / 1e4;
            if (realized < paid) {
                vm.revertToState(snap);
                vm.deleteStateSnapshot(snap);
                unprofitableSkips++;
                return false;
            }
            if (liqMode == Liquidator.Cascade) {
                uint256 impact = seizedValue * WAD / depthUsd;
                if (token == CBBTC) {
                    btcOverlay = btcOverlay * (WAD - (impact > WAD / 2 ? WAD / 2 : impact)) / WAD;
                    _pushFeed(BTC_USD_FEED, btcBase, btcRatio, btcOverlay);
                } else {
                    ethOverlay = ethOverlay * (WAD - (impact > WAD / 2 ? WAD / 2 : impact)) / WAD;
                    _pushFeed(ETH_USD_FEED, ethBase, ethRatio, ethOverlay);
                }
            }
        }
        vm.deleteStateSnapshot(snap);
        liquidations++;
    }

    function _keeperStep() internal {
        if (liqMode == Liquidator.Absent) return;
        if (liqMode == Liquidator.Latency && block.timestamp < lastLiqAt + liqLatency) return;
        lastLiqAt = block.timestamp;
        uint256 done;
        for (uint256 k = 0; k < borrowers.length; k++) {
            Market memory m = mkts[borrowerMkt[k]];
            bytes32 id = mktIds[borrowerMkt[k]];
            if (midnight.debt(id, borrowers[k]) == 0 || midnight.isHealthy(m, id, borrowers[k])) continue;
            if (liqMode == Liquidator.ProfitCapacity && done >= liqCapacity) break;
            if (_tryLiquidate(k)) done++;
        }
    }

    function _trackJuniorFirst() internal {
        for (uint256 k = 0; k < seriesSet.length; k++) {
            creditSeries s = seriesSet[k];
            if (uint8(s.state()) == uint8(SeriesState.SETTLED) || uint8(s.state()) == uint8(SeriesState.CANCELED)) {
                continue;
            }
            (uint256 navS, uint256 navJ,) = s.navs();
            if (navS < lastNavS[address(s)] && navJ > 0) navSDropsWithJuniorLeft++;
            lastNavS[address(s)] = navS;
        }
    }

    function _loadPath(string memory name) internal view returns (Path memory p) {
        string memory file = string.concat(vm.projectRoot(), "/sim/vectors/crash_", name, ".hex");
        (p.elapsed, p.ratio) = abi.decode(vm.parseBytes(vm.readFile(file)), (uint256[], uint256[]));
    }

    function _replay(string memory btcName, string memory ethName, uint256 depthFactor) internal {
        Path memory btc = _loadPath(btcName);
        Path memory eth = _loadPath(ethName);
        uint256 t0 = block.timestamp;
        uint256 i;
        uint256 j;
        uint256 steps;
        while (i < btc.elapsed.length || j < eth.elapsed.length) {
            bool takeBtc = j >= eth.elapsed.length || (i < btc.elapsed.length && btc.elapsed[i] <= eth.elapsed[j]);
            if (takeBtc) {
                vm.warp(t0 + btc.elapsed[i]);
                _setBtc(_amplify(btc.ratio[i], depthFactor));
                i++;
            } else {
                vm.warp(t0 + eth.elapsed[j]);
                _setEth(_amplify(eth.ratio[j], depthFactor));
                j++;
            }
            _keeperStep();
            _trackJuniorFirst();
            if (++steps % 60 == 0) _checkStructure();
        }
        _checkStructure();
    }

    function _amplify(uint256 ratio, uint256 factor) internal pure returns (uint256) {
        if (ratio >= WAD || factor <= 1) return ratio;
        uint256 drop = (WAD - ratio) * factor;
        return drop >= WAD - 0.05e18 ? 0.05e18 : WAD - drop;
    }

    uint256 internal defaultsAtMaturity;
    uint256 internal auctionLiquidations;

    function _settleAll() internal {
        uint256 latestT;
        for (uint256 k = 0; k < seriesSet.length; k++) {
            if (seriesSet[k].T() > latestT) latestT = seriesSet[k].T();
        }
        vm.warp(latestT);
        for (uint256 k = 0; k < seriesSet.length; k++) {
            if (uint8(seriesSet[k].state()) == uint8(SeriesState.LOCKED)) {
                vm.prank(keeper);
                seriesSet[k].startSettlement();
            }
        }
        for (uint256 k = 0; k < borrowers.length; k++) {
            Market memory m = mkts[borrowerMkt[k]];
            bytes32 id = mktIds[borrowerMkt[k]];
            uint256 debt = midnight.debt(id, borrowers[k]);
            if (debt == 0) continue;
            if (_realValue(m, midnight.collateral(id, borrowers[k], 0)) >= debt) {
                _repayAll(m, id, borrowers[k]);
            } else {
                defaultsAtMaturity++;
            }
        }
        vm.warp(latestT + 1 hours);
        for (uint256 k = 0; k < borrowers.length; k++) {
            Market memory m = mkts[borrowerMkt[k]];
            bytes32 id = mktIds[borrowerMkt[k]];
            if (midnight.debt(id, borrowers[k]) == 0) continue;
            if (_auction(m, id, borrowers[k])) auctionLiquidations++;
        }
        vm.warp(latestT + 7 days);
        for (uint256 k = 0; k < seriesSet.length; k++) {
            creditSeries s = seriesSet[k];
            if (uint8(s.state()) != uint8(SeriesState.SETTLING)) continue;
            _collectAll(s);
            bool all = true;
            for (uint256 x = 0; x < s.marketIds().length; x++) {
                if (!s.resolved(x)) all = false;
            }
            vm.prank(keeper);
            if (all) s.settle();
            else s.writeOff();
        }
        _checkStructure();
    }

    function _auction(Market memory m, bytes32 id, address b) internal returns (bool ok) {
        address token = m.collateralParams[0].token;
        uint256 usdcBefore = iErc20Like(USDC).balanceOf(keeper);
        uint256 collBefore = iErc20Like(token).balanceOf(keeper);
        uint256 snap = vm.snapshotState();
        uint256 posted = midnight.collateral(id, b, 0);
        vm.prank(keeper);
        (ok,) = MIDNIGHT.call(abi.encodeCall(midnight.liquidate, (m, 0, posted, 0, b, true, keeper, address(0), "")));
        if (!ok) {
            uint256 owed = midnight.debt(id, b);
            vm.prank(keeper);
            (ok,) = MIDNIGHT.call(abi.encodeCall(midnight.liquidate, (m, 0, 0, owed, b, true, keeper, address(0), "")));
        }
        if (!ok) {
            vm.deleteStateSnapshot(snap);
            return false;
        }
        if (liqMode == Liquidator.ProfitCapacity || liqMode == Liquidator.Cascade) {
            uint256 paid = usdcBefore - iErc20Like(USDC).balanceOf(keeper);
            uint256 seizedValue = _realValue(m, iErc20Like(token).balanceOf(keeper) - collBefore);
            uint256 slip = seizedValue * 1e4 / depthUsd;
            if (seizedValue * (1e4 - (slip > 5000 ? 5000 : slip)) / 1e4 < paid) {
                vm.revertToState(snap);
                vm.deleteStateSnapshot(snap);
                unprofitableSkips++;
                return false;
            }
        }
        vm.deleteStateSnapshot(snap);
    }

    function _report(string memory label) internal view {
        console.log(label);
        console.log("  crash-time liquidations / unprofitable skips:", liquidations, unprofitableSkips);
        console.log("  defaults at maturity / auction liquidations:", defaultsAtMaturity, auctionLiquidations);
        console.log("  senior NAV drops while junior > 0:", navSDropsWithJuniorLeft);
        for (uint256 k = 0; k < seriesSet.length; k++) {
            creditSeries s = seriesSet[k];
            console.log("  series", k);
            console.log("    senior claim / paid:", s.seniorClaim(), s.paidS());
            console.log("    junior deployed / paid:", s.juniorDeployed(), s.paidJ());
            console.log("    backstop from junior idle:", core.backstopPaid(address(s)));
        }
    }

    function _assertSeniority() internal view {
        for (uint256 k = 0; k < seriesSet.length; k++) {
            creditSeries s = seriesSet[k];
            if (uint8(s.state()) != uint8(SeriesState.SETTLED)) continue;
            uint256 p = _proceeds(s);
            uint256 claim = s.seniorClaim();
            if (!s.passThrough()) assertEq(s.paidS(), p < claim ? p : claim, "senior paid first from what came back");
            if (s.paidS() < claim) assertEq(s.paidJ(), 0, "junior receives nothing while senior is short");
        }
        assertEq(navSDropsWithJuniorLeft, 0, "senior NAV never falls while junior still has value");
    }
}
