// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: stress plan V.1, V.3 (K2) and V.4 (H2): the real crash paths re-run under realistic liquidators
// (profit and capacity bound, latency 5/30/120 min, absent, cascade) on a live cbBTC + WETH basket.
// @author adiii.eth

pragma solidity 0.8.34;

import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {StressBase} from "./StressBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";

contract ForkCrashRealismTest is StressBase {
    function _basketSetup() internal {
        _fundBooks(1_500_000e6, 500_000e6);
        mkts.push(_cbMarket(0.86e18, OCT_30, 3_000_000_000));
        mkts.push(_weMarket(0.77e18, OCT_30, 2_000_000_000));
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
        _checkStructure();
    }

    function _run(string memory window, Liquidator mode, uint256 latency, uint256 depthFactor, string memory label)
        internal
    {
        vm.pauseGasMetering();
        _basketSetup();
        _setLiquidator(mode, latency);
        _replay(string.concat(window, "_btc"), string.concat(window, "_eth"), depthFactor);
        _settleAll();
        _report(label);
        _assertSeniority();
    }

    function test_H2_oct25_profitCapacity() public {
        _run("oct25", Liquidator.ProfitCapacity, 0, 1, "H2 oct25 real | L1 profit+capacity");
    }

    function test_H2_oct25_latency5m() public {
        _run("oct25", Liquidator.Latency, 5 minutes, 1, "H2 oct25 real | L2 latency 5m");
    }

    function test_H2_oct25_latency30m() public {
        _run("oct25", Liquidator.Latency, 30 minutes, 1, "H2 oct25 real | L2 latency 30m");
    }

    function test_H2_oct25_latency120m() public {
        _run("oct25", Liquidator.Latency, 120 minutes, 1, "H2 oct25 real | L2 latency 120m");
    }

    function test_H2_oct25_absent() public {
        _run("oct25", Liquidator.Absent, 0, 1, "H2 oct25 real | L3 absent until maturity auction");
    }

    function test_H2_oct25_cascade() public {
        _run("oct25", Liquidator.Cascade, 0, 1, "H2 oct25 real | L4 cascade, depth $50M (assumption)");
    }

    function test_H2_oct25_cascadeThinDepth() public {
        depthUsd = 1_000_000e6;
        _run("oct25", Liquidator.Cascade, 0, 1, "H2 oct25 real | L4 cascade, depth $1M (assumption)");
    }

    function test_H2_apr25_profitCapacity() public {
        _run("apr25", Liquidator.ProfitCapacity, 0, 1, "H2 apr25 real | L1 profit+capacity");
    }

    function test_H2_apr25_latency120m() public {
        _run("apr25", Liquidator.Latency, 120 minutes, 1, "H2 apr25 real | L2 latency 120m");
    }

    function test_H2_apr25_absent() public {
        _run("apr25", Liquidator.Absent, 0, 1, "H2 apr25 real | L3 absent");
    }

    function test_H2_feb25_profitCapacity() public {
        _run("feb25", Liquidator.ProfitCapacity, 0, 1, "H2 feb25 real | L1 profit+capacity");
    }

    function test_H2_feb25_latency120m() public {
        _run("feb25", Liquidator.Latency, 120 minutes, 1, "H2 feb25 real | L2 latency 120m");
    }

    function test_H2_feb25_absent() public {
        _run("feb25", Liquidator.Absent, 0, 1, "H2 feb25 real | L3 absent");
    }

    function test_H2_oct25x3_profitCapacity() public {
        _run("oct25", Liquidator.ProfitCapacity, 0, 3, "H2 oct25 at 3x depth (synthetic) | L1 profit+capacity");
    }

    function test_H2_oct25x3_latency120m() public {
        _run("oct25", Liquidator.Latency, 120 minutes, 3, "H2 oct25 at 3x depth (synthetic) | L2 latency 120m");
    }

    function test_H2_oct25x3_absent() public {
        _run("oct25", Liquidator.Absent, 0, 3, "H2 oct25 at 3x depth (synthetic) | L3 absent");
    }
}
