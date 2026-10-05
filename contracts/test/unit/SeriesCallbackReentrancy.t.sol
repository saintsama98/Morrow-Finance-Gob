// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: a hostile borrower taking the series' bid re-enters from its seller callback; caps, cash and approvals hold.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Market, Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {Midnight} from "@morpho-org/midnight/src/Midnight.sol";
import {HashLib} from "@morpho-org/midnight/src/ratifiers/libraries/HashLib.sol";
import {UtilsLib} from "@morpho-org/midnight/src/libraries/UtilsLib.sol";
import {TickLib} from "@morpho-org/midnight/src/libraries/TickLib.sol";
import {ORACLE_PRICE_SCALE, CALLBACK_SUCCESS} from "@morpho-org/midnight/src/libraries/ConstantsLib.sol";
import {DummyRatifier} from "@morpho-org/midnight/test/helpers/DummyRatifier.sol";
import {MidnightHarness} from "../mocks/MidnightHarness.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {StubCore} from "../mocks/StubCore.sol";
import {seriesFactory} from "../../src/series/seriesFactory.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesParams} from "../../src/interfaces/iSeries.sol";
import {iMidnightMinimal} from "../../src/interfaces/iMidnightMinimal.sol";
import {iParking} from "../../src/parking/iParking.sol";
import {idleParking} from "../../src/parking/idleParking.sol";

contract HostileSeller {
    Midnight immutable midnight;
    creditSeries immutable series;
    Offer offer;
    bytes ratifierData;
    uint256 nestedUnits;
    uint256 public depth;
    uint256 public nestedOk;
    uint256 public directCallsOk;
    uint256 public pokeIndex;
    uint256 public okMask;

    constructor(Midnight midnight_, creditSeries series_) {
        midnight = midnight_;
        series = series_;
    }

    function arm(Offer memory offer_, bytes memory ratifierData_, uint256 nestedUnits_) external {
        offer = offer_;
        ratifierData = ratifierData_;
        nestedUnits = nestedUnits_;
    }

    function post(address collateral, Market memory market, uint256 amount) external {
        MockUSDC(collateral).approve(address(midnight), amount);
        midnight.supplyCollateral(market, 0, amount, address(this));
    }

    function go(uint256 units) external {
        midnight.take(offer, ratifierData, units, address(this), address(this), address(this), "");
    }

    function onSell(bytes32, Market memory, uint256, uint256, uint256, address, address, bytes memory)
        external
        returns (bytes32)
    {
        depth++;
        if (depth == 1) {
            try midnight.take(offer, ratifierData, nestedUnits, address(this), address(this), address(this), "") {
                nestedOk++;
            } catch {}
            _poke(abi.encodeWithSignature("finalize()"));
            _poke(abi.encodeWithSignature("cancel()"));
            _poke(abi.encodeWithSignature("collect(uint256)", 0));
            _poke(abi.encodeWithSignature("claimFee()"));
            _poke(abi.encodeWithSelector(creditSeries(series).deployTake.selector, 0, offer, ratifierData, 1));
            _poke(
                abi.encodeWithSelector(
                    creditSeries(series).onBuy.selector,
                    bytes32(0),
                    offer.market,
                    1e6,
                    1e6,
                    0,
                    address(series),
                    bytes("")
                )
            );
        }
        return CALLBACK_SUCCESS;
    }

    function _poke(bytes memory data) internal {
        (bool ok,) = address(series).call(data);
        if (ok) {
            directCallsOk++;
            okMask |= 1 << pokeIndex;
        }
        pokeIndex++;
    }
}

contract HostileAskMaker {
    Midnight immutable midnight;
    creditSeries immutable series;
    Offer bid;
    bytes bidRatifierData;
    uint256 public nestedOk;
    uint256 public okMask;
    uint256 pokeIndex;
    bool public entered;

    constructor(Midnight midnight_, creditSeries series_, address ratifier) {
        midnight = midnight_;
        series = series_;
        midnight_.setIsAuthorized(ratifier, true, address(this));
    }

    function arm(Offer memory bid_, bytes memory rd) external {
        bid = bid_;
        bidRatifierData = rd;
    }

    function post(address collateral, Market memory market, uint256 amount) external {
        MockUSDC(collateral).approve(address(midnight), amount);
        midnight.supplyCollateral(market, 0, amount, address(this));
    }

    function onSell(bytes32, Market memory, uint256, uint256, uint256, address, address, bytes memory)
        external
        returns (bytes32)
    {
        if (!entered) {
            entered = true;
            try midnight.take(bid, bidRatifierData, 10_000e6, address(this), address(this), address(0), "") {
                nestedOk++;
            } catch {}
            _poke(abi.encodeWithSignature("finalize()"));
            _poke(abi.encodeWithSignature("cancel()"));
            _poke(abi.encodeWithSignature("collect(uint256)", 0));
            _poke(abi.encodeWithSignature("claimFee()"));
        }
        return CALLBACK_SUCCESS;
    }

    function _poke(bytes memory data) internal {
        (bool ok,) = address(series).call(data);
        if (ok) okMask |= 1 << pokeIndex;
        pokeIndex++;
    }
}

contract SeriesCallbackReentrancyTest is Test, MidnightHarness {
    using UtilsLib for uint256;

    uint256 constant WAD = 1e18;
    seriesFactory factory;
    StubCore core;
    idleParking parking;
    address allocator = makeAddr("allocator");
    address sentinel = makeAddr("sentinel");
    address feeRecipient = makeAddr("feeRecipient");
    Market market;
    bytes32 marketId;

    function setUp() public {
        _setUpMidnightHarness();
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
        market = _cbBtcMarket(block.timestamp + 90 days, LLTV_77);
        marketId = _touch(market);
        parking = new idleParking(address(usdc));
        usdc.mint(address(core), 10_000_000e6);
    }

    function _open(uint256 s, uint256 j, uint256 marketCap) internal returns (creditSeries series) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = marketId;
        uint256[] memory floors = new uint256[](1);
        floors[0] = 0.005e18;
        uint256[] memory caps = new uint256[](1);
        caps[0] = marketCap;
        SeriesParams memory p = SeriesParams({
            marketIds: ids,
            tDeployEnd: uint64(block.timestamp + 3 days),
            dWriteOff: uint64(7 days),
            covWad: 0.15e18,
            pi0Wad: 0.1e18,
            piTWad: 0.2e18,
            pi1Wad: 0.35e18,
            rateFloorWad: floors,
            marketCapAssets: caps,
            kMinAssets: 50_000e6,
            thetaWad: 0.1e18,
            feeRecipient: feeRecipient,
            allocator: allocator,
            parking: iParking(address(parking)),
            offchainAttestationHash: bytes32(0)
        });
        vm.prank(address(core));
        series = creditSeries(core.createAndFund(factory, p, s, j));
    }

    function _bid(creditSeries series, uint256 maxAssets) internal returns (Offer memory offer, bytes memory rd) {
        offer.market = market;
        offer.buy = true;
        offer.maker = address(series);
        offer.expiry = block.timestamp + 1 days;
        offer.tick = series.tickMaxFor(0);
        offer.group = keccak256("group-0");
        offer.callback = address(series);
        offer.callbackData = abi.encode(uint256(0));
        offer.ratifier = address(setterRatifier);
        offer.maxAssets = uint128(maxAssets);
        offer.continuousFeeCap = type(uint256).max;
        Offer[] memory leaves = new Offer[](1);
        leaves[0] = offer;
        bytes32 root = HashLib.hashOffer(offer);
        vm.prank(allocator);
        series.registerOffers(root, leaves);
        rd = abi.encode(root, uint256(0), new bytes32[](0));
    }

    function _hostile(creditSeries series, uint256 units) internal returns (HostileSeller h) {
        h = new HostileSeller(midnight, series);
        uint256 collateral = units.mulDivUp(WAD, LLTV_77).mulDivUp(ORACLE_PRICE_SCALE, cbBtcOracle.price());
        MockUSDC(cbBTC).mint(address(h), collateral);
        h.post(cbBTC, market, collateral);
    }

    function _assertSeriesConsistent(creditSeries series, uint256 kAlloc, uint256 cap) internal view {
        assertLe(series.filled(0), cap, "filled within market cap");
        assertLe(series.totalFilled(), kAlloc, "totalFilled within allocation");
        assertEq(usdc.balanceOf(address(series)), 0, "no raw cash stranded on the series");
        assertEq(usdc.allowance(address(series), address(midnight)), 0, "no standing approval to Midnight");
        assertEq(
            parking.totalAssets(address(series)) + series.totalFilled(), kAlloc, "parked plus lent equals allocation"
        );
        (uint128 credit,,) = midnight.updatePositionView(market, marketId, address(series));
        assertEq(uint256(credit), series.unitsBought(0), "Midnight credit equals recorded units");
    }

    function test_nestedTakeFromSellerCallback_withinCap_fillsTwiceConsistently() public {
        creditSeries series = _open(900_000e6, 200_000e6, 1_100_000e6);
        (Offer memory offer, bytes memory rd) = _bid(series, 400_000e6);
        HostileSeller h = _hostile(series, 300_000e6);
        h.arm(offer, rd, 100_000e6);
        vm.prank(address(h));
        h.go(100_000e6);
        assertEq(h.nestedOk(), 1, "a nested take is a second ordinary fill");
        assertEq(h.okMask(), 1 << 3, "only claimFee, a no-op with nothing owed, succeeds from the seller callback");
        assertEq(series.unitsBought(0), 200_000e6);
        _assertSeriesConsistent(series, 1_100_000e6, 1_100_000e6);
    }

    function test_nestedTakeFromSellerCallback_pastAllocation_isRejected() public {
        creditSeries series = _open(150_000e6, 30_000e6, 1_000_000e6);
        (Offer memory offer, bytes memory rd) = _bid(series, 400_000e6);
        HostileSeller h = _hostile(series, 300_000e6);
        h.arm(offer, rd, 100_000e6);
        vm.prank(address(h));
        h.go(100_000e6);
        assertEq(h.nestedOk(), 0, "the nested fill would breach the allocation and must fail");
        _assertSeriesConsistent(series, 180_000e6, 1_000_000e6);
    }

    function test_donationBeforeCollect_cannotBreakTheBalanceDeltaCheck() public {
        creditSeries series = _open(900_000e6, 200_000e6, 1_100_000e6);
        (Offer memory offer, bytes memory rd) = _bid(series, 400_000e6);
        HostileSeller h = _hostile(series, 100_000e6);
        h.arm(offer, rd, 0);
        vm.prank(address(h));
        h.go(100_000e6);
        vm.prank(allocator);
        series.finalize();
        usdc.mint(address(series), 777e6);
        uint256 repay = 100_000e6;
        usdc.mint(address(h), repay);
        vm.warp(market.maturity + 1);
        vm.startPrank(address(h));
        usdc.approve(address(midnight), repay);
        midnight.repay(market, repay, address(h), address(0), "");
        vm.stopPrank();
        series.startSettlement();
        uint256 got = series.collect(0);
        assertEq(got, 100_000e6, "collect pays exactly the credit, donations do not enter the delta");
        assertTrue(series.resolved(0));
        series.settle();
        assertEq(usdc.balanceOf(address(series)), 0, "the donation is swept into the waterfall, not stranded");
    }

    function test_hostileAskMaker_reentersDuringDeployTake_cannotReachTheSeries() public {
        creditSeries series = _open(900_000e6, 200_000e6, 1_100_000e6);
        (Offer memory bid, bytes memory rd) = _bid(series, 400_000e6);
        DummyRatifier dummy = new DummyRatifier();
        HostileAskMaker m = new HostileAskMaker(midnight, series, address(dummy));
        uint256 units = 50_000e6;
        uint256 collateral = (units * 2).mulDivUp(WAD, LLTV_77).mulDivUp(ORACLE_PRICE_SCALE, cbBtcOracle.price());
        MockUSDC(cbBTC).mint(address(m), collateral);
        m.post(cbBTC, market, collateral);
        m.arm(bid, rd);

        Offer memory ask;
        ask.market = market;
        ask.buy = false;
        ask.maker = address(m);
        ask.receiverIfMakerIsSeller = address(m);
        ask.maxAssets = type(uint128).max;
        ask.continuousFeeCap = type(uint256).max;
        ask.group = keccak256("hostile-ask");
        ask.ratifier = address(dummy);
        ask.expiry = block.timestamp + 1 days;
        ask.tick = series.tickMaxFor(0);
        ask.callback = address(m);

        vm.prank(allocator);
        series.deployTake(0, ask, "", units);

        assertEq(m.nestedOk(), 0, "the series bid cannot be filled while deployTake holds the lock");
        assertTrue(m.entered(), "the maker callback ran");
        assertEq(m.okMask(), 0, "every series entry point is locked while deployTake runs");
        assertEq(series.unitsBought(0), units);
        _assertSeriesConsistent(series, 1_100_000e6, 1_100_000e6);
    }

    function test_parkedBalanceAboveAllocation_cannotBeFilledPastAllocation() public {
        creditSeries series = _open(150_000e6, 30_000e6, 1_000_000e6);
        address donor = makeAddr("donor");
        usdc.mint(donor, 300_000e6);
        vm.startPrank(donor);
        usdc.approve(address(parking), 300_000e6);
        parking.deposit(300_000e6);
        parking.transferPosition(address(series), 300_000e6);
        vm.stopPrank();
        assertGt(parking.totalAssets(address(series)), 180_000e6, "series now parks more than its allocation");

        (Offer memory offer, bytes memory rd) = _bid(series, 400_000e6);
        HostileSeller h = _hostile(series, 250_000e6);
        h.arm(offer, rd, 0);
        vm.prank(address(h));
        vm.expectRevert();
        h.go(250_000e6);
        assertEq(series.totalFilled(), 0, "no fill may take the series past its allocation");

        vm.prank(address(h));
        h.go(150_000e6);
        assertLe(series.totalFilled(), 180_000e6);
        vm.prank(allocator);
        series.finalize();
    }
}
