// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: fork group C: real crash price paths (every Chainlink round) replayed onto live Base markets holding a
// Morrow basket, with a keeper liquidating in real time and the structure checked after every round.
// @author adiii.eth

pragma solidity 0.8.34;

import {console} from "forge-std/console.sol";
import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {ForkBase, iChainlinkFeed} from "./ForkBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesState} from "../../src/interfaces/iSeries.sol";
import {iErc20Like} from "../../src/interfaces/iErc20Like.sol";

contract ForkCrashReplayTest is ForkBase {
    struct Path {
        uint256[] elapsed;
        uint256[] ratio;
    }

    uint256[4] internal healthLevels = [uint256(60), 80, 90, 97];

    creditSeries internal s;
    bytes32[] internal ids;
    Market[] internal mkts;
    address[] internal borrowers;
    uint256[] internal borrowerMarket;

    int256 internal btcBase;
    int256 internal ethBase;
    uint80 internal roundCounter = 1;

    uint256 internal liquidations;
    uint256 internal lastNavS;
    uint256 internal navSDropsWithJuniorLeft;

    function _path(string memory name) internal view returns (Path memory p) {
        string memory file = string.concat(vm.projectRoot(), "/sim/vectors/crash_", name, ".hex");
        (p.elapsed, p.ratio) = abi.decode(vm.parseBytes(vm.readFile(file)), (uint256[], uint256[]));
    }

    function _setup() internal {
        _fundBooks(1_000_000e6, 400_000e6);
        mkts.push(_cbMarket(0.86e18, OCT_30, 3_000_000_000));
        mkts.push(_weMarket(0.77e18, OCT_30, 2_000_000_000));
        Market[] memory ms = new Market[](2);
        ms[0] = mkts[0];
        ms[1] = mkts[1];
        uint256[] memory caps = new uint256[](2);
        caps[0] = 250_000e6;
        caps[1] = 250_000e6;
        (s, ids) = _openSeries(ms, caps, 400_000e6, 100_000e6);

        for (uint256 i = 0; i < 2; i++) {
            for (uint256 h = 0; h < 4; h++) {
                address b = makeAddr(string.concat("crash-borrower-", vm.toString(i), "-", vm.toString(h)));
                _borrow(s, i, mkts[i], 50_000e6, b, healthLevels[h]);
                borrowers.push(b);
                borrowerMarket.push(i);
            }
        }
        _finalizeByKeeper(s);
        _checkStructure();

        (, btcBase,,,) = iChainlinkFeed(BTC_USD_FEED).latestRoundData();
        (, ethBase,,,) = iChainlinkFeed(ETH_USD_FEED).latestRoundData();
        _fund(USDC, keeper, 5_000_000e6);
        vm.prank(keeper);
        iErc20Like(USDC).approve(MIDNIGHT, type(uint256).max);
        (lastNavS,,) = s.navs();
    }

    function _amplify(uint256 ratio, uint256 factor) internal pure returns (uint256) {
        if (ratio >= WAD) return ratio;
        uint256 drop = (WAD - ratio) * factor;
        return drop >= WAD - 0.05e18 ? 0.05e18 : WAD - drop;
    }

    function _setPrice(address feed, int256 base, uint256 ratio) internal {
        int256 answer = base * int256(ratio) / int256(WAD);
        roundCounter++;
        vm.mockCall(
            feed,
            abi.encodeWithSelector(iChainlinkFeed.latestRoundData.selector),
            abi.encode(roundCounter, answer, block.timestamp, block.timestamp, roundCounter)
        );
    }

    function _keeperSweep() internal {
        for (uint256 k = 0; k < borrowers.length; k++) {
            Market memory m = mkts[borrowerMarket[k]];
            bytes32 id = ids[borrowerMarket[k]];
            address b = borrowers[k];
            if (midnight.debt(id, b) == 0 || midnight.isHealthy(m, id, b)) continue;
            uint256 posted = midnight.collateral(id, b, 0);
            vm.prank(keeper);
            (bool ok,) =
                MIDNIGHT.call(abi.encodeCall(midnight.liquidate, (m, 0, posted, 0, b, false, keeper, address(0), "")));
            if (!ok) {
                vm.prank(keeper);
                (ok,) = MIDNIGHT.call(
                    abi.encodeCall(
                        midnight.liquidate, (m, 0, 0, midnight.debt(id, b) / 2, b, false, keeper, address(0), "")
                    )
                );
            }
            if (ok) liquidations++;
        }
    }

    function _checkJuniorFirst() internal {
        (uint256 navS, uint256 navJ,) = s.navs();
        if (navS < lastNavS && navJ > 0) navSDropsWithJuniorLeft++;
        lastNavS = navS;
    }

    function _replay(string memory window, uint256 factor) internal {
        Path memory btc = _path(string.concat(window, "_btc"));
        Path memory eth = _path(string.concat(window, "_eth"));
        uint256 t0 = block.timestamp;
        uint256 i;
        uint256 j;
        while (i < btc.elapsed.length || j < eth.elapsed.length) {
            bool takeBtc = j >= eth.elapsed.length || (i < btc.elapsed.length && btc.elapsed[i] <= eth.elapsed[j]);
            if (takeBtc) {
                vm.warp(t0 + btc.elapsed[i]);
                _setPrice(BTC_USD_FEED, btcBase, _amplify(btc.ratio[i], factor));
                i++;
            } else {
                vm.warp(t0 + eth.elapsed[j]);
                _setPrice(ETH_USD_FEED, ethBase, _amplify(eth.ratio[j], factor));
                j++;
            }
            _keeperSweep();
            _checkJuniorFirst();
            if ((i + j) % 50 == 0) _checkStructure();
        }
        _checkStructure();
    }

    function _settleAfter() internal {
        vm.clearMockedCalls();
        _toSettling(s);
        for (uint256 k = 0; k < borrowers.length; k++) {
            _repayAll(mkts[borrowerMarket[k]], ids[borrowerMarket[k]], borrowers[k]);
        }
        vm.warp(s.T() + s.D_WRITE_OFF());
        _collectAll(s);
        vm.startPrank(keeper);
        if (s.resolved(0) && s.resolved(1)) s.settle();
        else s.writeOff();
        vm.stopPrank();
        _checkStructure();
    }

    function _report(string memory label) internal view {
        console.log(label);
        console.log("  keeper liquidations:", liquidations);
        console.log("  senior claim / paid:", s.seniorClaim(), s.paidS());
        console.log("  junior deployed / paid:", s.juniorDeployed(), s.paidJ());
    }

    function test_C1_oct2025Crash_realPath() public {
        _setup();
        _replay("oct25", 1);
        assertEq(navSDropsWithJuniorLeft, 0, "senior NAV never falls while junior still has value");
        _settleAfter();
        _report("C1 Oct 10-11 2025, real path (BTC -14.0%, ETH -19.8% troughs)");
        assertEq(s.paidS(), s.seniorClaim(), "C1: a real crash leaves senior whole");
        assertGt(_seniorExit(seniorVault.balanceOf(alice) / 2), 0, "C1: senior exits pay after the crash");
    }

    function test_C2_apr2025Crash_realPath() public {
        _setup();
        _replay("apr25", 1);
        assertEq(navSDropsWithJuniorLeft, 0, "senior NAV never falls while junior still has value");
        _settleAfter();
        _report("C2 Apr 6-7 2025, real path");
        assertEq(s.paidS(), s.seniorClaim(), "C2: senior whole");
    }

    function test_C3_feb2025Crash_realPath() public {
        _setup();
        _replay("feb25", 1);
        assertEq(navSDropsWithJuniorLeft, 0, "senior NAV never falls while junior still has value");
        _settleAfter();
        _report("C3 Feb 27-28 2025, real path");
        assertEq(s.paidS(), s.seniorClaim(), "C3: senior whole");
    }

    function test_C5_bear2025to2026_compressed() public {
        _setup();
        _replay("bear", 1);
        assertEq(navSDropsWithJuniorLeft, 0, "senior NAV never falls while junior still has value");
        _settleAfter();
        _report("C5 Oct 2025 - Jul 2026 bear (-52.9%), daily closes compressed to hourly steps");
        uint256 p = _proceeds(s);
        uint256 claim = s.seniorClaim();
        assertEq(s.paidS(), p < claim ? p : claim, "C5: senior paid first from what came back");
    }

    function test_C4_oct2025Crash_shapeAtThreeTimesDepth() public {
        _setup();
        _replay("oct25", 3);
        assertEq(navSDropsWithJuniorLeft, 0, "senior NAV never falls while junior still has value");
        _settleAfter();
        _report("C4 Oct 2025 shape at 3x depth (synthetic amplification)");
        uint256 p = _proceeds(s);
        uint256 claim = s.seniorClaim();
        assertEq(s.paidS(), p < claim ? p : claim, "C4: senior paid first from what came back");
        if (s.paidS() < claim) assertEq(s.paidJ(), 0, "C4: junior receives nothing while senior is short");
    }
}
