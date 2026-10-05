// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the full core-and-vault invariant suite, run with idle cash lent directly in a Morpho Blue market.
// @author adiii.eth

pragma solidity 0.8.34;

import {CoreVaultInvariantsTest} from "./CoreVaultInvariants.t.sol";
import {SeriesRegistry} from "./handlers/SeriesRegistry.sol";
import {SeriesRegistryBlueParking} from "./handlers/SeriesRegistryBlueParking.sol";
import {BlueParkingChaosHandler} from "./handlers/BlueParkingChaosHandler.sol";
import {blueParking} from "../../src/parking/blueParking.sol";
import {seriesCore} from "../../src/core/seriesCore.sol";

contract CoreVaultInvariantsBlueTest is CoreVaultInvariantsTest {
    BlueParkingChaosHandler blueChaosHandler;

    function _newRegistry() internal override returns (SeriesRegistry) {
        return new SeriesRegistryBlueParking();
    }

    function _addExtraTargets() internal override {
        blueChaosHandler = new BlueParkingChaosHandler(SeriesRegistryBlueParking(address(registry)));
        targetContract(address(blueChaosHandler));
    }

    function _parking() internal view returns (blueParking) {
        return SeriesRegistryBlueParking(address(registry)).blueParkingAdapter();
    }

    function invariant_parkingShareLedgerIsExact() public view {
        blueParking parking = _parking();
        seriesCore core = registry.realCore();
        uint256 sum = parking.sharesOf(address(core));
        uint256 n = registry.everSeriesCount();
        for (uint256 i = 0; i < n; i++) {
            sum += parking.sharesOf(registry.everSeries(i));
        }
        assertEq(sum, parking.totalShares(), "every adapter share must belong to the core or a funded series");
    }

    function invariant_parkingAccountsNeverExceedPool() public view {
        blueParking parking = _parking();
        seriesCore core = registry.realCore();
        uint256 claimed = parking.totalAssets(address(core));
        uint256 n = registry.everSeriesCount();
        for (uint256 i = 0; i < n; i++) {
            claimed += parking.totalAssets(registry.everSeries(i));
        }
        assertLe(claimed, parking.poolAssets(), "accounts can never be worth more than the pool holds");
    }

    function invariant_blueSharesBackedByTheMarketPosition() public view {
        SeriesRegistryBlueParking r = SeriesRegistryBlueParking(address(registry));
        blueParking parking = _parking();
        assertLe(
            parking.blueShares(),
            r.blue().supplyShares(parking.MARKET_ID(), address(parking)),
            "the adapter never counts more Blue shares than the market records for it"
        );
    }

    function invariant_parkingLossIsJuniorFirst() public view {
        assertEq(
            blueChaosHandler.ghost_seniorHitWhileJuniorCovered(),
            0,
            "a parking loss never reached senior idle while junior idle covered it"
        );
    }

    function test_regression_largeBookParkingLoss_seniorIdleUnchangedWhileJuniorCovers() public {
        blueChaosHandler.donateToBlue(21983602980621659843988992692125077870630);
        blueChaosHandler.accrue(86400);
        blueChaosHandler.donateToBlue(2348302563);
        blueChaosHandler.accrue(13120211386482);
        vaultHandler.seniorDeposit(28085433376986347436298358732545982264764897040, type(uint256).max);
        blueChaosHandler.accrue(653870745696717150668088106537726371166801147117796303658688043475450291);
        blueChaosHandler.lose(2792);
        assertGt(blueChaosHandler.ghost_lossCalls(), 0, "the loss step ran");
        assertEq(blueChaosHandler.ghost_seniorHitWhileJuniorCovered(), 0, "senior idle held through the loss");
    }
}
