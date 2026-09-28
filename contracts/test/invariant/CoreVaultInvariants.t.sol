// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: stateful invariant suite: the real core and both vaults, driven end to end.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {SeriesRegistry} from "./handlers/SeriesRegistry.sol";
import {CoreAllocatorHandler} from "./handlers/CoreAllocatorHandler.sol";
import {VaultHandler} from "./handlers/VaultHandler.sol";
import {EpochHandler} from "./handlers/EpochHandler.sol";
import {DeployHandler} from "./handlers/DeployHandler.sol";
import {MidnightChaosHandler} from "./handlers/MidnightChaosHandler.sol";
import {SettleHandler} from "./handlers/SettleHandler.sol";

import {seriesCore} from "../../src/core/seriesCore.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {usdcSeniorVault} from "../../src/vaults/senior/usdcSeniorVault.sol";
import {usdcJuniorVault} from "../../src/vaults/junior/usdcJuniorVault.sol";

contract CoreVaultInvariantsTest is Test {
    SeriesRegistry registry;
    CoreAllocatorHandler coreAllocatorHandler;
    VaultHandler vaultHandler;
    EpochHandler epochHandler;
    DeployHandler deployHandler;
    MidnightChaosHandler chaosHandler;
    SettleHandler settleHandler;

    function _newRegistry() internal virtual returns (SeriesRegistry) {
        return new SeriesRegistry();
    }

    function _addExtraTargets() internal virtual {}

    function setUp() public virtual {
        registry = _newRegistry();
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
        _addExtraTargets();

        vaultHandler.juniorRequestDeposit(0, 2_000_000e6);
        vaultHandler.curatorJuniorRequestDeposit(300_000e6);
        epochHandler.closeJuniorDepositEpoch();
        epochHandler.fulfillJuniorDeposit(1, type(uint128).max);
        epochHandler.claimJuniorDeposit(0, 1);
        usdcJuniorVault jvSeed = registry.juniorVault();
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

    function invariant_I15_coreBalanceReconciles() public view {
        seriesCore core = registry.realCore();
        (, uint256 seniorReserved,) = core.senior();
        (, uint256 juniorReserved, uint256 juniorPending) = core.junior();

        assertEq(
            registry.usdc().balanceOf(address(core)),
            seniorReserved + juniorReserved + juniorPending,
            "core's raw usdc balance must equal reserved assets (both books) plus junior pending deposits"
        );
        uint256 parked = registry.parking().totalAssets(address(core));
        uint256 booked = core.idle(true) + core.idle(false);
        assertLe(booked, parked, "the books must never claim more than the core's parking account holds");
        assertLe(parked - booked, 2, "the books must account for the whole parking account, up to rounding");
    }

    function invariant_I16_vaultAssetsEqualCoreBooks() public view {
        seriesCore core = registry.realCore();
        assertEq(
            registry.seniorVault().totalAssets(),
            core.seniorAssets(),
            "I16: srUSDC totalAssets must equal the senior book"
        );
        assertEq(
            registry.juniorVault().totalAssets(),
            core.juniorAssets(),
            "I16: jrUSDC totalAssets must equal the junior book"
        );
    }

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

    function invariant_I18_epochProRataSoundness() public view {
        usdcSeniorVault sv = registry.seniorVault();
        uint256 svOpen = sv.openEpochId();
        for (uint256 id = 1; id < svOpen; id++) {
            (uint256 totalShares,, uint256 sharesFulfilled, uint256 assetsFulfilled,,) = sv.epochs(id);
            assertLe(sharesFulfilled, totalShares, "senior redeem: sharesFulfilled must never exceed totalShares");
            assertLe(
                _sumClaimablePlusClaimedRedeemAssets(true, id, sharesFulfilled, totalShares),
                assetsFulfilled + _sumFrozenRedeemAssets(true, id),
                "senior redeem: claimable + already-claimed assets must never exceed assetsFulfilled"
            );
        }

        usdcJuniorVault jv = registry.juniorVault();
        uint256 jvRedeemOpen = jv.openRedeemEpochId();
        for (uint256 id = 1; id < jvRedeemOpen; id++) {
            (uint256 totalShares,, uint256 sharesFulfilled, uint256 assetsFulfilled,,) = jv.redeemEpochs(id);
            assertLe(sharesFulfilled, totalShares, "junior redeem: sharesFulfilled must never exceed totalShares");
            assertLe(
                _sumClaimablePlusClaimedRedeemAssets(false, id, sharesFulfilled, totalShares),
                assetsFulfilled + _sumFrozenRedeemAssets(false, id),
                "junior redeem: claimable + already-claimed assets must never exceed assetsFulfilled"
            );
        }

        uint256 jvDepositOpen = jv.openDepositEpochId();
        for (uint256 id = 1; id < jvDepositOpen; id++) {
            (uint256 totalAssets,, uint256 assetsFulfilled, uint256 sharesFulfilled,,) = jv.depositEpochs(id);
            assertLe(assetsFulfilled, totalAssets, "junior deposit: assetsFulfilled must never exceed totalAssets");
            assertLe(
                _sumClaimablePlusClaimedDepositShares(id, sharesFulfilled, totalAssets),
                sharesFulfilled + _sumFrozenDepositShares(id),
                "junior deposit: claimable + already-claimed shares must never exceed sharesFulfilled"
            );
        }
    }

    function invariant_I19_epochPricingDirection() public view {
        usdcSeniorVault sv = registry.seniorVault();
        for (uint256 id = 1; id < sv.openEpochId(); id++) {
            (,,, uint256 assetsFulfilled, uint256 ppsCloseWad,) = sv.epochs(id);
            _assertRedeemPriceWithinCeiling(
                assetsFulfilled + _sumFrozenRedeemAssets(true, id),
                _sharesFulfilledOf(sv, id) + _sumFrozenRedeemShares(true, id),
                ppsCloseWad,
                "senior redeem"
            );
        }

        usdcJuniorVault jv = registry.juniorVault();
        for (uint256 id = 1; id < jv.openRedeemEpochId(); id++) {
            (,, uint256 sharesFulfilled, uint256 assetsFulfilled, uint256 ppsCloseWad,) = jv.redeemEpochs(id);
            _assertRedeemPriceWithinCeiling(
                assetsFulfilled + _sumFrozenRedeemAssets(false, id),
                sharesFulfilled + _sumFrozenRedeemShares(false, id),
                ppsCloseWad,
                "junior redeem"
            );
        }

        for (uint256 id = 1; id < jv.openDepositEpochId(); id++) {
            (,, uint256 assetsFulfilled, uint256 sharesFulfilled, uint256 ppsCloseWad,) = jv.depositEpochs(id);
            uint256 batchShares = sharesFulfilled + _sumFrozenDepositShares(id);
            if (batchShares == 0) continue;
            _assertDepositPriceAboveFloor(assetsFulfilled + _sumFrozenDepositAssets(id), batchShares, ppsCloseWad);
        }
    }

    function invariant_I30_batchLedgerBalances() public view {
        usdcSeniorVault sv = registry.seniorVault();
        for (uint256 id = 1; id <= sv.openEpochId(); id++) {
            (uint256 total, uint256 remaining, uint256 filled,,,) = sv.epochs(id);
            assertEq(remaining, total - filled, "senior exit batch: remaining must equal requested minus filled");
        }
        usdcJuniorVault jv = registry.juniorVault();
        for (uint256 id = 1; id <= jv.openRedeemEpochId(); id++) {
            (uint256 total, uint256 remaining, uint256 filled,,,) = jv.redeemEpochs(id);
            assertEq(remaining, total - filled, "junior exit batch: remaining must equal requested minus filled");
        }
        for (uint256 id = 1; id <= jv.openDepositEpochId(); id++) {
            (uint256 total, uint256 remaining, uint256 filled,,,) = jv.depositEpochs(id);
            assertEq(remaining, total - filled, "junior entry batch: remaining must equal requested minus filled");
        }
    }

    function invariant_I31_fillsAreOldestFirst() public view {
        usdcSeniorVault sv = registry.seniorVault();
        uint256 ptr = sv.nextEpochToFill();
        for (uint256 id = 1; id < ptr; id++) {
            (, uint256 remaining,,,,) = sv.epochs(id);
            assertEq(remaining, 0, "senior exit: a batch behind the fill pointer is unfinished");
        }
        for (uint256 id = ptr + 1; id < sv.openEpochId(); id++) {
            (,, uint256 filled,,,) = sv.epochs(id);
            assertEq(filled, 0, "senior exit: a batch ahead of the oldest unfinished one was filled");
        }

        usdcJuniorVault jv = registry.juniorVault();
        ptr = jv.nextRedeemEpochToFill();
        for (uint256 id = 1; id < ptr; id++) {
            (, uint256 remaining,,,,) = jv.redeemEpochs(id);
            assertEq(remaining, 0, "junior exit: a batch behind the fill pointer is unfinished");
        }
        for (uint256 id = ptr + 1; id < jv.openRedeemEpochId(); id++) {
            (,, uint256 filled,,,) = jv.redeemEpochs(id);
            assertEq(filled, 0, "junior exit: a batch ahead of the oldest unfinished one was filled");
        }

        ptr = jv.nextDepositEpochToFill();
        for (uint256 id = 1; id < ptr; id++) {
            (, uint256 remaining,,,,) = jv.depositEpochs(id);
            assertEq(remaining, 0, "junior entry: a batch behind the fill pointer is unfinished");
        }
        for (uint256 id = ptr + 1; id < jv.openDepositEpochId(); id++) {
            (,, uint256 filled,,,) = jv.depositEpochs(id);
            assertEq(filled, 0, "junior entry: a batch ahead of the oldest unfinished one was filled");
        }
    }

    function invariant_I32_queuedExitDemandMatchesClosedBatches() public view {
        usdcSeniorVault sv = registry.seniorVault();
        uint256 expected;
        for (uint256 id = 1; id <= sv.openEpochId(); id++) {
            (, uint256 remaining,,, uint256 pps, bool closed) = sv.epochs(id);
            expected += _demandOf(remaining, pps, closed);
        }
        assertEq(sv.queuedExitAssets(), expected, "senior queued exit demand drifted from its closed batches");
        assertEq(registry.realCore().queuedExits(true), expected, "core must see the senior exit demand");

        usdcJuniorVault jv = registry.juniorVault();
        expected = 0;
        for (uint256 id = 1; id <= jv.openRedeemEpochId(); id++) {
            (, uint256 remaining,,, uint256 pps, bool closed) = jv.redeemEpochs(id);
            expected += _demandOf(remaining, pps, closed);
        }
        assertEq(jv.queuedExitAssets(), expected, "junior queued exit demand drifted from its closed batches");
        assertEq(registry.realCore().queuedExits(false), expected, "core must see the junior exit demand");
    }

    function invariant_I33_completedBatchLeavesNobodyPending() public view {
        usdcSeniorVault sv = registry.seniorVault();
        usdcJuniorVault jv = registry.juniorVault();
        uint256 count = vaultHandler.actorsCount();
        for (uint256 id = 1; id < sv.openEpochId(); id++) {
            (, uint256 remaining,,,,) = sv.epochs(id);
            if (remaining != 0) continue;
            for (uint256 i = 0; i < count; i++) {
                assertEq(
                    sv.pendingRedeemRequest(id, vaultHandler.actors(i)), 0, "senior exit: stranded in a done batch"
                );
            }
        }
        for (uint256 id = 1; id < jv.openRedeemEpochId(); id++) {
            (, uint256 remaining,,,,) = jv.redeemEpochs(id);
            if (remaining != 0) continue;
            for (uint256 i = 0; i < count; i++) {
                assertEq(
                    jv.pendingRedeemRequest(id, vaultHandler.actors(i)), 0, "junior exit: stranded in a done batch"
                );
            }
        }
        for (uint256 id = 1; id < jv.openDepositEpochId(); id++) {
            (, uint256 remaining,,,,) = jv.depositEpochs(id);
            if (remaining != 0) continue;
            for (uint256 i = 0; i < count; i++) {
                assertEq(
                    jv.pendingDepositRequest(id, vaultHandler.actors(i)), 0, "junior entry: stranded in a done batch"
                );
            }
        }
    }

    function invariant_I24_seriesCountsWithinCaps() public view {
        seriesCore core = registry.realCore();
        (,,,,,,,,, uint256 maxSeries, uint256 maxRecovering,,,,,,,,) = core.policy();
        assertLe(core.liveSeriesCount(), maxSeries, "liveSeries must never exceed maxSeries");
        assertLe(core.recoveringSeriesCount(), maxRecovering, "recoveringSeries must never exceed maxRecovering");
    }

    function invariant_seriesCustodyBoundToCoreParking() public view {
        seriesCore core = registry.realCore();
        address coreParking = address(core.PARKING());
        uint256 live = core.liveSeriesCount();
        for (uint256 i = 0; i < live; i++) {
            assertEq(
                address(creditSeries(core.liveSeries(i)).PARKING()), coreParking, "live series parks outside the core"
            );
        }
        uint256 recovering = core.recoveringSeriesCount();
        for (uint256 i = 0; i < recovering; i++) {
            assertEq(
                address(creditSeries(core.recoveringSeries(i)).PARKING()),
                coreParking,
                "recovering series parks outside the core"
            );
        }
    }

    function _sharesFulfilledOf(usdcSeniorVault sv, uint256 id) internal view returns (uint256 sharesFulfilled) {
        (,, sharesFulfilled,,,) = sv.epochs(id);
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

    function _sumUnclaimedRedeemAssets(bool isSenior) internal view returns (uint256 total) {
        uint256 count = vaultHandler.actorsCount();
        if (isSenior) {
            usdcSeniorVault sv = registry.seniorVault();
            for (uint256 id = 1; id < sv.openEpochId(); id++) {
                for (uint256 i = 0; i < count; i++) {
                    total += sv.owedRedeemAssets(id, vaultHandler.actors(i));
                }
            }
        } else {
            usdcJuniorVault jv = registry.juniorVault();
            for (uint256 id = 1; id < jv.openRedeemEpochId(); id++) {
                for (uint256 i = 0; i < count; i++) {
                    total += jv.owedRedeemAssets(id, vaultHandler.actors(i));
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
        sharesFulfilled;
        totalShares;
        uint256 count = vaultHandler.actorsCount();
        for (uint256 i = 0; i < count; i++) {
            address a = vaultHandler.actors(i);
            if (isSenior) {
                usdcSeniorVault sv = registry.seniorVault();
                total += sv.claimedAssets(id, a) + sv.owedRedeemAssets(id, a);
            } else {
                usdcJuniorVault jv = registry.juniorVault();
                total += jv.claimedAssets(id, a) + jv.owedRedeemAssets(id, a);
            }
        }
    }

    function _sumFrozenRedeemAssets(bool isSenior, uint256 id) internal view returns (uint256 total) {
        uint256 count = vaultHandler.actorsCount();
        for (uint256 i = 0; i < count; i++) {
            address a = vaultHandler.actors(i);
            total += isSenior
                ? registry.seniorVault().frozenAssets(id, a)
                : registry.juniorVault().frozenRedeemAssets(id, a);
        }
    }

    function _sumClaimablePlusClaimedDepositShares(uint256 id, uint256 sharesFulfilled, uint256 totalAssets)
        internal
        view
        returns (uint256 total)
    {
        sharesFulfilled;
        totalAssets;
        usdcJuniorVault jv = registry.juniorVault();
        uint256 count = vaultHandler.actorsCount();
        for (uint256 i = 0; i < count; i++) {
            address a = vaultHandler.actors(i);
            total += jv.claimedShares(id, a) + jv.owedDepositShares(id, a);
        }
    }

    function _sumFrozenDepositShares(uint256 id) internal view returns (uint256 total) {
        uint256 count = vaultHandler.actorsCount();
        for (uint256 i = 0; i < count; i++) {
            total += registry.juniorVault().frozenDepositShares(id, vaultHandler.actors(i));
        }
    }

    function _sumFrozenRedeemShares(bool isSenior, uint256 id) internal view returns (uint256 total) {
        uint256 count = vaultHandler.actorsCount();
        for (uint256 i = 0; i < count; i++) {
            address a = vaultHandler.actors(i);
            total += isSenior
                ? registry.seniorVault().frozenShares(id, a)
                : registry.juniorVault().frozenRedeemShares(id, a);
        }
    }

    function _sumFrozenDepositAssets(uint256 id) internal view returns (uint256 total) {
        uint256 count = vaultHandler.actorsCount();
        for (uint256 i = 0; i < count; i++) {
            total += registry.juniorVault().frozenDepositAssets(id, vaultHandler.actors(i));
        }
    }

    function _demandOf(uint256 remaining, uint256 ppsCloseWad, bool closed) internal pure returns (uint256) {
        return closed ? (remaining * ppsCloseWad + 1e18 - 1) / 1e18 : 0;
    }
}
