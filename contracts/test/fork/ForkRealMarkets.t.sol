// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: fork group A: every series type on real Base Midnight markets, structure checked at each step.
// @author adiii.eth

pragma solidity 0.8.34;

import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {ForkBase, iChainlinkFeed} from "./ForkBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesState} from "../../src/interfaces/iSeries.sol";
import {iErc20Like} from "../../src/interfaces/iErc20Like.sol";

contract ForkRealMarketsTest is ForkBase {
    bytes32 internal constant CB86_OCT_ID = 0x43d6120738c57b2bc5835901f8250fdf7fc8054efbb006c6ccba61ec898e5ed9;
    bytes32 internal constant CB86_NOV_ID = 0xe1878eec035b601f301484e63a49a428f8e008e2bf57a2fd88a3fc3a4c1b1acd;
    bytes32 internal constant CB86_DEC_ID = 0x9593c3a6dba45b6106af8dc8b45ba8c505d90d3d68a3d33f7c278dd921b637da;
    bytes32 internal constant CB77_OCT_ID = 0x7fc066f0fa3c730d17e6164b322504abb24547af6d8ecc226df92f1128ff4603;
    bytes32 internal constant CB915_OCT_ID = 0xb4407e9d6b5f8f8c298f045acf21b10ff500b1350f31961d35fa64aa6b865302;
    bytes32 internal constant WE77_OCT_ID = 0x63cfd76067b30fe5ce4a78edf0d0c78bff7b9418cf636b5a67d3577043b27b34;
    bytes32 internal constant WECB_OCT_ID = 0xb0e46ce2729eb0318e07ae32738b54e19e23553e3179a4a5783d69d42e8b0c89;

    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function _cb86(uint256 maturity) internal pure returns (Market memory) {
        return _cbMarket(0.86e18, maturity, 3_000_000_000);
    }

    function _we77Oct() internal pure returns (Market memory) {
        return _weMarket(0.77e18, OCT_30, 2_000_000_000);
    }

    function _settleClean(creditSeries s, Market[] memory ms, bytes32[] memory ids, address[] memory borrowers)
        internal
    {
        _toSettling(s);
        for (uint256 i = 0; i < ms.length; i++) {
            _repayAll(ms[i], ids[i], borrowers[i]);
        }
        vm.warp(s.T() + 1);
        _collectAll(s);
        vm.prank(keeper);
        s.settle();
    }

    function test_A0_marketIdsMatchTheLiveBooks() public {
        assertEq(midnight.touchMarket(_cb86(OCT_30)), CB86_OCT_ID, "cbBTC 0.86 Oct");
        assertEq(midnight.touchMarket(_cb86(NOV_27)), CB86_NOV_ID, "cbBTC 0.86 Nov");
        assertEq(midnight.touchMarket(_cb86(DEC_25)), CB86_DEC_ID, "cbBTC 0.86 Dec");
        assertEq(midnight.touchMarket(_cbMarket(0.77e18, OCT_30, 2_000_000_000)), CB77_OCT_ID, "cbBTC 0.77 Oct");
        assertEq(midnight.touchMarket(_cbMarket(0.915e18, OCT_30, 5_000_000_000)), CB915_OCT_ID, "cbBTC 0.915 Oct");
        assertEq(midnight.touchMarket(_we77Oct()), WE77_OCT_ID, "WETH 0.77 Oct");
        assertEq(midnight.touchMarket(_wecbMarket(OCT_30)), WECB_OCT_ID, "WETH+cbBTC 0.86 Oct");
    }

    function test_A1_standardSeries_realMarket_repaidAndBothExitsPaid() public {
        _fundBooks(1_000_000e6, 400_000e6);
        Market memory m = _cb86(OCT_30);
        (creditSeries s, bytes32 id) = _openSingle(m, 400_000e6, 100_000e6);
        _borrow(s, 0, m, 300_000e6, bob, 80);
        _checkStructure();
        _finalizeByKeeper(s);
        _checkStructure();

        Market[] memory ms = new Market[](1);
        ms[0] = m;
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        address[] memory bs = new address[](1);
        bs[0] = bob;
        _settleClean(s, ms, ids, bs);
        _checkStructure();

        assertEq(s.paidS(), s.seniorClaim(), "A1: senior fully paid");
        assertGt(s.paidJ(), s.juniorDeployed(), "A1: junior earns above principal");
        assertGt(_seniorExit(seniorVault.balanceOf(alice) / 2), 0, "A1: senior exit paid");
        assertGt(_juniorExit(juniorVault.balanceOf(juniorLender) / 4), 0, "A1: junior exit paid");
        _checkStructure();
    }

    function test_A2_ladder_OctThenNovThenDec() public {
        _fundBooks(1_000_000e6, 400_000e6);
        uint256[3] memory maturities = [OCT_30, NOV_27, DEC_25];
        uint256 lastPps = seniorVault.pricePerShareWad();
        for (uint256 r = 0; r < 3; r++) {
            Market memory m = _cb86(maturities[r]);
            (creditSeries s, bytes32 id) = _openSingle(m, 300_000e6, 75_000e6);
            assertEq(core.liveSeriesCount(), 1, "A2: exactly one live rung");
            address borrower = makeAddr(string.concat("rung", vm.toString(r)));
            _borrow(s, 0, m, 250_000e6, borrower, 80);
            _finalizeByKeeper(s);

            Market[] memory ms = new Market[](1);
            ms[0] = m;
            bytes32[] memory ids = new bytes32[](1);
            ids[0] = id;
            address[] memory bs = new address[](1);
            bs[0] = borrower;
            _settleClean(s, ms, ids, bs);
            _checkStructure();

            uint256 pps = seniorVault.pricePerShareWad();
            assertGt(pps, lastPps, "A2: senior price rises with each repaid rung");
            lastPps = pps;
            assertEq(core.liveSeriesCount(), 0, "A2: the settled rung left the live set");
        }
    }

    function _basket() internal pure returns (Market[] memory ms, uint256[] memory caps) {
        ms = new Market[](2);
        ms[0] = _cb86(OCT_30);
        ms[1] = _we77Oct();
        caps = new uint256[](2);
        caps[0] = 250_000e6;
        caps[1] = 250_000e6;
    }

    function test_A3_basket_twoCollateralFamilies_bothRepaid() public {
        _fundBooks(1_000_000e6, 400_000e6);
        (Market[] memory ms, uint256[] memory caps) = _basket();
        (creditSeries s, bytes32[] memory ids) = _openSeries(ms, caps, 400_000e6, 100_000e6);
        _borrow(s, 0, ms[0], 150_000e6, bob, 80);
        _borrow(s, 1, ms[1], 150_000e6, carol, 80);
        assertEq(s.unitsBought(0), 150_000e6, "A3: cbBTC leg filled");
        assertEq(s.unitsBought(1), 150_000e6, "A3: WETH leg filled");
        _finalizeByKeeper(s);
        _toSettling(s);

        _repayAll(ms[0], ids[0], bob);
        vm.warp(s.T() + 1);
        vm.prank(keeper);
        s.collect(0);
        vm.prank(keeper);
        vm.expectPartialRevert(bytes4(keccak256("NotResolved(uint256)")));
        s.settle();

        _repayAll(ms[1], ids[1], carol);
        vm.prank(keeper);
        s.collect(1);
        vm.prank(keeper);
        s.settle();
        _checkStructure();
        assertEq(s.paidS(), s.seniorClaim(), "A3: senior whole across the basket");
    }

    creditSeries internal pdSeries;
    bytes32[] internal pdIds;

    function _partialDefault() internal {
        _fundBooks(1_000_000e6, 400_000e6);
        (Market[] memory ms, uint256[] memory caps) = _basket();
        (pdSeries, pdIds) = _openSeries(ms, caps, 400_000e6, 100_000e6);
        _borrow(pdSeries, 0, ms[0], 150_000e6, bob, 80);
        _borrow(pdSeries, 1, ms[1], 150_000e6, carol, 80);
        _finalizeByKeeper(pdSeries);
        _toSettling(pdSeries);
        _repayAll(ms[0], pdIds[0], bob);
        vm.warp(pdSeries.T() + pdSeries.D_WRITE_OFF());
        vm.prank(keeper);
        pdSeries.collect(0);
        vm.prank(keeper);
        pdSeries.writeOff();
    }

    function test_A4_basket_oneMarketDefaults_writeOffRoutesLossJuniorFirst() public {
        _partialDefault();
        creditSeries s = pdSeries;
        _checkStructure();
        assertFalse(s.writtenOff(0), "A4: repaid market is not written off");
        assertTrue(s.writtenOff(1), "A4: defaulted market is written off");
        uint256 p = _proceeds(s);
        assertEq(s.paidJ(), p > s.seniorClaim() ? s.paidJ() : 0, "A4: junior gets nothing until senior is whole");
        assertEq(core.recoveringSeriesCount(), 1, "A4: series tracked as recovering");
        assertFalse(core.stressGateOpen(), "A4: unresolved write-off closes senior deposits");
    }

    function test_A5_recoveryAfterWriteOff_rerunsWaterfallAndReopensGate() public {
        _partialDefault();
        creditSeries s = pdSeries;
        uint256 seniorBefore = s.paidS();
        uint256 juniorBefore = s.paidJ();

        _liquidateOverdue(_we77Oct(), pdIds[1], carol, 0);
        vm.prank(keeper);
        s.collect(1);
        _checkStructure();

        assertTrue(s.resolved(1), "A5: recovered market resolves");
        assertGe(s.paidS(), seniorBefore, "A5: senior payout never decreases");
        assertGe(s.paidJ(), juniorBefore, "A5: junior payout never decreases");
        assertEq(s.paidS(), s.seniorClaim(), "A5: a full recovery restores senior");
        assertTrue(core.stressGateOpen(), "A5: the gate reopens once the loss is recovered");
    }

    function test_A6_twoCollateralMarket_borrowerPostsBoth_overdueLiquidationOnOne() public {
        _fundBooks(1_000_000e6, 400_000e6);
        Market memory m = _wecbMarket(OCT_30);
        (creditSeries s, bytes32 id) = _openSingle(m, 400_000e6, 100_000e6);
        uint256 units = 200_000e6;
        _postCollateral(bob, m, 0, _collateralFor(m, 0, units / 2, 70));
        _postCollateral(bob, m, 1, _collateralFor(m, 1, units / 2, 70));
        _take(s, 0, m, units, bob);
        assertEq(midnight.collateralBitmap(id, bob), 3, "A6: both collaterals active");
        _finalizeByKeeper(s);
        _toSettling(s);

        vm.warp(s.T() + 1 hours);
        uint256 debt = midnight.debt(id, bob);
        _fund(USDC, keeper, debt);
        vm.startPrank(keeper);
        iErc20Like(USDC).approve(MIDNIGHT, debt);
        midnight.liquidate(m, 1, 0, debt / 2, bob, true, keeper, address(0), "");
        midnight.liquidate(m, 0, 0, midnight.debt(id, bob), bob, true, keeper, address(0), "");
        vm.stopPrank();
        assertEq(midnight.debt(id, bob), 0, "A6: overdue auctions across both legs clear the debt");
        assertGt(iErc20Like(CBBTC).balanceOf(keeper), 0, "A6: cbBTC leg seized");
        assertGt(iErc20Like(WETH).balanceOf(keeper), 0, "A6: WETH leg seized");
        _collectAll(s);
        vm.prank(keeper);
        s.settle();
        _checkStructure();
        assertEq(s.paidS(), s.seniorClaim(), "A6: senior whole");
    }

    function test_A7_lltvBandEdges_0_77_and_0_915() public {
        _fundBooks(1_000_000e6, 400_000e6);
        Market memory low = _cbMarket(0.77e18, OCT_30, 2_000_000_000);
        Market memory high = _cbMarket(0.915e18, OCT_30, 5_000_000_000);
        Market[] memory ms = new Market[](2);
        ms[0] = low;
        ms[1] = high;
        uint256[] memory caps = new uint256[](2);
        caps[0] = 150_000e6;
        caps[1] = 150_000e6;
        (creditSeries s, bytes32[] memory ids) = _openSeries(ms, caps, 240_000e6, 60_000e6);
        _borrow(s, 0, low, 100_000e6, bob, 90);
        _borrow(s, 1, high, 100_000e6, carol, 99);
        assertTrue(midnight.isHealthy(high, ids[1], carol), "A7: 0.915 borrower just inside health");
        _finalizeByKeeper(s);
        _toSettling(s);
        _repayAll(low, ids[0], bob);
        _repayAll(high, ids[1], carol);
        vm.warp(s.T() + 1);
        _collectAll(s);
        vm.prank(keeper);
        s.settle();
        _checkStructure();
    }

    function test_A8_passThrough_belowKMin_paysProRata() public {
        _fundBooks(1_000_000e6, 400_000e6);
        Market memory m = _cb86(OCT_30);
        (creditSeries s, bytes32 id) = _openSingle(m, 400_000e6, 100_000e6);
        _borrow(s, 0, m, 30_000e6, bob, 80);
        _finalizeByKeeper(s);
        assertTrue(s.passThrough(), "A8: below kMin runs pass-through");
        _toSettling(s);
        _repayAll(m, id, bob);
        vm.warp(s.T() + 1);
        _collectAll(s);
        vm.prank(keeper);
        s.settle();
        _checkStructure();
        uint256 p = _proceeds(s);
        assertEq(s.paidS(), p * s.seniorDeployed() / s.totalFilled(), "A8: senior share is pro rata");
        assertEq(s.feeAccounted(), 0, "A8: no fee in pass-through");
    }

    function test_A9_canceled_nothingFilled_cashReturnsExactly() public {
        _fundBooks(1_000_000e6, 400_000e6);
        uint256 seniorBefore = core.seniorAssets();
        uint256 juniorBefore = core.juniorAssets();
        (creditSeries s,) = _openSingle(_cb86(OCT_30), 400_000e6, 100_000e6);
        _finalizeByKeeper(s);
        assertEq(uint8(s.state()), uint8(SeriesState.CANCELED), "A9: no fill cancels at finalize");
        assertEq(core.liveSeriesCount(), 0, "A9: canceled series left the live set");
        assertApproxEqAbs(core.seniorAssets(), seniorBefore, 2, "A9: senior book restored");
        assertApproxEqAbs(core.juniorAssets(), juniorBefore, 2, "A9: junior book restored");
        _checkStructure();
    }

    function test_A10_ethOraclePathIsLive() public view {
        (, int256 answer,, uint256 updatedAt,) = iChainlinkFeed(ETH_USD_FEED).latestRoundData();
        assertGt(answer, 0, "A10: ETH/USD feed answers on the fork");
        assertGt(updatedAt, 0, "A10: ETH/USD feed has a timestamp");
    }
}
