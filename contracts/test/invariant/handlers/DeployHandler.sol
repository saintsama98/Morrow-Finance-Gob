// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: invariant-suite handler for borrower fills against live series bids.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {Midnight} from "@morpho-org/midnight/src/Midnight.sol";
import {TickLib} from "@morpho-org/midnight/src/libraries/TickLib.sol";
import {UtilsLib} from "@morpho-org/midnight/src/libraries/UtilsLib.sol";
import {ORACLE_PRICE_SCALE} from "@morpho-org/midnight/src/libraries/ConstantsLib.sol";

import {SeriesRegistry} from "./SeriesRegistry.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {creditSeries} from "../../../src/series/creditSeries.sol";
import {SeriesState} from "../../../src/interfaces/iSeries.sol";

contract DeployHandler is Test {
    using UtilsLib for uint256;

    uint256 internal constant WAD = 1e18;
    SeriesRegistry public registry;

    constructor(SeriesRegistry registry_) {
        registry = registry_;
    }

    function borrowerTakesBid(uint256 seriesSeed, uint256 unitsSeed, uint256 borrowerSeed) external {
        (address seriesAddr,) = registry.pickActiveWithOffer(seriesSeed, true);
        if (seriesAddr == address(0)) return;

        creditSeries series = creditSeries(seriesAddr);
        if (uint8(series.state()) != uint8(SeriesState.DEPLOYING)) return;
        if (block.timestamp > series.T_DEPLOY_END()) return;

        Offer memory offer = registry.getLastOffer(seriesAddr);
        bytes32 root = registry.lastOfferRoot(seriesAddr);

        uint256 price = TickLib.tickToPrice(offer.tick);
        if (price == 0) return;

        uint256 kAlloc = series.seniorAllocated() + series.juniorAllocated();
        uint256 totalFilled = series.totalFilled();
        if (totalFilled >= kAlloc) return;
        uint256 maxUnitsByAlloc = (kAlloc - totalFilled).mulDivDown(WAD, price);
        uint256 filled0 = series.filled(0);
        uint256 maxUnitsByCap =
            offer.maxAssets > filled0 ? uint256(offer.maxAssets - filled0).mulDivDown(WAD, price) : 0;
        uint256 cap = maxUnitsByCap < maxUnitsByAlloc ? maxUnitsByCap : maxUnitsByAlloc;
        if (cap < 100e6) return;
        uint256 units = bound(unitsSeed, 100e6, cap);

        address borrower = address(uint160(uint256(keccak256(abi.encode("borrower", seriesAddr, borrowerSeed)))));

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
            registry.recordCall(this.borrowerTakesBid.selector, false);
            registry.recordUnitsBought(units);
            (bytes32 marketId, uint256 maturity,,) = registry.info(seriesAddr);
            registry.updateInfo(
                seriesAddr,
                SeriesRegistry.SeriesInfo({
                    marketId: marketId, maturity: maturity, registeredAnOffer: true, lastBorrower: borrower
                })
            );
        } catch {
            registry.recordCall(this.borrowerTakesBid.selector, true);
        }
    }

    function noOpTake(uint256 seriesSeed) external {
        (address seriesAddr,) = registry.pickActiveWithOffer(seriesSeed, true);
        if (seriesAddr == address(0)) return;

        Offer memory offer = registry.getLastOffer(seriesAddr);
        bytes32 root = registry.lastOfferRoot(seriesAddr);
        bytes memory ratifierData = abi.encode(root, uint256(0), new bytes32[](0));
        Midnight midnight = registry.midnight();

        address caller = address(uint160(uint256(keccak256(abi.encode("nooptaker", seriesSeed)))));
        vm.prank(caller);
        try midnight.take(offer, ratifierData, uint256(0), caller, caller, address(0), "") {
            registry.recordCall(this.noOpTake.selector, false);
        } catch {
            registry.recordCall(this.noOpTake.selector, true);
        }
    }

    function warp(uint256 seed) external {
        if (seed % 5 == 0) {
            uint256 bigDelta = bound(seed, 3 days, 10 days);
            vm.warp(block.timestamp + bigDelta);
        } else {
            uint256 smallDelta = bound(seed, 10 minutes, 2 hours);
            vm.warp(block.timestamp + smallDelta);
        }
    }
}
