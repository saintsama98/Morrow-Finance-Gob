// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Market, Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {HashLib} from "@morpho-org/midnight/src/ratifiers/libraries/HashLib.sol";
import {TickLib} from "@morpho-org/midnight/src/libraries/TickLib.sol";
import {UtilsLib} from "@morpho-org/midnight/src/libraries/UtilsLib.sol";

import {Midnight} from "@morpho-org/midnight/src/Midnight.sol";
import {ORACLE_PRICE_SCALE} from "@morpho-org/midnight/src/libraries/ConstantsLib.sol";

import {SeriesRegistry} from "./SeriesRegistry.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Series} from "../../../src/series/Series.sol";
import {SeriesParams, SeriesState} from "../../../src/interfaces/ISeries.sol";
import {IParking} from "../../../src/parking/IParking.sol";

/// @dev section 25.4 AllocatorHandler: openSeries within policy (immediately registering and filling one bid,
/// see rationale below), cancel, registerOffers (additional bids on top), finalize.
///
/// openSeries fills its own series atomically rather than relying on a later, independently-random
/// registerOffer + borrowerTakesBid pair to happen to land on it before its deployment window or offer expiry
/// passes: Series.MIN_TERM forces maturities >= 14 days out, which needs large warps to ever reach within a
/// bounded-depth run, and any run containing even one such large warp reliably blows through a short
/// deployment window before two *independently* random handler calls can coincidentally correlate on the same
/// series. registerOffer/borrowerTakesBid are kept as separate handler actions for exercising *additional*
/// bids and fills against a series that already has one (partial fills, repeated takes), which is what those
/// two independent steps are actually meant to test -- not whether a series gets its first fill at all.
contract AllocatorHandler is Test {
    using UtilsLib for uint256;

    uint256 internal constant WAD = 1e18;
    SeriesRegistry public registry;
    uint256 public maturityCounter;

    constructor(SeriesRegistry registry_) {
        registry = registry_;
    }

    function openSeries(uint256 sSeed, uint256 jSeed) external {
        uint256 s = bound(sSeed, 100_000e6, 2_000_000e6);
        // a = J / (S+J) kept in [0.15, 0.30] (the curator band) by construction; enforcing C1 is SeriesCore's
        // job (M5), not Series's, so this is just a realistic default for this handler, not an invariant.
        uint256 aWad = bound(jSeed, 0.15e18, 0.30e18);
        uint256 j = s.mulDivDown(aWad, WAD - aWad);

        maturityCounter++;
        // Series.MIN_TERM is a hard 14-day floor (T >= 14 days, tDeployEnd < T - 14 days); staying close to it
        // (rather than spec's realistic 28-91 day tau range) keeps full lifecycles reachable within a single
        // invariant run's warp budget.
        uint256 maturity = block.timestamp + 17 days + maturityCounter * 10 minutes;
        Market memory market = registry.marketFor(maturity);
        registry.midnight().touchMarket(market);
        bytes32 marketId = registry.idOf(market);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = marketId;
        uint256[] memory rateFloors = new uint256[](1);
        rateFloors[0] = 0.005e18;
        uint256[] memory caps = new uint256[](1);
        caps[0] = s + j;

        SeriesParams memory p = SeriesParams({
            marketIds: ids,
            tDeployEnd: uint64(block.timestamp + 2 days), // must stay < T - MIN_TERM (14 days); see maturity above
            dWriteOff: uint64(1 days), // shortened from spec's 7-day default so write-off is reachable in-run
            covWad: 0.15e18,
            pi0Wad: 0.10e18,
            piTWad: 0.20e18,
            pi1Wad: 0.35e18,
            rateFloorWad: rateFloors,
            marketCapAssets: caps,
            kMinAssets: 50_000e6,
            thetaWad: 0.10e18,
            feeRecipient: registry.FEE_RECIPIENT(),
            allocator: registry.ALLOCATOR(),
            parking: IParking(address(registry.parking())),
            offchainAttestationHash: bytes32(0)
        });

        (bool ok, bytes memory ret) = address(registry.core()).call(
            abi.encodeWithSelector(registry.core().createAndFund.selector, registry.factory(), p, s, j)
        );
        registry.recordCall(this.openSeries.selector, !ok);
        if (!ok) return;

        address seriesAddr = abi.decode(ret, (address));
        registry.pushActive(
            seriesAddr,
            SeriesRegistry.SeriesInfo({marketId: marketId, maturity: maturity, registeredAnOffer: false, lastBorrower: address(0)})
        );
        registry.recordFunded(s + j);

        _registerAndFillAtomically(seriesAddr, marketId, maturity, s + j);
    }

    /// @dev Registers one bid for roughly the whole allocation and has a dedicated synthetic borrower take it
    /// immediately, in the same call as funding. See the contract-level doc for why this needs to be atomic.
    function _registerAndFillAtomically(address seriesAddr, bytes32 marketId, uint256 maturity, uint256 kAlloc) internal {
        Series series = Series(seriesAddr);
        uint256 tick = series.tickMaxFor(0);
        uint256 price = TickLib.tickToPrice(tick);
        if (price == 0) return;
        uint256 units = kAlloc.mulDivDown(WAD, price);
        if (units < 1000e6) return;

        Offer memory offer;
        offer.market = registry.marketFor(maturity);
        offer.buy = true;
        offer.maker = seriesAddr;
        offer.expiry = series.T_DEPLOY_END();
        offer.tick = tick;
        offer.group = keccak256(abi.encode("group", seriesAddr));
        offer.callback = seriesAddr;
        offer.callbackData = abi.encode(uint256(0));
        offer.ratifier = address(registry.setterRatifier());
        offer.maxAssets = uint128(units.mulDivUp(price, WAD) + 1000e6);
        offer.continuousFeeCap = type(uint256).max;

        Offer[] memory leaves = new Offer[](1);
        leaves[0] = offer;
        bytes32 root = HashLib.hashOffer(offer);

        vm.prank(registry.ALLOCATOR());
        (bool registered,) = seriesAddr.call(abi.encodeWithSelector(series.registerOffers.selector, root, leaves));
        if (!registered) return;

        address borrower = address(uint160(uint256(keccak256(abi.encode("initial-borrower", seriesAddr)))));
        Midnight midnight = registry.midnight();
        address collateralTokenAddr = registry.collateralToken();
        uint256 oraclePrice = registry.oracle().price();
        uint256 collateral = units.mulDivUp(WAD, registry.LLTV()).mulDivUp(ORACLE_PRICE_SCALE, oraclePrice);
        MockUSDC(collateralTokenAddr).mint(borrower, collateral);

        vm.startPrank(borrower);
        MockUSDC(collateralTokenAddr).approve(address(midnight), collateral);
        midnight.supplyCollateral(offer.market, 0, collateral, borrower);
        vm.stopPrank();

        bytes memory ratifierData = abi.encode(root, uint256(0), new bytes32[](0));
        vm.prank(borrower);
        try midnight.take(offer, ratifierData, units, borrower, borrower, address(0), "") {
            registry.recordUnitsBought(units);
            registry.updateInfo(
                seriesAddr,
                SeriesRegistry.SeriesInfo({marketId: marketId, maturity: maturity, registeredAnOffer: true, lastBorrower: borrower})
            );
            registry.setLastOffer(seriesAddr, offer, root);
        } catch {
            // registration still succeeded; leave registeredAnOffer set so registerOffer's scan skips this
            // series (it already has a bid) even though nobody took it this time.
            registry.updateInfo(
                seriesAddr,
                SeriesRegistry.SeriesInfo({marketId: marketId, maturity: maturity, registeredAnOffer: true, lastBorrower: address(0)})
            );
            registry.setLastOffer(seriesAddr, offer, root);
        }
    }

    function registerOffer(uint256 seriesSeed, uint256 unitsSeed) external {
        (address seriesAddr,) = registry.pickActiveWithOffer(seriesSeed, false);
        if (seriesAddr == address(0)) return;
        Series series = Series(seriesAddr);
        if (uint8(series.state()) != uint8(SeriesState.DEPLOYING)) return;
        if (block.timestamp > series.T_DEPLOY_END()) return;

        (bytes32 marketId, uint256 maturity,,) = registry.info(seriesAddr);

        uint256 tick = series.tickMaxFor(0);
        uint256 price = TickLib.tickToPrice(tick);
        if (price == 0) return;
        uint256 kAlloc = series.seniorAllocated() + series.juniorAllocated();
        uint256 maxUnitsForCap = kAlloc.mulDivDown(WAD, price);
        if (maxUnitsForCap < 1000e6) return;
        uint256 units = bound(unitsSeed, 1000e6, maxUnitsForCap);

        Offer memory offer;
        offer.market = registry.marketFor(series.T());
        offer.buy = true;
        offer.maker = seriesAddr;
        offer.expiry = series.T_DEPLOY_END(); // valid for the whole deployment window, not an arbitrary short window
        offer.tick = tick;
        offer.group = keccak256(abi.encode("group", seriesAddr));
        offer.callback = seriesAddr;
        offer.callbackData = abi.encode(uint256(0));
        offer.ratifier = address(registry.setterRatifier());
        offer.maxAssets = uint128(units.mulDivUp(price, WAD) + 1000e6);
        offer.continuousFeeCap = type(uint256).max;

        Offer[] memory leaves = new Offer[](1);
        leaves[0] = offer;
        bytes32 root = HashLib.hashOffer(offer);

        vm.prank(registry.ALLOCATOR());
        (bool ok,) = seriesAddr.call(abi.encodeWithSelector(series.registerOffers.selector, root, leaves));
        registry.recordCall(this.registerOffer.selector, !ok);
        if (!ok) return;

        registry.updateInfo(
            seriesAddr,
            SeriesRegistry.SeriesInfo({marketId: marketId, maturity: maturity, registeredAnOffer: true, lastBorrower: address(0)})
        );
        registry.setLastOffer(seriesAddr, offer, root);
    }

    function finalizeSeries(uint256 seriesSeed) external {
        (address seriesAddr,) = registry.pickActive(seriesSeed);
        if (seriesAddr == address(0)) return;
        Series series = Series(seriesAddr);
        if (uint8(series.state()) != uint8(SeriesState.DEPLOYING)) return;

        vm.prank(registry.ALLOCATOR());
        (bool ok,) = seriesAddr.call(abi.encodeWithSelector(series.finalize.selector));
        registry.recordCall(this.finalizeSeries.selector, !ok);
    }

    function cancelSeries(uint256 seriesSeed) external {
        (address seriesAddr, uint256 idx) = registry.pickActive(seriesSeed);
        if (seriesAddr == address(0)) return;
        Series series = Series(seriesAddr);
        if (uint8(series.state()) != uint8(SeriesState.DEPLOYING) || series.totalFilled() != 0) return;

        vm.prank(registry.ALLOCATOR());
        (bool ok,) = seriesAddr.call(abi.encodeWithSelector(series.cancel.selector));
        registry.recordCall(this.cancelSeries.selector, !ok);
        if (ok) registry.removeActive(idx);
    }
}
