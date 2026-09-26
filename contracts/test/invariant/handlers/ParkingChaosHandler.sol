// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: fuzz handler that moves the parking venue underneath the protocol.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SeriesRegistryMorphoParking} from "./SeriesRegistryMorphoParking.sol";
import {MockMorphoVault} from "../../mocks/MockMorphoVault.sol";
import {morphoParking} from "../../../src/parking/morphoParking.sol";

contract ParkingChaosHandler is Test {
    SeriesRegistryMorphoParking public registry;

    uint256 public ghost_accrueCalls;
    uint256 public ghost_lossCalls;
    uint256 public ghost_crunchCalls;

    constructor(SeriesRegistryMorphoParking registry_) {
        registry = registry_;
    }

    function accrue(uint256 bpsSeed) external {
        MockMorphoVault vault = registry.morphoVault();
        vault.accrueBps(bound(bpsSeed, 0, 100));
        ghost_accrueCalls++;
    }

    function lose(uint256 seed) external {
        if (seed % 8 != 0) return;
        MockMorphoVault vault = registry.morphoVault();
        vault.loseBps(bound(seed >> 8, 1, 50));
        ghost_lossCalls++;
    }

    function setLiquidity(uint256 seed) external {
        MockMorphoVault vault = registry.morphoVault();
        uint256 mode = seed % 3;
        if (mode == 0) vault.setLiquidityCap(0);
        else if (mode == 1) vault.setLiquidityCap(bound(seed >> 8, 0, 2_000_000e6));
        else vault.setLiquidityCap(type(uint256).max);
        ghost_crunchCalls++;
    }

    function rebalance() external {
        morphoParking parking = registry.morphoParkingAdapter();
        try parking.rebalance() {} catch {}
    }

    function donate(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 0, 10_000e6);
        address parking = address(registry.morphoParkingAdapter());
        registry.usdc().mint(parking, amount);
    }
}
