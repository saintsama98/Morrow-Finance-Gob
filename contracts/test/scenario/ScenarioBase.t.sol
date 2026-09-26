// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: shared deterministic scenario harness.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Midnight} from "@morpho-org/midnight/src/Midnight.sol";
import {Market, Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {HashLib} from "@morpho-org/midnight/src/ratifiers/libraries/HashLib.sol";
import {TickLib} from "@morpho-org/midnight/src/libraries/TickLib.sol";
import {UtilsLib} from "@morpho-org/midnight/src/libraries/UtilsLib.sol";
import {ORACLE_PRICE_SCALE} from "@morpho-org/midnight/src/libraries/ConstantsLib.sol";

import {SeriesRegistry} from "../invariant/handlers/SeriesRegistry.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesParams} from "../../src/interfaces/iSeries.sol";
import {seriesCore} from "../../src/core/seriesCore.sol";
import {usdcSeniorVault} from "../../src/vaults/senior/usdcSeniorVault.sol";
import {usdcJuniorVault} from "../../src/vaults/junior/usdcJuniorVault.sol";
import {iParking} from "../../src/parking/iParking.sol";
import {wadMath} from "../../src/libraries/wadMath.sol";

abstract contract ScenarioBase is Test {
    using wadMath for uint256;

    uint256 internal constant WAD = 1e18;

    SeriesRegistry registry;
    seriesCore core;
    usdcSeniorVault seniorVault;
    usdcJuniorVault juniorVault;
    MockUSDC usdc;

    function setUp() public virtual {
        registry = new SeriesRegistry();
        core = registry.realCore();
        seniorVault = registry.seniorVault();
        juniorVault = registry.juniorVault();
        usdc = registry.usdc();
    }

    function _seniorDeposit(address who, uint256 assets) internal returns (uint256 shares) {
        usdc.mint(who, assets);
        vm.startPrank(who);
        usdc.approve(address(seniorVault), assets);
        shares = seniorVault.deposit(assets, who);
        vm.stopPrank();
    }

    function _juniorDeposit(address who, uint256 assets) internal returns (uint256 shares) {
        usdc.mint(who, assets);
        vm.startPrank(who);
        usdc.approve(address(juniorVault), assets);
        uint256 epochId = juniorVault.requestDeposit(assets, who, who);
        vm.stopPrank();

        vm.prank(registry.CURATOR());
        juniorVault.closeDepositEpoch();
        vm.prank(registry.CURATOR());
        juniorVault.fulfillDeposit(epochId, assets);

        vm.prank(who);
        shares = juniorVault.claimDeposit(epochId);
    }

    function _openSeries(uint256 S, uint256 J, uint256 maturity)
        internal
        returns (address seriesAddr, bytes32 marketId)
    {
        return _openSeriesWithTheta(S, J, maturity, 0.1e18);
    }

    function _openSeriesWithTheta(uint256 S, uint256 J, uint256 maturity, uint256 thetaWad)
        internal
        returns (address seriesAddr, bytes32 marketId)
    {
        Market memory market = registry.marketFor(maturity);
        registry.midnight().touchMarket(market);
        marketId = registry.idOf(market);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = marketId;
        uint256[] memory rateFloors = new uint256[](1);
        rateFloors[0] = 0.005e18;
        uint256[] memory caps = new uint256[](1);
        caps[0] = S + J;

        SeriesParams memory p = SeriesParams({
            marketIds: ids,
            tDeployEnd: uint64(block.timestamp + 2 days),
            dWriteOff: uint64(7 days),
            covWad: 0.15e18,
            pi0Wad: 0.1e18,
            piTWad: 0.2e18,
            pi1Wad: 0.35e18,
            rateFloorWad: rateFloors,
            marketCapAssets: caps,
            kMinAssets: 50_000e6,
            thetaWad: thetaWad,
            feeRecipient: registry.FEE_RECIPIENT(),
            allocator: registry.ALLOCATOR(),
            parking: iParking(address(registry.parking())),
            offchainAttestationHash: bytes32(0)
        });

        vm.prank(registry.ALLOCATOR());
        seriesAddr = core.openSeries(p, S, J);
    }

    function _registerAndFill(address seriesAddr, uint256 maturity, uint256 units, address borrower)
        internal
        returns (uint256 price)
    {
        creditSeries series = creditSeries(seriesAddr);
        uint256 tick = series.tickMaxFor(0);
        price = TickLib.tickToPrice(tick);

        Offer memory offer;
        offer.market = registry.marketFor(maturity);
        offer.buy = true;
        offer.maker = seriesAddr;
        offer.expiry = series.T_DEPLOY_END();
        offer.tick = tick;
        offer.group = keccak256(abi.encode("scenario-group", seriesAddr, units));
        offer.callback = seriesAddr;
        offer.callbackData = abi.encode(uint256(0));
        offer.ratifier = address(registry.setterRatifier());
        offer.maxAssets = uint128(units.mulDivUp(price, WAD) + 1000e6);
        offer.continuousFeeCap = type(uint256).max;

        Offer[] memory leaves = new Offer[](1);
        leaves[0] = offer;
        bytes32 root = HashLib.hashOffer(offer);

        vm.prank(registry.ALLOCATOR());
        series.registerOffers(root, leaves);

        address collateralTokenAddr = registry.collateralToken();
        uint256 oraclePrice = registry.oracle().price();
        uint256 collateral = units.mulDivUp(WAD, registry.LLTV()).mulDivUp(ORACLE_PRICE_SCALE, oraclePrice);
        MockUSDC(collateralTokenAddr).mint(borrower, collateral);

        vm.startPrank(borrower);
        MockUSDC(collateralTokenAddr).approve(address(registry.midnight()), collateral);
        registry.midnight().supplyCollateral(offer.market, 0, collateral, borrower);
        vm.stopPrank();

        bytes memory ratifierData = abi.encode(root, uint256(0), new bytes32[](0));
        Midnight midnight = registry.midnight();
        vm.prank(borrower);
        midnight.take(offer, ratifierData, units, borrower, borrower, address(0), "");
    }

    function _finalize(address seriesAddr) internal {
        vm.prank(registry.ALLOCATOR());
        creditSeries(seriesAddr).finalize();
    }

    function _cancel(address seriesAddr) internal {
        vm.prank(registry.ALLOCATOR());
        creditSeries(seriesAddr).cancel();
    }

    function _crashOracle(uint256 dropBps) internal {
        uint256 initial = 1e36 * 60_000;
        uint256 newPrice = initial - initial.mulDivDown(dropBps, 10_000);
        registry.oracle().setPrice(newPrice);
    }

    function _restoreOracle() internal {
        registry.oracle().setPrice(1e36 * 60_000);
    }

    function _liquidate(uint256 maturity, address borrower) internal {
        Midnight midnight = registry.midnight();
        midnight.liquidate(registry.marketFor(maturity), 0, 0, 0, borrower, false, address(this), address(0), "");
    }

    function _liquidateOverdue(uint256 maturity, address borrower) internal {
        Midnight midnight = registry.midnight();
        midnight.liquidate(registry.marketFor(maturity), 0, 0, 0, borrower, true, address(this), address(0), "");
    }

    function _liquidateOverdueFull(uint256 maturity, address borrower) internal returns (uint256 repaidUnits) {
        Midnight midnight = registry.midnight();
        Market memory market = registry.marketFor(maturity);
        bytes32 marketId = registry.idOf(market);
        repaidUnits = uint256(midnight.debt(marketId, borrower));
        usdc.mint(address(this), repaidUnits);
        usdc.approve(address(midnight), repaidUnits);
        midnight.liquidate(market, 0, 0, repaidUnits, borrower, true, address(this), address(0), "");
    }

    function _repay(uint256 maturity, address borrower, uint256 units) internal {
        Midnight midnight = registry.midnight();
        usdc.mint(borrower, units);
        vm.startPrank(borrower);
        usdc.approve(address(midnight), units);
        midnight.repay(registry.marketFor(maturity), units, borrower, address(0), "");
        vm.stopPrank();
    }

    function _debtOf(bytes32 marketId, address borrower) internal view returns (uint256) {
        return uint256(registry.midnight().debt(marketId, borrower));
    }

    function _marketIdOf(creditSeries series) internal view returns (bytes32) {
        return series.marketIds()[0];
    }
}
