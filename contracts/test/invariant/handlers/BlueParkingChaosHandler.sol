// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: fuzz handler that moves the Morpho Blue market underneath blueParking.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SeriesRegistryBlueParking, BlueVenueKnobs} from "./SeriesRegistryBlueParking.sol";
import {seriesCore} from "../../../src/core/seriesCore.sol";
import {blueParking} from "../../../src/parking/blueParking.sol";

contract BlueParkingChaosHandler is Test {
    SeriesRegistryBlueParking public registry;

    uint256 public ghost_accrueCalls;
    uint256 public ghost_lossCalls;
    uint256 public ghost_crunchCalls;
    uint256 public ghost_seniorHitWhileJuniorCovered;
    uint256 public ghost_exitCalls;

    constructor(SeriesRegistryBlueParking registry_) {
        registry = registry_;
    }

    function accrue(uint256 bpsSeed) external {
        registry.knobs().accrueBps(bound(bpsSeed, 0, 100));
        ghost_accrueCalls++;
    }

    function lose(uint256 seed) external {
        if (seed % 8 != 0) return;
        seriesCore core = registry.realCore();
        core.syncAll();
        blueParking parking = registry.blueParkingAdapter();
        uint256 parkedBefore = parking.totalAssets(address(core));
        uint256 seniorBefore = core.idle(true);
        uint256 juniorBefore = core.idle(false);
        registry.knobs().loseBps(bound(seed >> 8, 1, 50));
        uint256 parkedAfter = parking.totalAssets(address(core));
        uint256 coreLoss = parkedBefore > parkedAfter ? parkedBefore - parkedAfter : 0;
        if (juniorBefore > coreLoss + 2 && core.idle(true) + 2 < seniorBefore) ghost_seniorHitWhileJuniorCovered++;
        ghost_lossCalls++;
    }

    function setLiquidity(uint256 seed) external {
        BlueVenueKnobs knobs = registry.knobs();
        uint256 mode = seed % 3;
        if (mode == 0) knobs.setLiquidityCap(0);
        else if (mode == 1) knobs.setLiquidityCap(bound(seed >> 8, 0, 2_000_000e6));
        else knobs.setLiquidityCap(type(uint256).max);
        ghost_crunchCalls++;
    }

    function rebalance() external {
        try registry.blueParkingAdapter().rebalance() {} catch {}
    }

    function donate(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 0, 10_000e6);
        registry.usdc().mint(address(registry.blueParkingAdapter()), amount);
    }

    function donateToBlue(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 10_000e6);
        blueParking parking = registry.blueParkingAdapter();
        registry.usdc().mint(address(this), amount);
        registry.usdc().approve(address(registry.blue()), amount);
        registry.blue().supply(parking.marketParams(), amount, 0, address(parking), "");
    }

    function exitToCash(uint256 seed) external {
        if (seed % 1009 != 509) return;
        vm.prank(registry.SENTINEL());
        try registry.blueParkingAdapter().exitToCash() {} catch {}
        ghost_exitCalls++;
    }
}
