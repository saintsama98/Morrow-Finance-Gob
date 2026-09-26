// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: a series' live marks: face ledger, realized loss and the senior/junior NAV split.
// @author adiii.eth

pragma solidity 0.8.34;

import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {seriesStorage} from "./seriesStorage.sol";
import {SeriesState} from "../../interfaces/iSeries.sol";
import {wadMath} from "../../libraries/wadMath.sol";
import {seriesMath} from "../../libraries/seriesMath.sol";

abstract contract seriesMarks is seriesStorage {
    using wadMath for uint256;

    function sync(uint256 i) external {
        MIDNIGHT.updatePosition(_markets[i], address(this));

        uint256 fNetNow = _faceNetNow();
        int256 bufferAtT = int256(fNetNow) - int256(seniorClaim);
        uint256 lossAtT = _faceLossNow();
        (uint128 creditI,,) = MIDNIGHT.updatePositionView(_markets[i], _marketIds[i], address(this));

        emit BufferUpdated(i, creditI, fNetNow, bufferAtT, lossAtT);
    }

    function navs() external view returns (uint256 navS, uint256 navJ, uint256 feeAccrued) {
        return _navs();
    }

    function navsSynced() external returns (uint256 navS, uint256 navJ, uint256 feeAccrued) {
        uint256 length = _marketIds.length;
        for (uint256 i = 0; i < length; i++) {
            MIDNIGHT.updatePosition(_markets[i], address(this));
        }
        return _navs();
    }

    function marketIds() external view returns (bytes32[] memory) {
        return _marketIds;
    }

    function markets() external view returns (Market[] memory) {
        return _markets;
    }

    function _faceNetNow() internal view returns (uint256 fNetNow) {
        uint256 length = _marketIds.length;
        for (uint256 i = 0; i < length; i++) {
            (uint128 credit, uint128 pendingFee,) =
                MIDNIGHT.updatePositionView(_markets[i], _marketIds[i], address(this));
            fNetNow += (uint256(credit) - uint256(pendingFee)) + collected[i];
        }
    }

    function _faceLossNow() internal view returns (uint256) {
        uint256 fNetNow = _faceNetNow();
        return faceNetAtFinalize > fNetNow ? faceNetAtFinalize - fNetNow : 0;
    }

    function _navs() internal view returns (uint256 navS, uint256 navJ, uint256 feeAccrued) {
        if (state == SeriesState.DEPLOYING) {
            uint256 kAlloc = seniorAllocated + juniorAllocated;
            if (kAlloc == 0) return (0, 0, 0);
            uint256 value = PARKING.totalAssets(address(this)) + totalFilled;
            uint256 aWad = juniorAllocated.wDivDown(kAlloc);
            navS = value.mulDivDown(wadMath.WAD - aWad, wadMath.WAD);
            navJ = value - navS;
            return (navS, navJ, 0);
        }

        if (state == SeriesState.SETTLED || state == SeriesState.CANCELED) {
            return (0, 0, 0);
        }

        uint256 tau = T > tFinalize ? T - tFinalize : 0;
        uint256 elapsed = state == SeriesState.SETTLING ? tau : block.timestamp - tFinalize;
        uint256 faceLoss = _faceLossNow();

        if (passThrough) {
            uint256 s = elapsed > tau ? tau : elapsed;
            uint256 accretion = (tau > 0 && faceNetAtFinalize >= totalFilled)
                ? (faceNetAtFinalize - totalFilled).mulDivDown(s, tau)
                : 0;
            uint256 grossV = totalFilled + accretion;
            uint256 v = grossV > faceLoss ? grossV - faceLoss : 0;
            (navS, navJ) = seriesMath.navPassThrough(v, seniorDeployed, totalFilled);
            return (navS, navJ, 0);
        }

        return seriesMath.nav(
            elapsed,
            tau,
            totalFilled,
            faceNetAtFinalize,
            faceLoss,
            seniorDeployed,
            seniorClaim,
            juniorDeployed,
            THETA_WAD
        );
    }
}
