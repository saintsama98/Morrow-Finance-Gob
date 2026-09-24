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
import {SeriesParams} from "../../../src/interfaces/ISeries.sol";
import {IParking} from "../../../src/parking/IParking.sol";
import {SeriesCore} from "../../../src/core/SeriesCore.sol";

// Morrow Finance — invariant-suite handler that opens series through the REAL SeriesCore (M8), not the stub.
// @author adiii.eth

/// @notice Fuzz handler: openSeries against the real `SeriesCore.openSeries`, bounded by whatever is actually
/// idle in the senior/junior books at call time (unlike the stub-based AllocatorHandler.openSeries, which
/// self-funds unconditionally). Real capital only ever enters the books through VaultHandler/EpochHandler, so
/// this handler is a no-op until at least one of those has landed -- exactly the dependency CoreVaultInvariants
/// seeds once in setUp before the fuzzer takes over, matching the existing series-only suite's convention.
/// registerOffer / finalizeSeries / cancelSeries are intentionally NOT duplicated here: they operate purely on
/// a `Series` picked from `registry.activeSeries` and never touch the core, so AllocatorHandler's versions of
/// those three are reused unmodified against series this handler pushes too.
contract CoreAllocatorHandler is Test {
    using UtilsLib for uint256;

    uint256 internal constant WAD = 1e18;
    SeriesRegistry public registry;
    uint256 public maturityCounter;

    constructor(SeriesRegistry registry_) {
        registry = registry_;
    }

    function openSeries(uint256 sSeed, uint256 jSeed) external {
        uint256 seniorAvail = registry.realCore().idleAvailable(true);
        uint256 juniorAvail = registry.realCore().idleAvailable(false);
        if (seniorAvail < 50_000e6 || juniorAvail < 50_000e6) return; // below kMinAssets either side, not worth it

        // floor of 50_000e6 (kMinAssets) rather than 0: a seed of 0 would otherwise map to S == 0 every time,
        // which the S == 0 guard below just throws away -- kMinAssets is the smallest allocation an allocator
        // would realistically propose anyway, so this also makes every non-skipped call a meaningful open.
        uint256 S = bound(sSeed, 50_000e6, seniorAvail);
        // keep J inside the curator's coverage band [covWad, aMaxWad] relative to whatever S landed on, same
        // convention as AllocatorHandler.openSeries -- CoreVaultInvariants exercises the band's own boundary
        // failures through the real openSeries call reverting, not by feeding it out-of-band inputs here.
        // J rounds UP: SeriesCore.openSeries recomputes aWad' = floor(J * WAD / (S + J)) and requires
        // aWad' >= covWad. Flooring J here (the naive computation) can round aWad' just under the target when
        // aWad == covWad exactly; rounding J up keeps J * WAD >= covWad * (S + J) as integers, which keeps
        // floor(J * WAD / (S + J)) >= covWad too.
        uint256 aWad = bound(jSeed, 0.15e18, 0.3e18);
        uint256 J = S.mulDivUp(aWad, WAD - aWad);
        if (J > juniorAvail) J = juniorAvail;
        if (J < 1000e6) return; // too small to fill 1 unit at any plausible price; not worth registering an offer

        maturityCounter++;
        uint256 maturity = block.timestamp + 17 days + maturityCounter * 10 minutes;
        Market memory market = registry.marketFor(maturity);
        registry.midnight().touchMarket(market);
        bytes32 marketId = registry.idOf(market);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = marketId;
        uint256[] memory rateFloors = new uint256[](1);
        rateFloors[0] = 0.005e18;
        uint256[] memory caps = new uint256[](1);
        caps[0] = S + J;

        SeriesParams memory p = SeriesParams({
            marketIds: ids,
            tDeployEnd: uint64(block.timestamp + 2 days),
            dWriteOff: uint64(1 days),
            covWad: 0.15e18,
            pi0Wad: 0.1e18,
            piTWad: 0.2e18,
            pi1Wad: 0.35e18,
            rateFloorWad: rateFloors,
            marketCapAssets: caps,
            kMinAssets: 50_000e6,
            thetaWad: 0.1e18,
            feeRecipient: registry.FEE_RECIPIENT(),
            allocator: registry.ALLOCATOR(),
            parking: IParking(address(registry.parking())),
            offchainAttestationHash: bytes32(0)
        });

        // registry.realCore() must be resolved BEFORE the prank: it is itself an external call, and vm.prank
        // only overrides msg.sender for this contract's very next external call -- see DeployHandler's header
        // note for the same gotcha (registry.midnight() vs midnight.take()).
        SeriesCore realCoreRef = registry.realCore();
        vm.prank(registry.ALLOCATOR());
        try realCoreRef.openSeries(p, S, J) returns (address seriesAddr) {
            registry.recordCall(this.openSeries.selector, false);
            registry.pushActive(
                seriesAddr,
                SeriesRegistry.SeriesInfo({
                    marketId: marketId, maturity: maturity, registeredAnOffer: false, lastBorrower: address(0)
                })
            );
            registry.recordFunded(S + J);
            _registerAndFillAtomically(seriesAddr, marketId, maturity, S + J);
        } catch {
            registry.recordCall(this.openSeries.selector, true);
        }
    }

    /// @dev Same fill-atomically pattern as AllocatorHandler._registerAndFillAtomically (registers one bid for
    /// roughly the whole allocation, has a synthetic borrower take it immediately) so real-core series reach a
    /// real fill without depending on a second independent random call to correlate within the run.
    function _registerAndFillAtomically(address seriesAddr, bytes32 marketId, uint256 maturity, uint256 kAlloc)
        internal
    {
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
        offer.group = keccak256(abi.encode("core-group", seriesAddr));
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

        address borrower = address(uint160(uint256(keccak256(abi.encode("core-initial-borrower", seriesAddr)))));
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
                SeriesRegistry.SeriesInfo({
                    marketId: marketId, maturity: maturity, registeredAnOffer: true, lastBorrower: borrower
                })
            );
            registry.setLastOffer(seriesAddr, offer, root);
        } catch {
            registry.updateInfo(
                seriesAddr,
                SeriesRegistry.SeriesInfo({
                    marketId: marketId, maturity: maturity, registeredAnOffer: true, lastBorrower: address(0)
                })
            );
            registry.setLastOffer(seriesAddr, offer, root);
        }
    }
}
