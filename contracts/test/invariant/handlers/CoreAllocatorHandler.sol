// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: invariant-suite handler that opens series through the REAL seriesCore, not the stub.
// @author adiii.eth

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
import {creditSeries} from "../../../src/series/creditSeries.sol";
import {SeriesParams} from "../../../src/interfaces/iSeries.sol";
import {iParking} from "../../../src/parking/iParking.sol";
import {seriesCore} from "../../../src/core/seriesCore.sol";

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
        if (seniorAvail < 50_000e6 || juniorAvail < 50_000e6) return;

        uint256 S = bound(sSeed, 50_000e6, seniorAvail);
        uint256 aWad = bound(jSeed, 0.15e18, 0.3e18);
        uint256 J = S.mulDivUp(aWad, WAD - aWad);
        if (J > juniorAvail) J = juniorAvail;
        if (J < 1000e6) return;

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
            parking: iParking(address(registry.parking())),
            offchainAttestationHash: bytes32(0)
        });

        seriesCore realCoreRef = registry.realCore();
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

    function _registerAndFillAtomically(address seriesAddr, bytes32 marketId, uint256 maturity, uint256 kAlloc)
        internal
    {
        creditSeries series = creditSeries(seriesAddr);
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
