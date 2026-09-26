// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the full core-and-vault invariant suite, run with idle cash earning in a Morpho vault.
// @author adiii.eth

pragma solidity 0.8.34;

import {CoreVaultInvariantsTest} from "./CoreVaultInvariants.t.sol";
import {SeriesRegistry} from "./handlers/SeriesRegistry.sol";
import {SeriesRegistryMorphoParking} from "./handlers/SeriesRegistryMorphoParking.sol";
import {ParkingChaosHandler} from "./handlers/ParkingChaosHandler.sol";
import {morphoParking} from "../../src/parking/morphoParking.sol";
import {seriesCore} from "../../src/core/seriesCore.sol";

contract CoreVaultInvariantsMorphoTest is CoreVaultInvariantsTest {
    ParkingChaosHandler parkingChaosHandler;

    function _newRegistry() internal override returns (SeriesRegistry) {
        return new SeriesRegistryMorphoParking();
    }

    function _addExtraTargets() internal override {
        parkingChaosHandler = new ParkingChaosHandler(SeriesRegistryMorphoParking(address(registry)));
        targetContract(address(parkingChaosHandler));
    }

    function _parking() internal view returns (morphoParking) {
        return SeriesRegistryMorphoParking(address(registry)).morphoParkingAdapter();
    }

    function invariant_parkingShareLedgerIsExact() public view {
        morphoParking parking = _parking();
        seriesCore core = registry.realCore();
        uint256 sum = parking.sharesOf(address(core));
        uint256 n = registry.everSeriesCount();
        for (uint256 i = 0; i < n; i++) {
            sum += parking.sharesOf(registry.everSeries(i));
        }
        assertEq(sum, parking.totalShares(), "every adapter share must belong to the core or a funded series");
    }

    function invariant_parkingAccountsNeverExceedPool() public view {
        morphoParking parking = _parking();
        seriesCore core = registry.realCore();
        uint256 claimed = parking.totalAssets(address(core));
        uint256 n = registry.everSeriesCount();
        for (uint256 i = 0; i < n; i++) {
            claimed += parking.totalAssets(registry.everSeries(i));
        }
        assertLe(claimed, parking.poolAssets(), "accounts can never be worth more than the pool holds");
    }
}
