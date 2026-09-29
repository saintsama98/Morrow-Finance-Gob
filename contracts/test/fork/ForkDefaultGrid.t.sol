// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: stress plan V.2 (default share x recovery x timing, recovery lag), T1 (break-even per tranche) and
// V.3 (K1 correlated series, K3 maturity cluster) on live Base cbBTC and WETH markets.
// @author adiii.eth

pragma solidity 0.8.34;

import {console} from "forge-std/console.sol";
import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {StressBase} from "./StressBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesState} from "../../src/interfaces/iSeries.sol";

contract ForkDefaultGridTest is StressBase {
    uint256 internal constant N = 10;
    uint256 internal constant UNITS = 30_000e6;
    uint256 internal constant ISOLATED_RCF = 3_000_000_001;

    function _gridSetup() internal returns (creditSeries s) {
        _fundBooks(1_500_000e6, 500_000e6);
        mkts.push(_cbMarket(0.86e18, OCT_30, ISOLATED_RCF));
        bytes32 id;
        (s, id) = _openSingle(mkts[0], 400_000e6, 100_000e6);
        seriesSet.push(s);
        mktIds.push(id);
        uint256[] memory healths = new uint256[](N);
        for (uint256 k = 0; k < N; k++) {
            healths[k] = 70 + k;
        }
        _addBorrowers(s, 0, 0, UNITS, healths);
        _finalizeByKeeper(s);
        _captureBases();
    }

    function _injectLoss(uint256 defaulters, uint256 recoveryBps, bool postMaturity) internal returns (uint256 bad) {
        for (uint256 k = 0; k < defaulters; k++) {
            address b = borrowers[k];
            uint256 debt = midnight.debt(mktIds[0], b);
            if (debt == 0) continue;
            uint256 value = _collateralValue(mkts[0], midnight.collateral(mktIds[0], b, 0));
            uint256 target = debt * (recoveryBps == 0 ? 10 : recoveryBps) / 10_000;
            _setBtc(btcRatio * target / value);
            uint256 creditBefore = _creditView();
            uint256 posted = midnight.collateral(mktIds[0], b, 0);
            vm.prank(keeper);
            (bool ok,) = MIDNIGHT.call(
                abi.encodeCall(midnight.liquidate, (mkts[0], 0, posted, 0, b, postMaturity, keeper, address(0), ""))
            );
            require(ok, "injected liquidation failed");
            bad += creditBefore - _creditView();
            _setBtc(WAD);
        }
    }

    function _creditView() internal view returns (uint256) {
        (uint128 c,,) = midnight.updatePositionView(mkts[0], mktIds[0], address(seriesSet[0]));
        return c;
    }

    function _finishSeries(creditSeries s, bool postMaturityDone) internal {
        if (!postMaturityDone) {
            vm.warp(s.T());
            vm.prank(keeper);
            s.startSettlement();
        }
        for (uint256 k = 0; k < borrowers.length; k++) {
            _repayAll(mkts[0], mktIds[0], borrowers[k]);
        }
        vm.warp(s.T() + 1);
        _collectAll(s);
        vm.prank(keeper);
        s.settle();
        _checkStructure();
    }

    function _line(string memory tag, uint256 defaulters, uint256 recoveryBps, uint256 bad, creditSeries s)
        internal
        view
    {
        console.log(
            string.concat(
                tag,
                " | defaulted ",
                vm.toString(defaulters * 10),
                "% | recovery ",
                vm.toString(recoveryBps / 100),
                "% | realized loss ",
                vm.toString(bad / 1e6),
                " | senior ",
                vm.toString(s.paidS() / 1e6),
                "/",
                vm.toString(s.seniorClaim() / 1e6),
                " | junior ",
                vm.toString(s.paidJ() / 1e6),
                "/",
                vm.toString(s.juniorDeployed() / 1e6)
            )
        );
    }

    function test_G1_defaultShareByRecovery_midTerm() public {
        vm.pauseGasMetering();
        creditSeries s = _gridSetup();
        uint256 snap = vm.snapshotState();
        uint256[6] memory shares = [uint256(0), 1, 3, 5, 8, 10];
        uint256[3] memory recoveries = [uint256(10_000), 5_000, 0];
        for (uint256 a = 0; a < shares.length; a++) {
            for (uint256 r = 0; r < recoveries.length; r++) {
                vm.revertToState(snap);
                vm.warp(block.timestamp + 14 days);
                uint256 bad = _injectLoss(shares[a], recoveries[r], false);
                _finishSeries(s, false);
                _line("G1 mid-term", shares[a], recoveries[r], bad, s);
                _assertSeniority();
                if (bad == 0) assertEq(s.paidS(), s.seniorClaim(), "no realized loss leaves senior whole");
            }
        }
    }

    function test_G2_timingOfLoss_halfDefault_zeroRecovery() public {
        vm.pauseGasMetering();
        creditSeries s = _gridSetup();
        uint256 snap = vm.snapshotState();
        string[4] memory tags = ["G2 early (day 1)", "G2 mid-term", "G2 one day before maturity", "G2 post-maturity"];
        for (uint256 t = 0; t < 4; t++) {
            vm.revertToState(snap);
            bool post = t == 3;
            if (t == 0) vm.warp(block.timestamp + 1 days);
            if (t == 1) vm.warp(block.timestamp + 14 days);
            if (t == 2) vm.warp(s.T() - 1 days);
            if (post) {
                vm.warp(s.T());
                vm.prank(keeper);
                s.startSettlement();
                vm.warp(s.T() + 1 hours);
            }
            uint256 bad = _injectLoss(5, 0, post);
            _finishSeries(s, post);
            _line(tags[t], 5, 0, bad, s);
            _assertSeniority();
        }
    }

    function test_T1_breakEven_juniorThenSenior() public {
        vm.pauseGasMetering();
        creditSeries s = _gridSetup();
        uint256 snap = vm.snapshotState();
        uint256 juniorFirstLoss;
        uint256 seniorFirstLoss;
        for (uint256 d = 1; d <= N; d++) {
            for (uint256 rec = 10_000; rec + 1 > 0 && rec <= 10_000; rec -= 1_000) {
                vm.revertToState(snap);
                vm.warp(block.timestamp + 14 days);
                uint256 bad = _injectLoss(d, rec, false);
                _finishSeries(s, false);
                if (juniorFirstLoss == 0 && s.paidJ() < s.juniorDeployed()) juniorFirstLoss = bad;
                if (seniorFirstLoss == 0 && s.paidS() < s.seniorClaim()) seniorFirstLoss = bad;
                _assertSeniority();
                if (rec == 0) break;
            }
        }
        console.log("T1 deployed credit (face units):", s.totalFilled() / 1e6);
        console.log("T1 junior deployed / senior claim:", s.juniorDeployed() / 1e6, s.seniorClaim() / 1e6);
        console.log("T1 smallest realized loss where junior first loses principal:", juniorFirstLoss / 1e6);
        console.log("T1 smallest realized loss where senior first loses:", seniorFirstLoss / 1e6);
        assertGt(seniorFirstLoss, juniorFirstLoss, "senior only loses after junior has lost");
    }

    function test_G3_recoveryLag_afterWriteOff() public {
        vm.pauseGasMetering();
        creditSeries s = _gridSetup();
        uint256 snap = vm.snapshotState();
        uint256[3] memory lags = [uint256(1 days), 30 days, 180 days];
        for (uint256 x = 0; x < 3; x++) {
            vm.revertToState(snap);
            vm.warp(s.T());
            vm.prank(keeper);
            s.startSettlement();
            for (uint256 k = 3; k < N; k++) {
                _repayAll(mkts[0], mktIds[0], borrowers[k]);
            }
            vm.warp(s.T() + s.D_WRITE_OFF());
            _collectAll(s);
            vm.prank(keeper);
            s.writeOff();
            uint256 seniorAtWriteOff = s.paidS();
            uint256 juniorAtWriteOff = s.paidJ();
            assertFalse(core.stressGateOpen(), "G3: unresolved write-off closes senior deposits");

            vm.warp(block.timestamp + lags[x]);
            for (uint256 k = 0; k < 3; k++) {
                uint256 owed = midnight.debt(mktIds[0], borrowers[k]);
                if (owed == 0) continue;
                _fund(USDC, keeper, owed);
                Market memory m = mkts[0];
                address who = borrowers[k];
                vm.prank(keeper);
                midnight.liquidate(m, 0, 0, owed, who, true, keeper, address(0), "");
            }
            _collectAll(s);
            _checkStructure();
            console.log("G3 recovery lag (days):", lags[x] / 1 days);
            console.log("  senior at write-off -> after recovery:", seniorAtWriteOff / 1e6, s.paidS() / 1e6);
            console.log("  junior at write-off -> after recovery:", juniorAtWriteOff / 1e6, s.paidJ() / 1e6);
            assertGe(s.paidS(), seniorAtWriteOff, "G3: recovery never lowers senior");
            assertTrue(core.stressGateOpen(), "G3: gate reopens after full recovery");
        }
    }

    function test_G3b_recoveringListFull_gateBlindToWriteOff() public {
        vm.pauseGasMetering();
        creditSeries s = _gridSetup();
        vm.prank(CURATOR);
        core.proposePolicyChange(keccak256("maxRecovering"), 0);
        vm.warp(block.timestamp + core.CURATOR_TIMELOCK());
        core.executePolicyChange(keccak256("maxRecovering"));

        vm.warp(s.T());
        vm.prank(keeper);
        s.startSettlement();
        for (uint256 k = 3; k < N; k++) {
            _repayAll(mkts[0], mktIds[0], borrowers[k]);
        }
        vm.warp(s.T() + s.D_WRITE_OFF());
        _collectAll(s);
        vm.prank(keeper);
        s.writeOff();
        console.log("G3b recovering series tracked:", core.recoveringSeriesCount());
        console.log("G3b stress gate open despite unresolved write-off:", core.stressGateOpen());
        assertEq(core.recoveringSeriesCount(), 0, "G3b: list full, the written-off series is not tracked");
        assertTrue(core.stressGateOpen(), "G3b: confirms gap G4, the gate cannot see an untracked write-off");
    }

    function _openAll(uint256 S, uint256 J) internal {
        uint256 n = mkts.length;
        for (uint256 r = 0; r < n; r++) {
            Market memory m = mkts[r];
            (creditSeries s, bytes32 id) = _openSingle(m, S, J);
            seriesSet.push(s);
            mktIds.push(id);
        }
    }

    function _finalizeAll() internal {
        uint256 n = seriesSet.length;
        for (uint256 r = 0; r < n; r++) {
            _finalizeByKeeper(seriesSet[r]);
        }
    }

    function test_K1_correlatedBtcLadder_threeSeriesHitTogether() public {
        vm.pauseGasMetering();
        _fundBooks(2_000_000e6, 700_000e6);
        uint256[3] memory mats = [OCT_30, NOV_27, DEC_25];
        uint256[] memory healths = new uint256[](4);
        healths[0] = 85;
        healths[1] = 92;
        healths[2] = 96;
        healths[3] = 99;
        for (uint256 r = 0; r < 3; r++) {
            mkts.push(_cbMarket(0.86e18, mats[r], 3_000_000_000));
        }
        _openAll(240_000e6, 60_000e6);
        for (uint256 r = 0; r < 3; r++) {
            _addBorrowers(seriesSet[r], r, 0, 40_000e6, healths);
        }
        _finalizeAll();
        _captureBases();
        _setLiquidator(Liquidator.Latency, 120 minutes);
        _replay("oct25_btc", "bear_eth", 3);
        _settleAll();
        _report("K1 Oct 2025 BTC shape at 3x depth hits the Oct/Nov/Dec cbBTC ladder together | L2 latency 120m");
        _assertSeniority();
    }

    function test_K3_maturityCluster_fourOct30Series_exitsQueued() public {
        vm.pauseGasMetering();
        _fundBooks(2_000_000e6, 600_000e6);
        mkts.push(_cbMarket(0.77e18, OCT_30, 2_000_000_000));
        mkts.push(_cbMarket(0.86e18, OCT_30, 3_000_000_000));
        mkts.push(_cbMarket(0.915e18, OCT_30, 5_000_000_000));
        mkts.push(_weMarket(0.77e18, OCT_30, 2_000_000_000));
        uint256[] memory healths = new uint256[](2);
        healths[0] = 80;
        healths[1] = 95;
        _openAll(100_000e6, 25_000e6);
        for (uint256 r = 0; r < 4; r++) {
            _addBorrowers(seriesSet[r], r, 0, 50_000e6, healths);
        }
        _finalizeAll();
        _captureBases();
        uint256 aliceShares = seniorVault.balanceOf(alice);
        vm.prank(alice);
        uint256 exitId = seniorVault.requestRedeem(aliceShares * 3 / 10, alice, alice);
        vm.prank(CURATOR);
        seniorVault.closeEpoch();
        uint256 queued = seniorVault.queuedExitAssets();

        _settleAll();
        vm.prank(keeper);
        seniorVault.fulfill(exitId, type(uint128).max);
        uint256 claimable = seniorVault.claimableRedeemRequest(exitId, alice);
        vm.prank(alice);
        uint256 paid = seniorVault.redeem(claimable, alice, alice);
        _checkStructure();
        console.log("K3 four series settle on Oct 30; senior exit queued before maturity (assets):", queued / 1e6);
        console.log("K3 exit paid after the cluster settles:", paid / 1e6);
        assertEq(core.liveSeriesCount(), 0, "K3: all four series leave the live set");
        assertGt(paid, 0, "K3: the queued exit is paid once the cluster settles");
        assertEq(seniorVault.queuedExitAssets(), 0, "K3: exit demand fully served");
        _assertSeniority();
    }
}
