// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {SeriesRegistry} from "./handlers/SeriesRegistry.sol";
import {CoreAllocatorHandler} from "./handlers/CoreAllocatorHandler.sol";
import {VaultHandler} from "./handlers/VaultHandler.sol";
import {EpochHandler} from "./handlers/EpochHandler.sol";
import {DeployHandler} from "./handlers/DeployHandler.sol";
import {MidnightChaosHandler} from "./handlers/MidnightChaosHandler.sol";
import {SettleHandler} from "./handlers/SettleHandler.sol";

import {SeriesCore} from "../../src/core/SeriesCore.sol";
import {SeniorVault} from "../../src/vaults/SeniorVault.sol";
import {JuniorVault} from "../../src/vaults/JuniorVault.sol";
import {EpochMath} from "../../src/libraries/EpochMath.sol";

// Morrow Finance — M8 stateful invariant suite: the real SeriesCore and both vaults, driven end to end.
// @author adiii.eth

/// @notice Extends the M4 series-engine suite (SeriesInvariants.t.sol, run against a stub core) up to the real
/// SeriesCore and both vaults: I15-I23 from section 26. Reuses DeployHandler, MidnightChaosHandler and
/// SettleHandler UNMODIFIED (they operate purely on `Series` picked from the shared registry and never touch
/// the core), swapping only the allocator-side handler for one (CoreAllocatorHandler) that opens series through
/// the real `SeriesCore.openSeries`, funded from whatever VaultHandler/EpochHandler have actually deposited.
///
/// I16 and I23 were originally on this deferred list (real implementation gaps found while building this
/// suite, not testing conveniences) and have since been closed:
/// - I16: `SeniorVault.totalAssets()` / `JuniorVault.totalAssets()` now exist, each reading straight through to
///   `core.seniorAssets()` / `core.juniorAssets()`.
/// - I23: `JuniorVault.requestRedeem` now reverts if the caller is the curator and it would take their balance
///   below `curatorMinShareWad` of supply (build spec section 20.8's exact wording: "curator requestRedeem
///   reverts if it would take the curator below curatorMinShareWad"). Deliberately narrow, per spec: this
///   guards only the curator's own `requestRedeem`, not deposits by other holders (which dilute the curator's
///   percentage but are not blocked -- blocking them would cap total junior TVL at curator's own holding,
///   which is not this design's intent) and not a plain ERC20 `transfer` of the curator's jrUSDC (not
///   mentioned by the spec at that section). curatorJuniorRequestDeposit/curatorJuniorRequestRedeemAttempt in
///   VaultHandler exercise both directions.
///
/// Still deferred, with reasons:
/// - I24's `maxOpenEpochsPerController` clause: not modeled as a policy field at all (unlike `maxSeries` /
///   `maxRecovering`, which this suite does check). The `liveSeries`/`recoveringSeries` bound is asserted below;
///   the per-controller open-epoch cap is not, because there is nothing in the vaults to assert against.
/// - I25 (backstop off => no cross-series loss leakage): needs a second run configuration with the backstop
///   disabled; left for the next slice rather than mixed into this one.
/// - I27 (adapter realAssets): needs AdapterHandler / a vault v2 fork, out of scope until M10.
contract CoreVaultInvariantsTest is Test {
    SeriesRegistry registry;
    CoreAllocatorHandler coreAllocatorHandler;
    VaultHandler vaultHandler;
    EpochHandler epochHandler;
    DeployHandler deployHandler;
    MidnightChaosHandler chaosHandler;
    SettleHandler settleHandler;

    function setUp() public {
        registry = new SeriesRegistry();
        coreAllocatorHandler = new CoreAllocatorHandler(registry);
        vaultHandler = new VaultHandler(registry);
        epochHandler = new EpochHandler(registry);
        deployHandler = new DeployHandler(registry);
        chaosHandler = new MidnightChaosHandler(registry);
        settleHandler = new SettleHandler(registry);

        targetContract(address(coreAllocatorHandler));
        targetContract(address(vaultHandler));
        targetContract(address(epochHandler));
        targetContract(address(deployHandler));
        targetContract(address(chaosHandler));
        targetContract(address(settleHandler));

        // Seed a real starting state: a junior deposit taken through its full epoch (request -> close ->
        // fulfill -> claim, since junior capital only becomes book cash at fulfillDeposit) BEFORE any senior
        // deposit -- SeriesCore.seniorCapacity() is derived from juniorAssets(), so a senior deposit attempted
        // against an empty junior book reverts with CapacityExceeded. The curator deposits 300k alongside
        // actor(0)'s 2m in the same epoch, landing at 300k / 2.3m =~ 13% of supply -- comfortably above the 10%
        // curatorMinShareWad floor, with real margin for curatorJuniorRequestRedeemAttempt to explore both a
        // successful partial redemption and a reverted one that would breach the floor. Then a senior deposit,
        // then one real series opened and filled through the real core. Same rationale as SeriesInvariantsTest's
        // seed: every fuzz run starts from a state that has actually reached the economic layer, instead of
        // depending on random calls happening to land in the right order first.
        vaultHandler.juniorRequestDeposit(0, 2_000_000e6);
        vaultHandler.curatorJuniorRequestDeposit(300_000e6);
        epochHandler.closeJuniorDepositEpoch();
        epochHandler.fulfillJuniorDeposit(1, type(uint128).max);
        epochHandler.claimJuniorDeposit(0, 1);
        JuniorVault jvSeed = registry.juniorVault(); // resolve BEFORE the prank -- see the repeated gotcha noted
        // throughout the handlers: registry.juniorVault() is itself an external call and would otherwise
        // consume the prank below, leaving claimDeposit called as this test contract instead of the curator.
        vm.prank(registry.CURATOR());
        jvSeed.claimDeposit(1);
        vaultHandler.seniorDeposit(0, 2_000_000e6);
        coreAllocatorHandler.openSeries(0, 0);

        assertGt(registry.ghost_totalUnitsBought(), 0, "setUp seed fill (real core path) did not land");
        assertGt(registry.seniorVault().totalSupply(), 0, "setUp seed senior deposit did not land");
        assertGt(registry.juniorVault().totalSupply(), 0, "setUp seed junior deposit did not land");
        assertGt(
            registry.juniorVault().balanceOf(registry.CURATOR()), 0, "setUp seed curator junior deposit did not land"
        );
    }

    // --- I15: core usdc balance and parking balance reconcile against the books ---------------------------------

    function invariant_I15_coreBalanceReconciles() public view {
        SeriesCore core = registry.realCore();
        (uint256 seniorShares, uint256 seniorReserved,) = core.senior();
        (uint256 juniorShares, uint256 juniorReserved, uint256 juniorPending) = core.junior();

        assertEq(
            registry.usdc().balanceOf(address(core)),
            seniorReserved + juniorReserved + juniorPending,
            "core's raw usdc balance must equal reserved assets (both books) plus junior pending deposits"
        );
        assertEq(
            registry.parking().totalAssets(address(core)),
            seniorShares + juniorShares,
            "the parking adapter's balance for the core must equal the sum of both books' tracked parking shares"
        );
    }

    // --- I17: reserved assets always cover what redeemers have already been promised but not yet claimed --------

    function invariant_I17_reservedCoversUnclaimed() public view {
        (, uint256 seniorReserved,) = registry.realCore().senior();
        assertGe(
            seniorReserved,
            _sumUnclaimedRedeemAssets(true),
            "senior reserved assets must cover every unclaimed-but-fulfilled senior redemption"
        );

        (, uint256 juniorReserved,) = registry.realCore().junior();
        assertGe(
            juniorReserved,
            _sumUnclaimedRedeemAssets(false),
            "junior reserved assets must cover every unclaimed-but-fulfilled junior redemption"
        );
    }

    // --- I18: per-epoch pro-rata soundness on all three tracks ----------------------------------------------------

    function invariant_I18_epochProRataSoundness() public view {
        SeniorVault sv = registry.seniorVault();
        uint256 svOpen = sv.openEpochId();
        for (uint256 id = 1; id < svOpen; id++) {
            (uint256 totalShares, uint256 sharesFulfilled, uint256 assetsFulfilled,,) = sv.epochs(id);
            assertLe(sharesFulfilled, totalShares, "senior redeem: sharesFulfilled must never exceed totalShares");
            assertLe(
                _sumClaimablePlusClaimedRedeemAssets(true, id, sharesFulfilled, totalShares),
                assetsFulfilled,
                "senior redeem: claimable + already-claimed assets must never exceed assetsFulfilled"
            );
        }

        JuniorVault jv = registry.juniorVault();
        uint256 jvRedeemOpen = jv.openRedeemEpochId();
        for (uint256 id = 1; id < jvRedeemOpen; id++) {
            (uint256 totalShares, uint256 sharesFulfilled, uint256 assetsFulfilled,,) = jv.redeemEpochs(id);
            assertLe(sharesFulfilled, totalShares, "junior redeem: sharesFulfilled must never exceed totalShares");
            assertLe(
                _sumClaimablePlusClaimedRedeemAssets(false, id, sharesFulfilled, totalShares),
                assetsFulfilled,
                "junior redeem: claimable + already-claimed assets must never exceed assetsFulfilled"
            );
        }

        uint256 jvDepositOpen = jv.openDepositEpochId();
        for (uint256 id = 1; id < jvDepositOpen; id++) {
            (uint256 totalAssets, uint256 assetsFulfilled, uint256 sharesFulfilled,,) = jv.depositEpochs(id);
            assertLe(assetsFulfilled, totalAssets, "junior deposit: assetsFulfilled must never exceed totalAssets");
            assertLe(
                _sumClaimablePlusClaimedDepositShares(id, sharesFulfilled, totalAssets),
                sharesFulfilled,
                "junior deposit: claimable + already-claimed shares must never exceed sharesFulfilled"
            );
        }
    }

    // --- I19: redemption fulfillment never escapes a loss, junior deposit fulfillment never captures a jump -----

    function invariant_I19_epochPricingDirection() public view {
        SeniorVault sv = registry.seniorVault();
        for (uint256 id = 1; id < sv.openEpochId(); id++) {
            (,, uint256 assetsFulfilled, uint256 ppsCloseWad,) = sv.epochs(id);
            _assertRedeemPriceWithinCeiling(assetsFulfilled, _sharesFulfilledOf(sv, id), ppsCloseWad, "senior redeem");
        }

        JuniorVault jv = registry.juniorVault();
        for (uint256 id = 1; id < jv.openRedeemEpochId(); id++) {
            (uint256 totalShares, uint256 sharesFulfilled, uint256 assetsFulfilled, uint256 ppsCloseWad,) =
                jv.redeemEpochs(id);
            totalShares; // silence unused-var warning; kept for readability of the destructure
            _assertRedeemPriceWithinCeiling(assetsFulfilled, sharesFulfilled, ppsCloseWad, "junior redeem");
        }

        for (uint256 id = 1; id < jv.openDepositEpochId(); id++) {
            (, uint256 assetsFulfilled, uint256 sharesFulfilled, uint256 ppsCloseWad,) = jv.depositEpochs(id);
            if (sharesFulfilled == 0) continue;
            _assertDepositPriceAboveFloor(assetsFulfilled, sharesFulfilled, ppsCloseWad);
        }
    }

    // I20 and I21 are NOT standing invariants: both are point-in-time gates the spec itself scopes to "after
    // any X" (a deposit, a redemption fulfillment), not properties the book is required to maintain at rest
    // afterward. An initial attempt at asserting them unconditionally here found two real, reproducible
    // sequences where they read false between calls for reasons unrelated to any bug:
    //   - I20: a junior redemption (unrelated to any senior action) shrinks juniorAssets(), which shrinks
    //     seniorCapacity() below an already-admitted senior book. SeniorVault.deposit only checks capacity at
    //     the moment of that deposit; nothing re-validates it afterward, by design.
    //   - I21: the curator can raise covVaultMinWad (a policy action) with no re-check against the existing
    //     book, which can leave prior coverage below the new floor with no redemption having done anything
    //     wrong. juniorRedeemable() only guarantees a *fulfillment* cannot itself breach the floor at the time
    //     it runs.
    // Both are now asserted where the spec actually scopes them: VaultHandler.seniorDeposit (I20, right after a
    // successful deposit) and EpochHandler.fulfillJuniorRedeem (I21, right after a successful fulfillment).

    // --- I24 (partial): loop-bounded collections never exceed their configured caps ---------------------------------

    function invariant_I24_seriesCountsWithinCaps() public view {
        SeriesCore core = registry.realCore();
        (,,,,,,,,, uint256 maxSeries, uint256 maxRecovering,,,,,,,,) = core.policy();
        assertLe(core.liveSeriesCount(), maxSeries, "liveSeries must never exceed maxSeries");
        assertLe(core.recoveringSeriesCount(), maxRecovering, "recoveringSeries must never exceed maxRecovering");
    }

    // --- helpers ---------------------------------------------------------------------------------------------------

    function _sharesFulfilledOf(SeniorVault sv, uint256 id) internal view returns (uint256 sharesFulfilled) {
        (, sharesFulfilled,,,) = sv.epochs(id);
    }

    function _assertRedeemPriceWithinCeiling(
        uint256 assetsFulfilled,
        uint256 sharesFulfilled,
        uint256 ppsCloseWad,
        string memory label
    ) internal pure {
        if (sharesFulfilled == 0) return;
        uint256 impliedPriceWad = assetsFulfilled * 1e18 / sharesFulfilled;
        assertLe(
            impliedPriceWad,
            ppsCloseWad,
            string.concat(label, ": cumulative fulfillment price must never exceed the epoch's close price")
        );
    }

    function _assertDepositPriceAboveFloor(uint256 assetsFulfilled, uint256 sharesFulfilled, uint256 ppsCloseWad)
        internal
        pure
    {
        uint256 impliedPriceWad = assetsFulfilled * 1e18 / sharesFulfilled;
        assertGe(
            impliedPriceWad,
            ppsCloseWad,
            "junior deposit: cumulative fulfillment price must never fall below the epoch's close price"
        );
    }

    /// @dev Sum, across the fixed actor set, of each actor's still-unclaimed entitlement from every closed
    /// redeem epoch of one vault (senior if `isSenior`, else junior's redeem track).
    function _sumUnclaimedRedeemAssets(bool isSenior) internal view returns (uint256 total) {
        uint256 count = vaultHandler.actorsCount();
        if (isSenior) {
            SeniorVault sv = registry.seniorVault();
            for (uint256 id = 1; id < sv.openEpochId(); id++) {
                (uint256 totalShares,, uint256 assetsFulfilled,,) = sv.epochs(id);
                for (uint256 i = 0; i < count; i++) {
                    address a = vaultHandler.actors(i);
                    total += EpochMath.claimableAssets(
                        sv.requestedShares(id, a), assetsFulfilled, totalShares, sv.claimedAssets(id, a)
                    );
                }
            }
        } else {
            JuniorVault jv = registry.juniorVault();
            for (uint256 id = 1; id < jv.openRedeemEpochId(); id++) {
                (uint256 totalShares,, uint256 assetsFulfilled,,) = jv.redeemEpochs(id);
                for (uint256 i = 0; i < count; i++) {
                    address a = vaultHandler.actors(i);
                    total += EpochMath.claimableAssets(
                        jv.requestedShares(id, a), assetsFulfilled, totalShares, jv.claimedAssets(id, a)
                    );
                }
            }
        }
    }

    function _sumClaimablePlusClaimedRedeemAssets(
        bool isSenior,
        uint256 id,
        uint256 sharesFulfilled,
        uint256 totalShares
    ) internal view returns (uint256 total) {
        sharesFulfilled; // included in the signature for readability at call sites; not needed directly here
        uint256 count = vaultHandler.actorsCount();
        if (isSenior) {
            SeniorVault sv = registry.seniorVault();
            (,, uint256 assetsFulfilled,,) = sv.epochs(id);
            for (uint256 i = 0; i < count; i++) {
                address a = vaultHandler.actors(i);
                uint256 claimed = sv.claimedAssets(id, a);
                total += claimed
                    + EpochMath.claimableAssets(sv.requestedShares(id, a), assetsFulfilled, totalShares, claimed);
            }
        } else {
            JuniorVault jv = registry.juniorVault();
            (,, uint256 assetsFulfilled,,) = jv.redeemEpochs(id);
            for (uint256 i = 0; i < count; i++) {
                address a = vaultHandler.actors(i);
                uint256 claimed = jv.claimedAssets(id, a);
                total += claimed
                    + EpochMath.claimableAssets(jv.requestedShares(id, a), assetsFulfilled, totalShares, claimed);
            }
        }
    }

    function _sumClaimablePlusClaimedDepositShares(uint256 id, uint256 sharesFulfilled, uint256 totalAssets)
        internal
        view
        returns (uint256 total)
    {
        sharesFulfilled;
        JuniorVault jv = registry.juniorVault();
        (,, uint256 epochSharesFulfilled,,) = jv.depositEpochs(id);
        uint256 count = vaultHandler.actorsCount();
        for (uint256 i = 0; i < count; i++) {
            address a = vaultHandler.actors(i);
            uint256 claimed = jv.claimedShares(id, a);
            total += claimed
                + EpochMath.claimableShares(jv.requestedAssets(id, a), epochSharesFulfilled, totalAssets, claimed);
        }
    }
}
