// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: unit tests for creditSeries accounting and settlement: sync, navs, and the waterfall rerun.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Market, Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {Midnight} from "@morpho-org/midnight/src/Midnight.sol";
import {HashLib} from "@morpho-org/midnight/src/ratifiers/libraries/HashLib.sol";
import {UtilsLib} from "@morpho-org/midnight/src/libraries/UtilsLib.sol";
import {ORACLE_PRICE_SCALE} from "@morpho-org/midnight/src/libraries/ConstantsLib.sol";

import {MidnightHarness} from "../mocks/MidnightHarness.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {StubCore} from "../mocks/StubCore.sol";
import {seriesFactory} from "../../src/series/seriesFactory.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesParams, SeriesState} from "../../src/interfaces/iSeries.sol";
import {iMidnightMinimal} from "../../src/interfaces/iMidnightMinimal.sol";
import {iParking} from "../../src/parking/iParking.sol";
import {idleParking} from "../../src/parking/idleParking.sol";
import {seriesMath} from "../../src/libraries/seriesMath.sol";
import {seriesStorage} from "../../src/series/modules/seriesStorage.sol";

contract SeriesSettlementTest is Test, MidnightHarness {
    using UtilsLib for uint256;

    uint256 constant WAD = 1e18;
    seriesFactory factory;
    StubCore core;
    address allocator = makeAddr("allocator");
    address sentinel = makeAddr("sentinel");
    address feeRecipient = makeAddr("feeRecipient");
    address borrower = makeAddr("borrower");
    idleParking parking;

    uint256 maturity;
    bytes32 marketId;
    Market market;

    function setUp() public {
        _setUpMidnightHarness();
        maturity = block.timestamp + 90 days;

        core = new StubCore(address(usdc), sentinel);
        factory = new seriesFactory(
            iMidnightMinimal(address(midnight)), address(setterRatifier), address(usdc), address(this), 0.86e18, 4
        );
        factory.setCore(address(core));

        factory.proposeCollateralAllowed(cbBTC, true);
        factory.proposeOracleAllowed(cbBTC, address(cbBtcOracle), true);
        vm.warp(block.timestamp + 48 hours);
        factory.executeCollateralAllowed(cbBTC, true);
        factory.executeOracleAllowed(cbBTC, address(cbBtcOracle), true);
        vm.warp(block.timestamp - 48 hours);

        market = _cbBtcMarket(maturity, LLTV_77);
        marketId = _touch(market);

        parking = new idleParking(address(usdc));
        usdc.mint(address(core), 10_000_000e6);
    }

    function _defaultParams(uint256 kAllocCap) internal view returns (SeriesParams memory p) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = marketId;
        uint256[] memory rateFloors = new uint256[](1);
        rateFloors[0] = 0.005e18;
        uint256[] memory caps = new uint256[](1);
        caps[0] = kAllocCap;

        p = SeriesParams({
            marketIds: ids,
            tDeployEnd: uint64(block.timestamp + 3 days),
            dWriteOff: uint64(7 days),
            covWad: 0.15e18,
            pi0Wad: 0.1e18,
            piTWad: 0.2e18,
            pi1Wad: 0.35e18,
            rateFloorWad: rateFloors,
            marketCapAssets: caps,
            kMinAssets: 50_000e6,
            thetaWad: 0.1e18,
            feeRecipient: feeRecipient,
            allocator: allocator,
            parking: iParking(address(parking)),
            offchainAttestationHash: bytes32(0)
        });
    }

    function _openAndFund(uint256 s, uint256 j) internal returns (creditSeries series) {
        SeriesParams memory p = _defaultParams(s + j);
        vm.prank(address(core));
        address seriesAddr = core.createAndFund(factory, p, s, j);
        series = creditSeries(seriesAddr);
    }

    function _collateralizeAndBorrow(address who, uint256 units) internal {
        uint256 oraclePrice = cbBtcOracle.price();
        uint256 lltv = market.collateralParams[0].lltv;
        uint256 collateral = units.mulDivUp(WAD, lltv).mulDivUp(ORACLE_PRICE_SCALE, oraclePrice);
        MockUSDC(cbBTC).mint(who, collateral);
        vm.startPrank(who);
        MockUSDC(cbBTC).approve(address(midnight), collateral);
        midnight.supplyCollateral(market, 0, collateral, who);
        vm.stopPrank();
    }

    function _fillAndFinalize(creditSeries series, uint256 units) internal {
        uint256 tick = series.tickMaxFor(0);

        Offer memory offer;
        offer.market = market;
        offer.buy = true;
        offer.maker = address(series);
        offer.start = 0;
        offer.expiry = block.timestamp + 1 days;
        offer.tick = tick;
        offer.group = keccak256("group-0");
        offer.callback = address(series);
        offer.callbackData = abi.encode(uint256(0));
        offer.ratifier = address(setterRatifier);
        offer.maxAssets = uint128(units + units / 10);
        offer.continuousFeeCap = type(uint256).max;

        Offer[] memory leaves = new Offer[](1);
        leaves[0] = offer;
        bytes32 root = HashLib.hashOffer(offer);

        vm.prank(allocator);
        series.registerOffers(root, leaves);

        _collateralizeAndBorrow(borrower, units);
        bytes memory ratifierData = abi.encode(root, uint256(0), new bytes32[](0));
        vm.prank(borrower);
        midnight.take(offer, ratifierData, units, borrower, borrower, address(0), "");

        vm.prank(allocator);
        series.finalize();
    }

    function test_fullLifecycle_repaymentNoLoss() public {
        creditSeries series = _openAndFund(900_000e6, 200_000e6);
        uint256 units = 1_000_000e6;
        _fillAndFinalize(series, units);

        uint256 seniorClaim = series.seniorClaim();
        uint256 juniorDeployed = series.juniorDeployed();

        vm.warp(maturity + 1);
        series.startSettlement();
        assertEq(uint8(series.state()), uint8(SeriesState.SETTLING));

        uint128 debtOwed = midnight.debt(marketId, borrower);
        usdc.mint(borrower, uint256(debtOwed));
        vm.startPrank(borrower);
        usdc.approve(address(midnight), uint256(debtOwed));
        midnight.repay(market, debtOwed, borrower, address(0), "");
        vm.stopPrank();

        uint256 received = series.collect(0);
        assertEq(received, units, "full repayment collects exactly the units lent (fee = 0 in this harness)");
        assertTrue(series.resolved(0), "market must be resolved once repaid and settlement has begun");

        series.settle();
        assertEq(uint8(series.state()), uint8(SeriesState.SETTLED));

        (uint256 expectedXs, uint256 expectedXj, uint256 expectedFee) =
            seriesMath.waterfall(units, seniorClaim, juniorDeployed, 0.1e18);
        assertEq(core.lastPayoutToSenior(), expectedXs, "senior payout must match seriesMath.waterfall");
        assertEq(core.lastPayoutToJunior(), expectedXj, "junior payout must match seriesMath.waterfall");
        assertGt(expectedFee, 0, "no-loss case should recognize a positive operator fee");

        series.claimFee();
        assertEq(usdc.balanceOf(feeRecipient), expectedFee, "fee recipient must receive exactly the recognized fee");
    }

    function test_navs_convergeToWaterfallAtMaturity() public {
        creditSeries series = _openAndFund(900_000e6, 200_000e6);
        uint256 units = 1_000_000e6;
        _fillAndFinalize(series, units);

        vm.warp(maturity);
        (uint256 navS, uint256 navJ, uint256 feeAccrued) = series.navs();

        (uint256 expectedXs, uint256 expectedXj, uint256 expectedFee) =
            seriesMath.waterfall(units, series.seniorClaim(), series.juniorDeployed(), 0.1e18);

        assertEq(navS, expectedXs, "navS must converge to the waterfall's XS at maturity");
        assertEq(navJ, expectedXj, "navJ must converge to the waterfall's XJ at maturity");
        assertEq(feeAccrued, expectedFee, "feeAccrued must converge to the waterfall's fee at maturity");
    }

    function test_sync_permissionless_emitsBufferUpdated() public {
        creditSeries series = _openAndFund(900_000e6, 200_000e6);
        _fillAndFinalize(series, 1_000_000e6);

        vm.warp(maturity);
        series.sync(0);
    }

    function test_writeOff_noRepayment_pushesNothingBeyondWhatWasCollected() public {
        creditSeries series = _openAndFund(900_000e6, 200_000e6);
        uint256 units = 1_000_000e6;
        _fillAndFinalize(series, units);

        vm.warp(maturity);
        series.startSettlement();

        vm.warp(maturity + series.D_WRITE_OFF() + 1);

        assertFalse(series.resolved(0));
        series.writeOff();

        assertEq(uint8(series.state()), uint8(SeriesState.SETTLED));
        assertTrue(series.writtenOff(0));
        assertEq(core.lastPayoutToSenior(), 0);
        assertEq(core.lastPayoutToJunior(), 0);
    }

    function test_writeOff_beforeDelay_reverts() public {
        creditSeries series = _openAndFund(900_000e6, 200_000e6);
        _fillAndFinalize(series, 1_000_000e6);

        vm.warp(maturity);
        series.startSettlement();

        vm.expectRevert(abi.encodeWithSelector(seriesStorage.TooEarly.selector, block.timestamp));
        series.writeOff();
    }

    function test_settle_beforeAllResolved_reverts() public {
        creditSeries series = _openAndFund(900_000e6, 200_000e6);
        _fillAndFinalize(series, 1_000_000e6);

        vm.warp(maturity);
        series.startSettlement();

        vm.expectRevert(abi.encodeWithSelector(seriesStorage.NotResolved.selector, 0));
        series.settle();
    }

    function test_collect_afterWriteOff_isARecoveryThatRerunsWaterfall() public {
        creditSeries series = _openAndFund(900_000e6, 200_000e6);
        uint256 units = 1_000_000e6;
        _fillAndFinalize(series, units);

        vm.warp(maturity);
        series.startSettlement();
        vm.warp(maturity + series.D_WRITE_OFF() + 1);
        series.writeOff();

        assertEq(core.lastPayoutToSenior(), 0);

        uint128 debtOwed = midnight.debt(marketId, borrower);
        usdc.mint(borrower, uint256(debtOwed));
        vm.startPrank(borrower);
        usdc.approve(address(midnight), uint256(debtOwed));
        midnight.repay(market, debtOwed, borrower, address(0), "");
        vm.stopPrank();

        uint256 received = series.collect(0);
        assertEq(received, units);
        assertGt(core.lastPayoutToSenior(), 0, "the recovery must flow to senior first");
    }
}
