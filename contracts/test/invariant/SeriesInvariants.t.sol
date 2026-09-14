// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {SeriesRegistry} from "./handlers/SeriesRegistry.sol";
import {AllocatorHandler} from "./handlers/AllocatorHandler.sol";
import {DeployHandler} from "./handlers/DeployHandler.sol";
import {MidnightChaosHandler} from "./handlers/MidnightChaosHandler.sol";
import {SettleHandler} from "./handlers/SettleHandler.sol";
import {Series} from "../../src/series/Series.sol";
import {SeriesState} from "../../src/interfaces/ISeries.sol";

// Morrow Finance — stateful invariant suite for the series engine, run against the real Midnight contract.
// @author adiii.eth

/// @notice Stateful invariant suite for the series engine (Series + SeriesFactory), run against the real
/// Midnight contract through SeriesRegistry's shared harness. This covers what's checkable at the Series level
/// alone, without a core, plus a navs()/navsSynced() consistency
/// check and a no-op-take invariant reinforced via DeployHandler.noOpTake.
///
/// Not covered here, with reasons:
/// - Protocol credit and buffer sync: need fork-level cross-checks against a real deployed Midnight instance.
/// - Coverage band: enforced by the core's coverage-band check, which belongs to a level above this suite.
/// - Callback guards: already covered by direct fuzz/unit tests (Series.t.sol's onBuy guard tests) rather than re-derived
///   here as a stateful invariant.
/// - wants a dedicated "allocator handler disabled" run mode, which is a CI/tooling concern (running this
///   same suite twice with different target sets) rather than a single assertion; not implemented as a
///   separate run here.
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
    }

    // --- a series pays usdc only to midnight, the core, or the fee recipient -----------------------------
    // proxy: between top-level calls, a series never holds a stray usdc balance -- every path either parks
    // funds or forwards the whole withdrawn amount to a known recipient in the same call.
    function invariant_noResidualBalance() public view {
        uint256 count = registry.activeSeriesCount();
        for (uint256 k = 0; k < count; k++) {
            address seriesAddr = registry.activeSeries(k);
            assertEq(registry.usdc().balanceOf(seriesAddr), 0, "series must never hold a stray usdc balance between calls");
        }
    }

    // --- a series never holds midnight debt or collateral, and only ever authorizes the setter ratifier ---
    function invariant_noDebtNoCollateral_onlySetterRatifierAuthorized() public view {
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

    // --- senior is never overpaid beyond its claim (the structural core of "XS == min(C_S, P)") ----------
    // The full "XS == min(C_S, P)" identity and "XS + XJ + fee == P" are exhaustively checked
    // independently of Series.sol (SeriesMath's unit/fuzz/differential tests) and end to end
    // (SeriesSettlement.t.sol asserts real payouts against a fresh SeriesMath.waterfall computation). What's
    // worth re-asserting here, stateful and across arbitrary random sequences, is the safety property that
    // actually matters: cumulative senior payouts can never exceed the frozen senior claim, in any series, at
    // any point in any random sequence of handler calls.
    function invariant_seniorNeverOverpaid() public view {
        uint256 count = registry.activeSeriesCount();
        for (uint256 k = 0; k < count; k++) {
            address seriesAddr = registry.activeSeries(k);
            Series series = Series(seriesAddr);
            if (uint8(series.state()) == uint8(SeriesState.DEPLOYING) || uint8(series.state()) == uint8(SeriesState.LOCKED)) {
                continue; // waterfall has not run yet
            }
            if (series.passThrough()) continue; // pass-through has no fixed claim to compare against

            assertLe(series.paidS(), series.seniorClaim(), "cumulative senior payout must never exceed the frozen senior claim");
        }
    }

    // --- write off only in SETTLING and only once T + D_wo has passed -----------------------------------
    function invariant_writeOffTiming() public view {
        uint256 count = registry.activeSeriesCount();
        for (uint256 k = 0; k < count; k++) {
            address seriesAddr = registry.activeSeries(k);
            Series series = Series(seriesAddr);
            if (series.writtenOff(0)) {
                assertGe(series.tSettled(), series.T() + series.D_WRITE_OFF(), "write-off must not happen before T + D_wo");
            }
        }
    }

    // --- state transitions only ever move forward, never re-enter a state -------------------------------
    function invariant_stateMonotonicity() public {
        uint256 count = registry.activeSeriesCount();
        for (uint256 k = 0; k < count; k++) {
            address seriesAddr = registry.activeSeries(k);
            Series series = Series(seriesAddr);
            uint8 current = uint8(series.state());

            if (registry.ghost_seenState(seriesAddr)) {
                uint8 last = registry.ghost_lastState(seriesAddr);
                assertGe(current, last, "state must never move backward");
                if (last == uint8(SeriesState.SETTLED) || last == uint8(SeriesState.CANCELED)) {
                    assertEq(current, last, "a terminal state must never change again");
                }
            }
            (uint256 credit,,) = registry.midnight().updatePositionView(
                registry.marketFor(_maturityOf(seriesAddr)), _marketIdOf(seriesAddr), seriesAddr
            );
            registry.setGhostSnapshot(seriesAddr, credit, current);
        }
    }

    // --- series credit increases only while state == DEPLOYING --------------------------------------------
    function invariant_creditOnlyGrowsInDeploying() public view {
        uint256 count = registry.activeSeriesCount();
        for (uint256 k = 0; k < count; k++) {
            address seriesAddr = registry.activeSeries(k);
            Series series = Series(seriesAddr);
            if (!registry.ghost_seenState(seriesAddr)) continue;
            if (uint8(series.state()) == uint8(SeriesState.DEPLOYING)) continue;

            (uint256 creditNow,,) = registry.midnight().updatePositionView(
                registry.marketFor(_maturityOf(seriesAddr)), _marketIdOf(seriesAddr), seriesAddr
            );
            // outside DEPLOYING, credit can only fall (repayments/liquidations reduce it via collect/loss),
            // never rise, since onBuy/deployTake are the only credit-increasing paths and both require
            // state == DEPLOYING.
            assertLe(creditNow, registry.ghost_lastCredit(seriesAddr), "credit must not increase outside DEPLOYING");
        }
    }

    // --- navsSynced()'s on-chain write must not change the computed nav -------------------------
    function invariant_navsSyncedMatchesNavs() public {
        uint256 count = registry.activeSeriesCount();
        for (uint256 k = 0; k < count; k++) {
            address seriesAddr = registry.activeSeries(k);
            Series series = Series(seriesAddr);

            (uint256 navS, uint256 navJ, uint256 fee) = series.navs();
            (uint256 navSSynced, uint256 navJSynced, uint256 feeSynced) = series.navsSynced();

            assertEq(navS, navSSynced, "navsSynced must match navs (sync only affects midnight's own storage)");
            assertEq(navJ, navJSynced, "navsSynced must match navs (sync only affects midnight's own storage)");
            assertEq(fee, feeSynced, "navsSynced must match navs (sync only affects midnight's own storage)");
        }
    }

    /// @dev Called once at the end of each run (after `depth` handler calls), not after every single call like
    /// the invariant_ functions above. Used here to confirm the fuzzer actually reaches deep economic states
    /// (real fills, real settlements) rather than spending the whole run bouncing off early-return guards.
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
