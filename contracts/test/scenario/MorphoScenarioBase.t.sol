// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: scenario harness with idle cash in a yield-bearing parking venue (a mock Morpho vault by default).
// @author adiii.eth

pragma solidity 0.8.34;

import {Vm} from "forge-std/Test.sol";
import {Midnight} from "@morpho-org/midnight/src/Midnight.sol";
import {Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {HashLib} from "@morpho-org/midnight/src/ratifiers/libraries/HashLib.sol";
import {TickLib} from "@morpho-org/midnight/src/libraries/TickLib.sol";
import {ORACLE_PRICE_SCALE} from "@morpho-org/midnight/src/libraries/ConstantsLib.sol";

import {ScenarioBase} from "./ScenarioBase.t.sol";
import {SeriesRegistry} from "../invariant/handlers/SeriesRegistry.sol";
import {SeriesRegistryMorphoParking} from "../invariant/handlers/SeriesRegistryMorphoParking.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {wadMath} from "../../src/libraries/wadMath.sol";

interface iVenueKnobs {
    function accrueBps(uint256 bps) external;
    function loseBps(uint256 bps) external;
    function setLiquidityCap(uint256 cap) external;
}

interface iParkingView {
    function totalAssets(address account) external view returns (uint256);
    function maxWithdraw(address account) external view returns (uint256);
    function liquidity() external view returns (uint256);
}

abstract contract MorphoScenarioBase is ScenarioBase {
    using wadMath for uint256;

    iVenueKnobs vault;
    iParkingView mparking;

    function _newVenueRegistry() internal virtual returns (SeriesRegistry reg, address knobs, address adapter) {
        SeriesRegistryMorphoParking r = new SeriesRegistryMorphoParking();
        return (r, address(r.morphoVault()), address(r.morphoParkingAdapter()));
    }

    function setUp() public virtual override {
        (SeriesRegistry reg, address knobs, address adapter) = _newVenueRegistry();
        registry = reg;
        core = registry.realCore();
        seniorVault = registry.seniorVault();
        juniorVault = registry.juniorVault();
        usdc = registry.usdc();
        vault = iVenueKnobs(knobs);
        mparking = iParkingView(adapter);
    }

    function _registerBid(address seriesAddr, uint256 maturity, uint256 units, address borrower)
        internal
        returns (Offer memory offer, bytes memory ratifierData)
    {
        creditSeries series = creditSeries(seriesAddr);
        uint256 tick = series.tickMaxFor(0);
        uint256 price = TickLib.tickToPrice(tick);

        offer.market = registry.marketFor(maturity);
        offer.buy = true;
        offer.maker = seriesAddr;
        offer.expiry = series.T_DEPLOY_END();
        offer.tick = tick;
        offer.group = keccak256(abi.encode("morpho-scenario-group", seriesAddr, units));
        offer.callback = seriesAddr;
        offer.callbackData = abi.encode(uint256(0));
        offer.ratifier = address(registry.setterRatifier());
        offer.maxAssets = uint128(units.mulDivUp(price, 1e18) + 1000e6);
        offer.continuousFeeCap = type(uint256).max;

        Offer[] memory leaves = new Offer[](1);
        leaves[0] = offer;
        bytes32 root = HashLib.hashOffer(offer);
        vm.prank(registry.ALLOCATOR());
        series.registerOffers(root, leaves);

        address collateralTokenAddr = registry.collateralToken();
        uint256 collateral =
            units.mulDivUp(1e18, registry.LLTV()).mulDivUp(ORACLE_PRICE_SCALE, registry.oracle().price());
        MockUSDC(collateralTokenAddr).mint(borrower, collateral);
        Midnight midnight = registry.midnight();
        vm.startPrank(borrower);
        MockUSDC(collateralTokenAddr).approve(address(midnight), collateral);
        midnight.supplyCollateral(offer.market, 0, collateral, borrower);
        vm.stopPrank();

        ratifierData = abi.encode(root, uint256(0), new bytes32[](0));
    }

    function _take(Offer memory offer, bytes memory ratifierData, uint256 units, address borrower) internal {
        Midnight midnight = registry.midnight();
        vm.prank(borrower);
        midnight.take(offer, ratifierData, units, borrower, borrower, address(0), "");
    }

    function _decodeReturnReceived() internal returns (uint256 toSenior, uint256 toJunior) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("ReturnReceived(address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                return abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        revert("ReturnReceived not found");
    }

    function _assertBooksReconcile() internal view {
        uint256 parked = mparking.totalAssets(address(core));
        uint256 booked = core.idle(true) + core.idle(false);
        assertLe(booked, parked, "books never claim more than the core's parking account");
        assertLe(parked - booked, 2, "books account for the whole parking account, up to rounding");
    }
}
