// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: stateful invariant suite for the series engine, run against the real Midnight contract.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test, Vm} from "forge-std/Test.sol";

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

    function invariant_I1_I2_syncMatchesProtocolAndBuffer() public {
        bytes32 bufferTopic = keccak256("BufferUpdated(uint256,uint256,uint256,int256,uint256)");
        uint256 count = registry.activeSeriesCount();
        for (uint256 k = 0; k < count; k++) {
            address seriesAddr = registry.activeSeries(k);
            creditSeries series = creditSeries(seriesAddr);
            bytes32 marketId = _marketIdOf(seriesAddr);

            vm.recordLogs();
            series.sync(0);
            Vm.Log[] memory logs = vm.getRecordedLogs();

            (uint128 viewCredit, uint128 viewPendingFee,) = registry.midnight()
                .updatePositionView(registry.marketFor(_maturityOf(seriesAddr)), marketId, seriesAddr);
            assertEq(
                registry.midnight().credit(marketId, seriesAddr),
                viewCredit,
                "I1: after sync the protocol's stored credit must equal the live credit"
            );

            uint256 faceNet = uint256(viewCredit) - uint256(viewPendingFee) + series.collected(0);
            int256 expectedBuffer = int256(faceNet) - int256(series.seniorClaim());
            bool seen;
            for (uint256 j = 0; j < logs.length; j++) {
                if (logs[j].emitter != seriesAddr || logs[j].topics[0] != bufferTopic) continue;
                (uint256 credit, uint256 faceNetAtT, int256 buffer,) =
                    abi.decode(logs[j].data, (uint256, uint256, int256, uint256));
                assertEq(credit, viewCredit, "I2: reported credit must equal the protocol credit");
                assertEq(faceNetAtT, faceNet, "I2: reported face must equal credit - pendingFee + collected");
                assertEq(buffer, expectedBuffer, "I2: reported buffer must equal face minus the senior claim");
                seen = true;
            }
            assertTrue(seen, "I2: sync must report the buffer");
        }
    }

    function invariant_I10_I13_waterfallConservesAndIsSeniorFirst() public view {
        uint256 count = registry.activeSeriesCount();
        for (uint256 k = 0; k < count; k++) {
            address seriesAddr = registry.activeSeries(k);
            creditSeries series = creditSeries(seriesAddr);
            if (uint8(series.state()) != uint8(SeriesState.SETTLED)) continue;

            uint256 proceeds = _proceedsOf(series);
            assertEq(
                series.paidS() + series.paidJ() + series.feeAccounted(),
                proceeds,
                "I10: senior + junior + fee must equal cumulative proceeds after every waterfall run"
            );
            if (!series.passThrough()) {
                uint256 claim = series.seniorClaim();
                assertEq(
                    series.paidS(),
                    proceeds < claim ? proceeds : claim,
                    "I13: cumulative senior payout must equal min(senior claim, proceeds)"
                );
            }
        }
    }

    function invariant_I29_proceedsNeverDecrease() public {
        uint256 count = registry.activeSeriesCount();
        for (uint256 k = 0; k < count; k++) {
            address seriesAddr = registry.activeSeries(k);
            creditSeries series = creditSeries(seriesAddr);
            uint8 st = uint8(series.state());
            if (st == uint8(SeriesState.DEPLOYING) || st == uint8(SeriesState.CANCELED)) continue;

            uint256 proceeds = _proceedsOf(series);
            assertGe(proceeds, registry.ghost_lastProceeds(seriesAddr), "I29: cumulative proceeds must never decrease");
            registry.setGhostProceeds(seriesAddr, proceeds);
        }
    }

    function _proceedsOf(creditSeries series) internal view returns (uint256) {
        return registry.usdc().balanceOf(address(series)) + registry.parking().totalAssets(address(series))
            + series.paidS() + series.paidJ() + series.feeClaimed();
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
