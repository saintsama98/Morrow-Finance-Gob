// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: stateful invariant suite for the series engine, run against the real Midnight contract.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {SeriesRegistry} from "./handlers/SeriesRegistry.sol";
import {AllocatorHandler} from "./handlers/AllocatorHandler.sol";
import {DeployHandler} from "./handlers/DeployHandler.sol";
import {MidnightChaosHandler} from "./handlers/MidnightChaosHandler.sol";
import {SettleHandler} from "./handlers/SettleHandler.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesState} from "../../src/interfaces/iSeries.sol";

contract SeriesInvariantsTest is Test {
    SeriesRegistry registry;
    AllocatorHandler allocatorHandler;
    DeployHandler deployHandler;
    MidnightChaosHandler chaosHandler;
    SettleHandler settleHandler;

    function setUp() public {
        registry = new SeriesRegistry();
        allocatorHandler = new AllocatorHandler(registry);
        deployHandler = new DeployHandler(registry);
        chaosHandler = new MidnightChaosHandler(registry);
        settleHandler = new SettleHandler(registry);

        targetContract(address(allocatorHandler));
        targetContract(address(deployHandler));
        targetContract(address(chaosHandler));
        targetContract(address(settleHandler));

        allocatorHandler.openSeries(0, 0);
        assertGt(registry.ghost_totalUnitsBought(), 0, "setUp seed fill did not land");
    }

    function invariant_I6_noResidualBalance() public view {
        uint256 count = registry.activeSeriesCount();
        for (uint256 k = 0; k < count; k++) {
            address seriesAddr = registry.activeSeries(k);
            assertEq(
                registry.usdc().balanceOf(seriesAddr), 0, "series must never hold a stray usdc balance between calls"
            );
        }
    }

    function invariant_I8_noDebtNoCollateral_onlySetterRatifierAuthorized() public view {
        uint256 count = registry.activeSeriesCount();
        for (uint256 k = 0; k < count; k++) {
            address seriesAddr = registry.activeSeries(k);
            (bytes32 marketId,,,) = registry.info(seriesAddr);

            assertEq(registry.midnight().debt(marketId, seriesAddr), 0, "a series must never hold midnight debt");
            assertTrue(
                registry.midnight().isAuthorized(seriesAddr, address(registry.setterRatifier())),
                "the setter ratifier must always be authorized"
            );
            assertFalse(
                registry.midnight().isAuthorized(seriesAddr, registry.ALLOCATOR()),
                "the allocator must never be authorized on midnight"
            );
            assertFalse(
                registry.midnight().isAuthorized(seriesAddr, address(registry.core())),
                "the core must never be authorized on midnight"
            );
        }
    }

    function invariant_I13_seniorNeverOverpaid() public view {
        uint256 count = registry.activeSeriesCount();
        for (uint256 k = 0; k < count; k++) {
            address seriesAddr = registry.activeSeries(k);
            creditSeries series = creditSeries(seriesAddr);
            if (
                uint8(series.state()) == uint8(SeriesState.DEPLOYING)
                    || uint8(series.state()) == uint8(SeriesState.LOCKED)
            ) {
                continue;
            }
            if (series.passThrough()) continue;

            assertLe(
                series.paidS(),
                series.seniorClaim(),
                "cumulative senior payout must never exceed the frozen senior claim"
            );
        }
    }

    function invariant_I11_writeOffTiming() public view {
        uint256 count = registry.activeSeriesCount();
        for (uint256 k = 0; k < count; k++) {
            address seriesAddr = registry.activeSeries(k);
            creditSeries series = creditSeries(seriesAddr);
            if (series.writtenOff(0)) {
                assertGe(
                    series.tSettled(), series.T() + series.D_WRITE_OFF(), "write-off must not happen before T + D_wo"
                );
            }
        }
    }

    function invariant_I14_stateMonotonicity() public {
        uint256 count = registry.activeSeriesCount();
        for (uint256 k = 0; k < count; k++) {
            address seriesAddr = registry.activeSeries(k);
            creditSeries series = creditSeries(seriesAddr);
            uint8 current = uint8(series.state());

            if (registry.ghost_seenState(seriesAddr)) {
                uint8 last = registry.ghost_lastState(seriesAddr);
                assertGe(current, last, "state must never move backward");
                if (last == uint8(SeriesState.SETTLED) || last == uint8(SeriesState.CANCELED)) {
                    assertEq(current, last, "a terminal state must never change again");
                }
            }
            (uint256 credit,,) = registry.midnight()
                .updatePositionView(registry.marketFor(_maturityOf(seriesAddr)), _marketIdOf(seriesAddr), seriesAddr);
            registry.setGhostSnapshot(seriesAddr, credit, current);
        }
    }

    function invariant_I7_creditOnlyGrowsInDeploying() public view {
        uint256 count = registry.activeSeriesCount();
        for (uint256 k = 0; k < count; k++) {
            address seriesAddr = registry.activeSeries(k);
            creditSeries series = creditSeries(seriesAddr);
            if (!registry.ghost_seenState(seriesAddr)) continue;
            if (uint8(series.state()) == uint8(SeriesState.DEPLOYING)) continue;

            (uint256 creditNow,,) = registry.midnight()
                .updatePositionView(registry.marketFor(_maturityOf(seriesAddr)), _marketIdOf(seriesAddr), seriesAddr);
            assertLe(creditNow, registry.ghost_lastCredit(seriesAddr), "credit must not increase outside DEPLOYING");
        }
    }

    function invariant_I3_navsSyncedMatchesNavs() public {
        uint256 count = registry.activeSeriesCount();
        for (uint256 k = 0; k < count; k++) {
            address seriesAddr = registry.activeSeries(k);
            creditSeries series = creditSeries(seriesAddr);

            (uint256 navS, uint256 navJ, uint256 fee) = series.navs();
            (uint256 navSSynced, uint256 navJSynced, uint256 feeSynced) = series.navsSynced();

            assertEq(navS, navSSynced, "navsSynced must match navs (sync only affects midnight's own storage)");
            assertEq(navJ, navJSynced, "navsSynced must match navs (sync only affects midnight's own storage)");
            assertEq(fee, feeSynced, "navsSynced must match navs (sync only affects midnight's own storage)");
        }
    }

    function afterInvariant() public view {
        assertGt(registry.ghost_totalUnitsBought(), 0, "no run ever produced a real fill");
    }

    function _maturityOf(address seriesAddr) internal view returns (uint256 maturity) {
        (, maturity,,) = registry.info(seriesAddr);
    }

    function _marketIdOf(address seriesAddr) internal view returns (bytes32 marketId) {
        (marketId,,,) = registry.info(seriesAddr);
    }
}
