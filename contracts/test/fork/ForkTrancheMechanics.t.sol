// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: stress plan V.5 (T2 to T6 tranche mechanics under live loss), V.6 (O1 to O4 eligibility, oracle and
// de-peg) and the shared-market entanglement scenario, on live Base Midnight state.
// @author adiii.eth

pragma solidity 0.8.34;

import {console} from "forge-std/console.sol";
import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {StressBase} from "./StressBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {seriesFactory} from "../../src/series/seriesFactory.sol";
import {SeriesState} from "../../src/interfaces/iSeries.sol";
import {iErc20Like} from "../../src/interfaces/iErc20Like.sol";

contract ForkTrancheMechanicsTest is StressBase {
    uint256 internal constant ISOLATED_RCF = 3_000_000_001;
    address internal insider = makeAddr("insider");
    address internal newcomer = makeAddr("newcomer");

    function _isolatedSeries(uint256 seniorBook, uint256 juniorBook, uint256 S, uint256 J, uint256 n, uint256 units)
        internal
        returns (creditSeries s)
    {
        _fundBooks(seniorBook, juniorBook);
        mkts.push(_cbMarket(0.86e18, OCT_30, ISOLATED_RCF));
        bytes32 id;
        (s, id) = _openSingle(mkts[0], S, J);
        seriesSet.push(s);
        mktIds.push(id);
        uint256[] memory healths = new uint256[](n);
        for (uint256 k = 0; k < n; k++) {
            healths[k] = 70 + k;
        }
        _addBorrowers(s, 0, 0, units, healths);
        _finalizeByKeeper(s);
        _captureBases();
    }

    function _juniorJoin(address who, uint256 assets) internal returns (uint256 shares) {
        _fund(USDC, who, assets);
        vm.startPrank(who);
        iErc20Like(USDC).approve(address(juniorVault), assets);
        uint256 id = juniorVault.requestDeposit(assets, who, who);
        vm.stopPrank();
        vm.startPrank(CURATOR);
        juniorVault.closeDepositEpoch();
        juniorVault.fulfillDeposit(id, assets);
        vm.stopPrank();
        uint256 claimable = juniorVault.claimableDepositRequest(id, who);
        if (claimable == 0) return 0;
        vm.prank(who);
        (bool ok, bytes memory ret) = address(juniorVault).call(abi.encodeWithSignature("claimDeposit(uint256)", id));
        if (ok) shares = abi.decode(ret, (uint256));
    }

    function _crashAndRealize(uint256 defaulters, uint256 recoveryBps) internal returns (uint256 realized) {
        for (uint256 k = 0; k < defaulters; k++) {
            address b = borrowers[k];
            uint256 debt = midnight.debt(mktIds[0], b);
            uint256 value = _collateralValue(mkts[0], midnight.collateral(mktIds[0], b, 0));
            uint256 target = debt * (recoveryBps == 0 ? 10 : recoveryBps) / 10_000;
            _setBtc(btcRatio * target / value);
            (uint128 before,,) = midnight.updatePositionView(mkts[0], mktIds[0], address(seriesSet[0]));
            uint256 posted = midnight.collateral(mktIds[0], b, 0);
            Market memory m = mkts[0];
            vm.prank(keeper);
            midnight.liquidate(m, 0, posted, 0, b, false, keeper, address(0), "");
            (uint128 afterLoss,,) = midnight.updatePositionView(mkts[0], mktIds[0], address(seriesSet[0]));
            realized += before - afterLoss;
            _setBtc(WAD);
        }
    }

    function test_T3_juniorFrontRunsUnrealizedLoss_operatorFillVsPermissionlessFill() public {
        vm.pauseGasMetering();
        creditSeries s = _isolatedSeries(1_500_000e6, 500_000e6, 400_000e6, 100_000e6, 10, 30_000e6);
        uint256 insiderShares = _juniorJoin(insider, 100_000e6);
        uint256 snap = vm.snapshotState();

        _setBtc(0.5e18);
        (, uint256 navJBefore,) = s.navs();
        vm.prank(insider);
        uint256 rid = juniorVault.requestRedeem(insiderShares, insider, insider);
        vm.startPrank(CURATOR);
        juniorVault.closeRedeemEpoch();
        juniorVault.fulfillRedeem(rid, type(uint128).max);
        vm.stopPrank();
        uint256 claim = juniorVault.claimableRedeemRequest(rid, insider);
        vm.prank(insider);
        uint256 paidEarly = juniorVault.redeem(claim, insider, insider);
        _setBtc(WAD);
        uint256 realized = _crashAndRealize(5, 0);
        (, uint256 navJAfter,) = s.navs();
        uint256 juniorPpsAfter = juniorVault.pricePerShareWad();
        console.log(
            "T3 unrealized crash: series junior NAV before/after realization:", navJBefore / 1e6, navJAfter / 1e6
        );
        console.log("T3 insider exit with immediate operator fill, paid:", paidEarly / 1e6);
        console.log("T3 realized loss afterwards:", realized / 1e6);
        console.log("T3 remaining junior price per share (wad):", juniorPpsAfter);

        vm.revertToState(snap);
        _setBtc(0.5e18);
        vm.prank(insider);
        rid = juniorVault.requestRedeem(insiderShares, insider, insider);
        vm.warp(block.timestamp + juniorVault.MAX_EPOCH_DURATION());
        vm.prank(keeper);
        juniorVault.closeRedeemEpoch();
        _setBtc(WAD);
        _crashAndRealize(5, 0);
        vm.warp(block.timestamp + juniorVault.FILL_GRACE());
        vm.prank(keeper);
        juniorVault.fulfillRedeem(rid, type(uint128).max);
        claim = juniorVault.claimableRedeemRequest(rid, insider);
        uint256 paidLate;
        if (claim > 0) {
            vm.prank(insider);
            paidLate = juniorVault.redeem(claim, insider, insider);
        }
        console.log("T3 same exit filled permissionlessly after the loss is realized, paid:", paidLate / 1e6);
        _checkStructure();
        assertLt(paidLate, paidEarly, "T3: worse-of pricing protects when the fill follows realization");
    }

    function test_T2_T4_flowsAcrossLossStages_andRecoveryTimingGame() public {
        vm.pauseGasMetering();
        creditSeries s = _isolatedSeries(1_500_000e6, 500_000e6, 400_000e6, 100_000e6, 10, 30_000e6);
        string[4] memory stages = ["unrealized crash", "realized loss", "written off", "recovered"];
        for (uint256 st = 0; st < 4; st++) {
            if (st == 0) _setBtc(0.5e18);
            if (st == 1) {
                _setBtc(WAD);
                _crashAndRealize(3, 5_000);
            }
            if (st == 2) {
                vm.warp(s.T());
                vm.prank(keeper);
                s.startSettlement();
                for (uint256 k = 6; k < 10; k++) {
                    _repayAll(mkts[0], mktIds[0], borrowers[k]);
                }
                vm.warp(s.T() + s.D_WRITE_OFF());
                _collectAll(s);
                vm.prank(keeper);
                s.writeOff();
            }
            if (st == 3) {
                for (uint256 k = 3; k < 6; k++) {
                    uint256 owed = midnight.debt(mktIds[0], borrowers[k]);
                    if (owed == 0) continue;
                    Market memory m = mkts[0];
                    address who = borrowers[k];
                    _fund(USDC, keeper, owed);
                    vm.prank(keeper);
                    midnight.liquidate(m, 0, 0, owed, who, true, keeper, address(0), "");
                }
            }
            bool seniorDepositOk = _trySeniorDeposit(10_000e6);
            uint256 juniorShares = _juniorJoin(makeAddr(string.concat("jr", vm.toString(st))), 10_000e6);
            console.log(string.concat("T2 stage: ", stages[st]));
            console.log("  senior deposit accepted:", seniorDepositOk);
            console.log("  junior deposit shares minted:", juniorShares);
            console.log("  stress gate open:", core.stressGateOpen());
            if (st == 2) {
                uint256 before = core.juniorAssets();
                uint256 gameShares = _juniorJoin(newcomer, 50_000e6);
                uint256 supply = juniorVault.totalSupply();
                for (uint256 k = 3; k < 6; k++) {
                    uint256 owed = midnight.debt(mktIds[0], borrowers[k]);
                    if (owed == 0) continue;
                    Market memory m = mkts[0];
                    address who = borrowers[k];
                    _fund(USDC, keeper, owed);
                    vm.prank(keeper);
                    midnight.liquidate(m, 0, 0, owed, who, true, keeper, address(0), "");
                }
                _collectAll(s);
                uint256 worth = gameShares * core.juniorAssets() / supply;
                console.log("T4 junior book before recovery:", before / 1e6);
                console.log(
                    "T4 newcomer deposit 50,000 filled at the written-off price, worth after recovery:", worth / 1e6
                );
                st = 3;
            }
            _checkStructure();
        }
    }

    function _trySeniorDeposit(uint256 assets) internal returns (bool ok) {
        address who = makeAddr("lateSenior");
        _fund(USDC, who, assets);
        vm.startPrank(who);
        iErc20Like(USDC).approve(address(seniorVault), assets);
        (ok,) = address(seniorVault).call(abi.encodeWithSignature("deposit(uint256,address)", assets, who));
        vm.stopPrank();
    }

    function test_T5_juniorWipedToZero_newDepositAndExitBehaviour() public {
        vm.pauseGasMetering();
        vm.startPrank(CURATOR);
        core.proposePolicyChange(keccak256("minIdleJuniorWad"), 0);
        core.proposePolicyChange(keccak256("maxPerMaturityWindowWad"), 1e18);
        vm.stopPrank();
        vm.warp(block.timestamp + core.CURATOR_TIMELOCK());
        core.executePolicyChange(keccak256("minIdleJuniorWad"));
        core.executePolicyChange(keccak256("maxPerMaturityWindowWad"));

        creditSeries s = _isolatedSeries(400_000e6, 100_000e6, 380_000e6, 100_000e6, 12, 40_000e6);
        _crashAndRealize(12, 0);
        vm.warp(s.T());
        vm.prank(keeper);
        s.startSettlement();
        vm.warp(s.T() + s.D_WRITE_OFF());
        _collectAll(s);
        vm.prank(keeper);
        s.writeOff();
        _checkStructure();
        console.log("T5 junior book after full loss:", core.juniorAssets());
        console.log("T5 junior price per share (wad):", juniorVault.pricePerShareWad());
        console.log("T5 junior supply:", juniorVault.totalSupply());

        uint256 juniorBookBefore = core.juniorAssets();
        uint256 shares = _juniorJoin(newcomer, 10_000e6);
        console.log("T5 newcomer deposits 10,000 into a zero-priced junior; shares received:", shares);
        console.log("T5 junior book after the deposit:", core.juniorAssets() / 1e6);
        if (juniorBookBefore == 0) {
            assertEq(shares, 0, "T5 finding: a deposit filled at price 0 mints no shares");
        }

        uint256 oldShares = juniorVault.balanceOf(juniorLender);
        vm.prank(juniorLender);
        uint256 rid = juniorVault.requestRedeem(oldShares, juniorLender, juniorLender);
        vm.startPrank(CURATOR);
        juniorVault.closeRedeemEpoch();
        juniorVault.fulfillRedeem(rid, type(uint128).max);
        vm.stopPrank();
        uint256 claim = juniorVault.claimableRedeemRequest(rid, juniorLender);
        uint256 got;
        if (claim > 0) {
            vm.prank(juniorLender);
            got = juniorVault.redeem(claim, juniorLender, juniorLender);
        }
        console.log("T5 wiped junior holder exits after the newcomer's deposit, receives:", got / 1e6);
    }

    function test_T6_exitBatchSpanningWriteOff_paysPostLossPrice() public {
        vm.pauseGasMetering();
        creditSeries s = _isolatedSeries(1_500_000e6, 500_000e6, 400_000e6, 100_000e6, 10, 30_000e6);
        uint256 shares = seniorVault.balanceOf(alice) / 10;
        vm.prank(alice);
        uint256 rid = seniorVault.requestRedeem(shares, alice, alice);
        vm.prank(CURATOR);
        seniorVault.closeEpoch();
        (,,,, uint256 ppsClose,) = seniorVault.epochs(rid);

        _crashAndRealize(8, 0);
        vm.warp(s.T());
        vm.prank(keeper);
        s.startSettlement();
        vm.warp(s.T() + s.D_WRITE_OFF());
        _collectAll(s);
        vm.prank(keeper);
        s.writeOff();
        uint256 ppsNow = seniorVault.pricePerShareWad();

        vm.prank(CURATOR);
        seniorVault.fulfill(rid, type(uint128).max);
        uint256 claim = seniorVault.claimableRedeemRequest(rid, alice);
        vm.prank(alice);
        uint256 paid = seniorVault.redeem(claim, alice, alice);
        console.log("T6 senior pps at close / after write-off (wad):", ppsClose, ppsNow);
        console.log("T6 exit paid for shares requested before the loss:", paid / 1e6);
        assertLe(paid, shares * ppsNow / 1e18 + 1, "T6: an exit spanning the loss pays the post-loss price");
        _checkStructure();
    }

    function _loadMarkets(string memory name) internal view returns (bytes32[] memory ids, Market[] memory ms) {
        string memory file = string.concat(vm.projectRoot(), "/sim/vectors/markets_", name, ".hex");
        (ids, ms) = abi.decode(vm.parseBytes(vm.readFile(file)), (bytes32[], Market[]));
    }

    function test_O1_O2_O3_eligibilityAgainstEveryLiveMarket() public {
        (bytes32[] memory eIds, Market[] memory eMs) = _loadMarkets("eligible");
        uint256 passed;
        uint256 rejected;
        for (uint256 k = 0; k < eIds.length; k++) {
            assertEq(midnight.touchMarket(eMs[k]), eIds[k], "O3: API parameters reproduce the market id");
            bytes32[] memory one = new bytes32[](1);
            one[0] = eIds[k];
            try factory.checkEligibility(one) {
                passed++;
            } catch {
                rejected++;
                console.log("O3 eligible-by-LLTV but rejected (allowlist):", vm.toString(eIds[k]));
            }
        }
        console.log("O3 class E markets passing eligibility / rejected:", passed, rejected);

        (bytes32[] memory xIds, Market[] memory xMs) = _loadMarkets("above_ceiling");
        for (uint256 k = 0; k < xIds.length; k++) {
            midnight.touchMarket(xMs[k]);
            bytes32[] memory one = new bytes32[](1);
            one[0] = xIds[k];
            vm.expectPartialRevert(seriesFactory.IneligibleMarket.selector);
            factory.checkEligibility(one);
        }
        console.log("O2 above-ceiling markets rejected:", xIds.length);

        (bytes32[] memory mIds, Market[] memory mMs) = _loadMarkets("mismatched_oracle");
        for (uint256 k = 0; k < mIds.length; k++) {
            midnight.touchMarket(mMs[k]);
            bytes32[] memory one = new bytes32[](1);
            one[0] = mIds[k];
            vm.expectPartialRevert(seriesFactory.IneligibleMarket.selector);
            factory.checkEligibility(one);
        }
        console.log("O1 cbBTC market priced by a cbETH oracle rejected:", mIds.length);
    }

    function _depegRun(uint256 depegBps, Liquidator mode, string memory label) internal {
        creditSeries s = _isolatedSeries(1_500_000e6, 500_000e6, 400_000e6, 100_000e6, 10, 30_000e6);
        s;
        cbbtcDepegBps = depegBps;
        _setLiquidator(mode, 0);
        _settleAll();
        _report(label);
        _assertSeniority();
    }

    function test_O4_depeg40_profitLiquidator() public {
        vm.pauseGasMetering();
        _depegRun(4_000, Liquidator.ProfitCapacity, "O4 cbBTC de-peg 40%, oracle blind | L1 profit (real value)");
    }

    function test_O4_depeg40_absent() public {
        vm.pauseGasMetering();
        _depegRun(4_000, Liquidator.Absent, "O4 cbBTC de-peg 40%, oracle blind | L3 absent");
    }

    function test_O4_depeg40_naiveInstant() public {
        vm.pauseGasMetering();
        _depegRun(4_000, Liquidator.Instant, "O4 cbBTC de-peg 40%, oracle blind | naive keeper ignores real value");
    }

    function test_O4_depeg25_profitLiquidator() public {
        vm.pauseGasMetering();
        _depegRun(2_500, Liquidator.ProfitCapacity, "O4 cbBTC de-peg 25%, oracle blind | L1 profit (real value)");
    }

    function test_S1_sharedRealMarket_lossSocializationAndFirstComeWithdrawals() public {
        vm.pauseGasMetering();
        _fundBooks(1_500_000e6, 500_000e6);
        mkts.push(_cbMarket(0.86e18, OCT_30, 3_000_000_000));
        (creditSeries s, bytes32 id) = _openSingle(mkts[0], 400_000e6, 100_000e6);
        seriesSet.push(s);
        mktIds.push(id);
        uint256[] memory healths = new uint256[](10);
        for (uint256 k = 0; k < 10; k++) {
            healths[k] = 70 + k;
        }
        _addBorrowers(s, 0, 0, 30_000e6, healths);
        _finalizeByKeeper(s);
        _captureBases();
        uint256 outsideUnits = midnight.totalUnits(id) - midnight.credit(id, address(s));
        uint256 withdrawableBefore = midnight.withdrawable(id);

        uint256 debtDefaulted;
        for (uint256 k = 0; k < 5; k++) {
            debtDefaulted += midnight.debt(id, borrowers[k]);
        }
        uint256 seriesLoss = _crashAndRealize(5, 0);
        console.log("S1 outside credit in the real market (units):", outsideUnits / 1e6);
        console.log("S1 Morrow borrowers' defaulted debt:", debtDefaulted / 1e6);
        console.log("S1 loss taken by the Morrow series:", seriesLoss / 1e6);
        console.log(
            "S1 share of Morrow's bad debt absorbed by outside lenders (bps):",
            10_000 - seriesLoss * 10_000 / debtDefaulted
        );
        console.log("S1 withdrawable cash already in the market before Morrow's activity:", withdrawableBefore / 1e6);

        vm.warp(s.T());
        vm.prank(keeper);
        s.startSettlement();
        for (uint256 k = 5; k < 10; k++) {
            _repayAll(mkts[0], id, borrowers[k]);
        }
        vm.warp(s.T() + s.D_WRITE_OFF());
        _collectAll(s);
        console.log("S1 market resolved for the series after repayments:", s.resolved(0));
        vm.prank(keeper);
        if (s.resolved(0)) s.settle();
        else s.writeOff();
        console.log("S1 senior claim / paid:", s.seniorClaim() / 1e6, s.paidS() / 1e6);
        console.log("S1 junior deployed / paid:", s.juniorDeployed() / 1e6, s.paidJ() / 1e6);
        (uint128 leftCredit,,) = midnight.updatePositionView(mkts[0], id, address(s));
        console.log(
            "S1 series credit still stuck in the market waiting on outside borrowers:", uint256(leftCredit) / 1e6
        );
        _checkStructure();
    }
}
