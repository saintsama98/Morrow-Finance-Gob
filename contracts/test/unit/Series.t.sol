// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Market, Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {HashLib} from "@morpho-org/midnight/src/ratifiers/libraries/HashLib.sol";
import {UtilsLib} from "@morpho-org/midnight/src/libraries/UtilsLib.sol";
import {TickLib, MAX_TICK} from "@morpho-org/midnight/src/libraries/TickLib.sol";
import {ORACLE_PRICE_SCALE, CALLBACK_SUCCESS} from "@morpho-org/midnight/src/libraries/ConstantsLib.sol";
import {DummyRatifier} from "@morpho-org/midnight/test/helpers/DummyRatifier.sol";

import {MidnightHarness} from "../mocks/MidnightHarness.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {StubCore} from "../mocks/StubCore.sol";
import {SeriesFactory} from "../../src/series/SeriesFactory.sol";
import {Series} from "../../src/series/Series.sol";
import {SeriesParams, SeriesState} from "../../src/interfaces/ISeries.sol";
import {IMidnightMinimal} from "../../src/interfaces/IMidnightMinimal.sol";
import {IParking} from "../../src/parking/IParking.sol";
import {IdleParking} from "../../src/parking/IdleParking.sol";

// Morrow Finance — unit tests for Series creation, funding, fills, and finalize.
// @author adiii.eth

/// @notice Exercises creation, funding, cancel, the maker-path onBuy fill against the real Midnight contract
/// and real SetterRatifier, its guards, and finalize -- all against a stand-in core.
contract SeriesTest is Test, MidnightHarness {
    using UtilsLib for uint256;

    uint256 constant WAD = 1e18;
    SeriesFactory factory;
    StubCore core;
    address allocator = makeAddr("allocator");
    address sentinel = makeAddr("sentinel");
    address feeRecipient = makeAddr("feeRecipient");
    address borrower = makeAddr("borrower");
    IdleParking parking;

    uint256 maturity;
    bytes32 marketId;
    Market market;

    function setUp() public {
        _setUpMidnightHarness();
        maturity = block.timestamp + 90 days;

        core = new StubCore(address(usdc), sentinel);
        factory = new SeriesFactory(
            IMidnightMinimal(address(midnight)), address(setterRatifier), address(usdc), address(this), 0.86e18, 4
        );
        factory.setCore(address(core));

        _allowCollateralAndOracle(cbBTC, address(cbBtcOracle));

        market = _cbBtcMarket(maturity, LLTV_77);
        marketId = _touch(market);

        parking = new IdleParking(address(usdc));

        usdc.mint(address(core), 10_000_000e6);
    }

    function _allowCollateralAndOracle(address token, address oracle) internal {
        factory.proposeCollateralAllowed(token, true);
        factory.proposeOracleAllowed(token, oracle, true);
        vm.warp(block.timestamp + 48 hours);
        factory.executeCollateralAllowed(token, true);
        factory.executeOracleAllowed(token, oracle, true);
        vm.warp(block.timestamp - 48 hours);
    }

    function _defaultParams(uint256 kAllocCap) internal view returns (SeriesParams memory p) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = marketId;
        uint256[] memory rateFloors = new uint256[](1);
        rateFloors[0] = 0.005e18; // 0.5% term floor
        uint256[] memory caps = new uint256[](1);
        caps[0] = kAllocCap;

        p = SeriesParams({
            marketIds: ids,
            tDeployEnd: uint64(block.timestamp + 3 days),
            dWriteOff: uint64(7 days),
            covWad: 0.15e18,
            pi0Wad: 0.10e18,
            piTWad: 0.20e18,
            pi1Wad: 0.35e18,
            rateFloorWad: rateFloors,
            marketCapAssets: caps,
            kMinAssets: 50_000e6,
            thetaWad: 0.10e18,
            feeRecipient: feeRecipient,
            allocator: allocator,
            parking: IParking(address(parking)),
            offchainAttestationHash: bytes32(0)
        });
    }

    function _openAndFund(uint256 s, uint256 j) internal returns (Series series) {
        SeriesParams memory p = _defaultParams(s + j);
        vm.prank(address(core));
        address seriesAddr = core.createAndFund(factory, p, s, j);
        series = Series(seriesAddr);
    }

    // --- funding + cancel ---------------------------------------------------------------------------------

    function test_initialize_setsAllocations() public {
        Series series = _openAndFund(900_000e6, 200_000e6);
        assertEq(series.seniorAllocated(), 900_000e6);
        assertEq(series.juniorAllocated(), 200_000e6);
        assertEq(uint8(series.state()), uint8(SeriesState.DEPLOYING));
        assertEq(parking.totalAssets(address(series)), 1_100_000e6);
    }

    function test_cancel_beforeAnyFill_returnsExactly() public {
        Series series = _openAndFund(900_000e6, 200_000e6);

        vm.prank(allocator);
        series.cancel();

        assertEq(uint8(series.state()), uint8(SeriesState.CANCELED));
        assertEq(core.lastReturnToSenior(), 900_000e6);
        assertEq(core.lastReturnToJunior(), 200_000e6);
        assertEq(core.lastReturnToSenior() + core.lastReturnToJunior(), 1_100_000e6);
    }

    function test_cancel_bySentinel_allowed() public {
        Series series = _openAndFund(900_000e6, 200_000e6);
        vm.prank(sentinel);
        series.cancel();
        assertEq(uint8(series.state()), uint8(SeriesState.CANCELED));
    }

    function test_cancel_byRandomAddress_reverts() public {
        Series series = _openAndFund(900_000e6, 200_000e6);
        vm.expectRevert(Series.NotCoreOrSentinel.selector);
        series.cancel();
    }

    // --- maker path: real fill through Midnight + SetterRatifier -------------------------------------------

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

    function _registerSingleOffer(Series series, uint256 units, uint256 tick)
        internal
        returns (Offer memory offer, bytes32 root)
    {
        uint256 price = TickLib.tickToPrice(tick);

        offer.market = market;
        offer.buy = true;
        offer.maker = address(series);
        offer.start = 0;
        offer.expiry = block.timestamp + 1 days;
        offer.tick = tick;
        offer.group = keccak256("group-0");
        offer.callback = address(series);
        offer.callbackData = abi.encode(uint256(0));
        offer.receiverIfMakerIsSeller = address(0);
        offer.ratifier = address(setterRatifier);
        offer.reduceOnly = false;
        offer.maxUnits = 0;
        offer.maxAssets = uint128(units.mulDivUp(price, WAD) + 1); // generous cap above the expected fill
        offer.continuousFeeCap = type(uint256).max;

        Offer[] memory leaves = new Offer[](1);
        leaves[0] = offer;
        root = HashLib.hashOffer(offer);

        vm.prank(allocator);
        series.registerOffers(root, leaves);
    }

    function test_onBuy_makerPath_realFillThroughMidnight() public {
        Series series = _openAndFund(900_000e6, 200_000e6);
        uint256 tick = series.tickMaxFor(0);
        uint256 units = 100_000e6;

        (Offer memory offer, bytes32 root) = _registerSingleOffer(series, units, tick);

        _collateralizeAndBorrow(borrower, units);

        bytes memory ratifierData = abi.encode(root, uint256(0), new bytes32[](0));
        vm.prank(borrower);
        midnight.take(offer, ratifierData, units, borrower, borrower, address(0), "");

        assertEq(series.unitsBought(0), units, "units recorded");
        assertGt(series.filled(0), 0, "assets recorded");
        assertEq(series.totalFilled(), series.filled(0), "totalFilled matches single market fill");
    }

    function test_onBuy_wrongCaller_reverts() public {
        Series series = _openAndFund(900_000e6, 200_000e6);
        vm.expectRevert(Series.NotMidnight.selector);
        series.onBuy(marketId, market, 100e6, 100e6, 0, address(series), abi.encode(uint256(0)));
    }

    function test_onBuy_noOpTake_changesNoState() public {
        Series series = _openAndFund(900_000e6, 200_000e6);
        uint256 filledBefore = series.filled(0);
        uint256 totalBefore = series.totalFilled();

        vm.prank(address(midnight));
        bytes32 result = series.onBuy(marketId, market, 0, 0, 0, address(series), abi.encode(uint256(0)));

        assertEq(result, CALLBACK_SUCCESS);
        assertEq(series.filled(0), filledBefore);
        assertEq(series.totalFilled(), totalBefore);
    }

    function test_onBuy_wrongMarketId_reverts() public {
        Series series = _openAndFund(900_000e6, 200_000e6);
        vm.prank(address(midnight));
        vm.expectRevert(abi.encodeWithSelector(Series.MarketMismatch.selector, marketId, bytes32(uint256(1))));
        series.onBuy(bytes32(uint256(1)), market, 100e6, 100e6, 0, address(series), abi.encode(uint256(0)));
    }

    function test_onBuy_afterTDeployEnd_reverts() public {
        Series series = _openAndFund(900_000e6, 200_000e6);
        vm.warp(block.timestamp + 4 days); // past tDeployEnd (3 days)

        vm.prank(address(midnight));
        vm.expectRevert(
            abi.encodeWithSelector(Series.WrongState.selector, SeriesState.DEPLOYING, SeriesState.DEPLOYING)
        );
        series.onBuy(marketId, market, 100e6, 100e6, 0, address(series), abi.encode(uint256(0)));
    }

    // --- finalize ------------------------------------------------------------------------------------------

    function test_finalize_kdZero_cancels() public {
        Series series = _openAndFund(900_000e6, 200_000e6);
        vm.warp(block.timestamp + 4 days);
        series.finalize();

        assertEq(uint8(series.state()), uint8(SeriesState.CANCELED));
        assertEq(core.lastReturnToSenior(), 900_000e6);
        assertEq(core.lastReturnToJunior(), 200_000e6);
    }

    function test_finalize_belowKMin_setsPassThrough() public {
        Series series = _openAndFund(900_000e6, 200_000e6);
        uint256 tick = series.tickMaxFor(0);
        uint256 units = 10_000e6; // well below kMinAssets = 50_000e6

        (Offer memory offer, bytes32 root) = _registerSingleOffer(series, units, tick);
        _collateralizeAndBorrow(borrower, units);
        bytes memory ratifierData = abi.encode(root, uint256(0), new bytes32[](0));
        vm.prank(borrower);
        midnight.take(offer, ratifierData, units, borrower, borrower, address(0), "");

        vm.prank(allocator);
        series.finalize();

        assertTrue(series.passThrough());
        assertEq(uint8(series.state()), uint8(SeriesState.LOCKED));
    }

    function test_finalize_normalPath_pricesCorrectly() public {
        Series series = _openAndFund(900_000e6, 200_000e6);
        uint256 tick = series.tickMaxFor(0);
        uint256 units = 1_000_000e6; // above kMin, fills fully at ~1.0 price

        (Offer memory offer, bytes32 root) = _registerSingleOffer(series, units, tick);
        _collateralizeAndBorrow(borrower, units);
        bytes memory ratifierData = abi.encode(root, uint256(0), new bytes32[](0));
        vm.prank(borrower);
        midnight.take(offer, ratifierData, units, borrower, borrower, address(0), "");

        vm.prank(allocator);
        series.finalize();

        assertEq(uint8(series.state()), uint8(SeriesState.LOCKED));
        assertFalse(series.passThrough());
        assertEq(series.seniorDeployed() + series.juniorDeployed(), series.totalFilled());
        assertGt(series.seniorClaim(), 0);
    }

    // --- taker path ------------------------------------------------------------------------------------------

    /// @dev Sets up an existing lender with a real credit position (by having a separate borrower take their
    /// buy offer, via a permissive DummyRatifier unrelated to our SetterRatifier), then has that lender post a
    /// sell offer (ask) for that same position. Returns the ask offer ready for our series to take.
    function _setUpExistingAskFromLender(uint256 units, uint256 askTick)
        internal
        returns (address existingLender, Offer memory ask)
    {
        existingLender = makeAddr("existingLender");
        DummyRatifier dummy = new DummyRatifier();

        vm.prank(existingLender);
        midnight.setIsAuthorized(address(dummy), true, existingLender);

        usdc.mint(existingLender, units * 2); // headroom for the buy leg
        vm.startPrank(existingLender);
        usdc.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        Offer memory lenderBuyOffer;
        lenderBuyOffer.market = market;
        lenderBuyOffer.buy = true;
        lenderBuyOffer.maker = existingLender;
        lenderBuyOffer.maxUnits = 0;
        lenderBuyOffer.maxAssets = type(uint128).max;
        lenderBuyOffer.continuousFeeCap = type(uint256).max;
        lenderBuyOffer.group = keccak256("existing-lender-buy");
        lenderBuyOffer.ratifier = address(dummy);
        lenderBuyOffer.expiry = block.timestamp + 1 days;
        lenderBuyOffer.tick = MAX_TICK;

        address otherBorrower = makeAddr("otherBorrowerForAsk");
        _collateralizeAndBorrow(otherBorrower, units);
        vm.prank(otherBorrower);
        midnight.take(lenderBuyOffer, "", units, otherBorrower, otherBorrower, address(0), "");

        ask.market = market;
        ask.buy = false;
        ask.maker = existingLender;
        ask.receiverIfMakerIsSeller = existingLender;
        ask.maxUnits = 0;
        ask.maxAssets = type(uint128).max;
        ask.continuousFeeCap = type(uint256).max;
        ask.group = keccak256("existing-lender-sell");
        ask.ratifier = address(dummy);
        ask.expiry = block.timestamp + 1 days;
        ask.tick = askTick;
    }

    function test_deployTake_takerPath_realFillThroughMidnight() public {
        Series series = _openAndFund(900_000e6, 200_000e6);
        uint256 units = 50_000e6;

        (, Offer memory ask) = _setUpExistingAskFromLender(units, series.tickMaxFor(0));

        vm.prank(allocator);
        series.deployTake(0, ask, "", units);

        assertEq(series.unitsBought(0), units, "units recorded");
        assertGt(series.filled(0), 0, "assets recorded");
        assertEq(series.totalFilled(), series.filled(0));

        (uint128 credit,,) = midnight.updatePositionView(market, marketId, address(series));
        assertEq(uint256(credit), units, "series must hold the credit it just bought");
    }

    /// @dev deployTake requires a sell offer (offer.buy == false); the taker path only exists to take existing
    /// asks, never to duplicate the maker path's bids.
    function test_deployTake_wrongOfferSide_reverts() public {
        Series series = _openAndFund(900_000e6, 200_000e6);
        uint256 units = 50_000e6;
        (, Offer memory ask) = _setUpExistingAskFromLender(units, series.tickMaxFor(0));
        ask.buy = true;

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(Series.MarketMismatch.selector, marketId, marketId));
        series.deployTake(0, ask, "", units);
    }

    function test_deployTake_onlyAllocator_reverts() public {
        Series series = _openAndFund(900_000e6, 200_000e6);
        uint256 units = 50_000e6;
        (, Offer memory ask) = _setUpExistingAskFromLender(units, series.tickMaxFor(0));

        vm.expectRevert(Series.NotAllocator.selector);
        series.deployTake(0, ask, "", units);
    }
}
