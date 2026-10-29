// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: book valuation and the gates built on it: capacity, idle floors, the stress gate, junior exits.
// @author adiii.eth

pragma solidity 0.8.34;

import {CoreParkingBooks} from "./CoreParkingBooks.sol";
import {CreditSeries} from "../../series/CreditSeries.sol";
import {SeriesState} from "../../interfaces/ISeries.sol";
import {IExitQueue} from "../../interfaces/IExitQueue.sol";
import {WadMath} from "../../libraries/WadMath.sol";

/// @notice Book values, capacity, the stress gate and exit limits.
abstract contract CoreValuation is CoreParkingBooks {
    using WadMath for uint256;

    /// @notice Number of live series.
    function liveSeriesCount() external view returns (uint256) {
        return liveSeries.length;
    }

    /// @notice Number of settled series still waiting on recoveries.
    function recoveringSeriesCount() external view returns (uint256) {
        return recoveringSeries.length;
    }

    /// @notice Senior book value: idle plus senior marks of every live series.
    function seniorAssets() public view returns (uint256 total) {
        total = idle(true);
        uint256 length = liveSeries.length;
        for (uint256 i = 0; i < length; i++) {
            (uint256 navS,,) = CreditSeries(liveSeries[i]).navs();
            total += navS;
        }
    }

    /// @notice Junior book value: idle plus junior marks of every live series.
    function juniorAssets() public view returns (uint256 total) {
        total = idle(false);
        uint256 length = liveSeries.length;
        for (uint256 i = 0; i < length; i++) {
            (, uint256 navJ,) = CreditSeries(liveSeries[i]).navs();
            total += navJ;
        }
    }

    /// @notice Senior book value after syncing every live series.
    function seniorAssetsSynced() external returns (uint256 total) {
        total = idle(true);
        uint256 length = liveSeries.length;
        for (uint256 i = 0; i < length; i++) {
            (uint256 navS,,) = CreditSeries(liveSeries[i]).navsSynced();
            total += navS;
        }
    }

    /// @notice Junior book value after syncing every live series.
    function juniorAssetsSynced() external returns (uint256 total) {
        total = idle(false);
        uint256 length = liveSeries.length;
        for (uint256 i = 0; i < length; i++) {
            (, uint256 navJ,) = CreditSeries(liveSeries[i]).navsSynced();
            total += navJ;
        }
    }

    /// @notice Largest senior book the current junior book can support.
    function seniorCapacity() public view returns (uint256) {
        return juniorAssets().mulDivDown(WAD - policy.covVaultWad, policy.covVaultWad);
    }

    /// @notice Idle cash of one book above its floor.
    function idleAvailable(bool isSenior) public view returns (uint256) {
        uint256 bookAssets = isSenior ? seniorAssets() : juniorAssets();
        uint256 floorWad = isSenior ? policy.minIdleSeniorWad : policy.minIdleJuniorWad;
        uint256 floor = bookAssets.mulDivDown(floorWad, WAD);
        uint256 idleNow = idle(isSenior);
        return idleNow > floor ? idleNow - floor : 0;
    }

    /// @notice Assets waiting in one vault's closed exit batches.
    function queuedExits(bool isSenior) public view returns (uint256) {
        address vault = isSenior ? seniorVault : juniorVault;
        return vault == address(0) ? 0 : IExitQueue(vault).queuedExitAssets();
    }

    /// @notice Idle cash a new series may use: above the floor and after queued exits.
    function idleDeployable(bool isSenior) public view returns (uint256) {
        uint256 available = idleAvailable(isSenior);
        uint256 queued = queuedExits(isSenior);
        return available > queued ? available - queued : 0;
    }

    /// @notice False while any live series' junior value is below the stress floor.
    function stressGateOpen() public view returns (bool) {
        uint256 length = liveSeries.length;
        for (uint256 i = 0; i < length; i++) {
            CreditSeries s = CreditSeries(liveSeries[i]);
            if (uint8(s.state()) == uint8(SeriesState.DEPLOYING)) continue;
            uint256 jD = s.juniorDeployed();
            if (jD == 0) continue;
            (, uint256 navJ,) = s.navs();
            if (navJ < jD.mulDivDown(policy.stressJuniorFloorWad, WAD)) return false;
        }

        uint256 recLength = recoveringSeries.length;
        for (uint256 i = 0; i < recLength; i++) {
            if (_hasWrittenOffCredit(CreditSeries(recoveringSeries[i]))) return false;
        }

        return true;
    }

    /// @notice Junior cash that can exit now without breaking the coverage floor.
    function juniorRedeemable() public view returns (uint256) {
        uint256 sA = seniorAssets();
        uint256 jA = juniorAssets();
        uint256 floorJ = sA.mulDivUp(policy.covVaultMinWad, WAD - policy.covVaultMinWad);
        if (jA <= floorJ) return 0;
        uint256 maxRedeemable = jA - floorJ;
        uint256 idleAvail = idle(false);
        uint256 cap = maxRedeemable < idleAvail ? maxRedeemable : idleAvail;
        uint256 liquid = parkingLiquidity();
        return cap < liquid ? cap : liquid;
    }

    function _hasWrittenOffCredit(CreditSeries s) internal view returns (bool) {
        bytes32[] memory ids = s.marketIds();
        for (uint256 i = 0; i < ids.length; i++) {
            if (s.writtenOff(i) && !s.resolved(i)) return true;
        }
        return false;
    }
}
