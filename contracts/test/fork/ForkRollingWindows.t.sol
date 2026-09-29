// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: stress plan V.4 (H1): every rolling 30-day BTC and ETH window from 2024-04 to 2026-09 replayed onto a
// Dec 25 cbBTC + WETH basket under profit-bound and absent liquidators; distribution of tranche outcomes.
// @author adiii.eth

pragma solidity 0.8.34;

import {console} from "forge-std/console.sol";
import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {StressBase} from "./StressBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";

contract ForkRollingWindowsTest is StressBase {
    function _setupBasket() internal {
        _fundBooks(1_500_000e6, 500_000e6);
        mkts.push(_cbMarket(0.86e18, DEC_25, 3_000_000_001));
        mkts.push(_weMarket(0.77e18, DEC_25, 2_000_000_001));
        Market[] memory ms = new Market[](2);
        ms[0] = mkts[0];
        ms[1] = mkts[1];
        uint256[] memory caps = new uint256[](2);
        caps[0] = 250_000e6;
        caps[1] = 250_000e6;
        (creditSeries s, bytes32[] memory ids) = _openSeries(ms, caps, 400_000e6, 100_000e6);
        seriesSet.push(s);
        mktIds.push(ids[0]);
        mktIds.push(ids[1]);
        uint256[] memory healths = new uint256[](5);
        healths[0] = 80;
        healths[1] = 90;
        healths[2] = 95;
        healths[3] = 97;
        healths[4] = 99;
        _addBorrowers(s, 0, 0, 40_000e6, healths);
        _addBorrowers(s, 1, 1, 40_000e6, healths);
        _finalizeByKeeper(s);
        _captureBases();
    }

    function _runAll(Liquidator mode, string memory label) internal {
        vm.pauseGasMetering();
        _setupBasket();
        _setLiquidator(mode, 0);
        string memory file = string.concat(vm.projectRoot(), "/sim/vectors/rolling30_daily.hex");
        (uint256[] memory starts, uint256[31][] memory btc, uint256[31][] memory eth) =
            abi.decode(vm.parseBytes(vm.readFile(file)), (uint256[], uint256[31][], uint256[31][]));
        uint256 snap = vm.snapshotState();
        uint256 totalLiq;
        uint256 totalDefaults;
        uint256 totalAuctions;
        uint256 minEthRatio = WAD;
        uint256[5] memory st;
        uint256[] memory jLossBps = new uint256[](starts.length);
        for (uint256 w = 0; w < starts.length; w++) {
            vm.revertToState(snap);
            for (uint256 d = 0; d < 31; d++) {
                vm.warp(block.timestamp + 1 days);
                _setBtc(btc[w][d]);
                _setEth(eth[w][d]);
                _keeperStep();
                _trackJuniorFirst();
            }
            if (eth[w][30] < minEthRatio) minEthRatio = eth[w][30];
            _settleAll();
            totalLiq += liquidations;
            totalDefaults += defaultsAtMaturity;
            totalAuctions += auctionLiquidations;
            _assertSeniority();
            creditSeries s = seriesSet[0];
            uint256 jd = s.juniorDeployed();
            uint256 jLoss = s.paidJ() >= jd ? 0 : (jd - s.paidJ()) * 10_000 / jd;
            uint256 sLoss = s.paidS() >= s.seniorClaim() ? 0 : (s.seniorClaim() - s.paidS()) * 10_000 / s.seniorClaim();
            jLossBps[w] = jLoss;
            if (jLoss > 0) st[0]++;
            if (sLoss > 0) st[1]++;
            if (jLoss > st[2]) {
                st[2] = jLoss;
                st[4] = starts[w];
            }
            if (sLoss > st[3]) st[3] = sLoss;
        }
        console.log(label);
        console.log("  windows replayed:", starts.length);
        console.log("  windows with junior principal loss / senior loss:", st[0], st[1]);
        console.log("  worst junior loss (bps) / worst senior loss (bps):", st[2], st[3]);
        console.log("  worst junior window starts (unix):", st[4]);
        for (uint256 w = 0; w < starts.length; w++) {
            if (jLossBps[w] > 0) console.log("  window start / junior loss bps:", starts[w], jLossBps[w]);
        }
        console.log(
            "  crash-time liquidations / maturity defaults / auctions (all windows):",
            totalLiq,
            totalDefaults,
            totalAuctions
        );
        console.log("  lowest ETH window-end ratio (wad):", minEthRatio);
    }

    function _roundLevelJan26(Liquidator mode, uint256 latency, string memory label) internal {
        vm.pauseGasMetering();
        _setupBasket();
        _setLiquidator(mode, latency);
        _replay("jan26_btc", "jan26_eth", 1);
        _settleAll();
        _report(label);
        _assertSeniority();
    }

    function test_H1r_jan26_roundLevel_profitLiquidator() public {
        _roundLevelJan26(
            Liquidator.ProfitCapacity, 0, "H1r Jan 8 - Feb 7 2026, every Chainlink round | L1 profit+capacity"
        );
    }

    function test_H1r_jan26_roundLevel_latency120m() public {
        _roundLevelJan26(
            Liquidator.Latency, 120 minutes, "H1r Jan 8 - Feb 7 2026, every Chainlink round | L2 latency 120m"
        );
    }

    function test_H1r_jan26_roundLevel_absent() public {
        _roundLevelJan26(Liquidator.Absent, 0, "H1r Jan 8 - Feb 7 2026, every Chainlink round | L3 absent");
    }

    function test_H1_rollingWindows_profitLiquidator() public {
        _runAll(Liquidator.ProfitCapacity, "H1 124 rolling 30d windows, daily closes | L1 profit+capacity");
    }

    function test_H1_rollingWindows_absentLiquidator() public {
        _runAll(Liquidator.Absent, "H1 124 rolling 30d windows, daily closes | L3 absent until maturity auction");
    }
}
