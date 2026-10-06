// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: a series' funding window: taking the allocation, canceling, and locking the deal at finalize.
// @author adiii.eth

pragma solidity 0.8.34;

import {ERC20Lib} from "@morpho-org/midnight/src/periphery/libraries/ERC20Lib.sol";
import {seriesDeployment} from "./seriesDeployment.sol";
import {iSeriesCoreMinimal} from "../../interfaces/iSeriesCoreMinimal.sol";
import {iErc20Like} from "../../interfaces/iErc20Like.sol";
import {SeriesState} from "../../interfaces/iSeries.sol";
import {wadMath} from "../../libraries/wadMath.sol";
import {premiumCurve} from "../../libraries/premiumCurve.sol";
import {seriesMath} from "../../libraries/seriesMath.sol";

/// @notice Funding, cancellation and finalize of a series.
abstract contract seriesFunding is seriesDeployment {
    using wadMath for uint256;

    /// @notice Records the senior and junior allocations moved in by the core.
    function initialize(uint256 seniorAllocated_, uint256 juniorAllocated_) external inState(SeriesState.DEPLOYING) {
        require(msg.sender == CORE, NotCoreOrSentinel());

        uint256 kAlloc = seniorAllocated_ + juniorAllocated_;
        uint256 sumCaps;
        uint256 length = _marketCapAssets.length;
        for (uint256 i = 0; i < length; i++) {
            sumCaps += _marketCapAssets[i];
        }
        require(sumCaps >= kAlloc, CapacityBelowAllocation());

        seniorAllocated = seniorAllocated_;
        juniorAllocated = juniorAllocated_;

        require(PARKING.totalAssets(address(this)) >= kAlloc, InsufficientCash());

        emit Initialized(seniorAllocated_, juniorAllocated_);
    }

    /// @notice Cancels a series with no fills; allocator or sentinel.
    function cancel() external nonReentrant inState(SeriesState.DEPLOYING) {
        require(msg.sender == ALLOCATOR || msg.sender == iSeriesCoreMinimal(CORE).sentinel(), NotCoreOrSentinel());
        require(totalFilled == 0, AlreadyFilled());

        state = SeriesState.CANCELED;
        _returnAllCashToCore();
    }

    /// @notice Prices the senior claim and returns undeployed cash; allocator any time, anyone after the window.
    function finalize() external nonReentrant inState(SeriesState.DEPLOYING) {
        require(msg.sender == ALLOCATOR || block.timestamp > T_DEPLOY_END, NotAllocator());

        uint256 kD = totalFilled;
        if (kD == 0) {
            state = SeriesState.CANCELED;
            _returnAllCashToCore();
            return;
        }

        passThrough = kD < K_MIN_ASSETS;

        uint256 length = _marketIds.length;
        uint256 fGross;
        uint256 fNet;
        for (uint256 i = 0; i < length; i++) {
            fGross += unitsBought[i];
            fNet += unitsBought[i] - feeCrystallized[i];
        }
        faceGross = fGross;
        faceNetAtFinalize = fNet;

        uint256 kAlloc = seniorAllocated + juniorAllocated;
        uint256 aWad = juniorAllocated.wDivDown(kAlloc);
        juniorShareWad = aWad;
        utilizationWad = COV_WAD.wDivUp(aWad);
        premiumWad = premiumCurve.pi(utilizationWad, U_T_WAD, PI0_WAD, PIT_WAD, PI1_WAD);

        seriesMath.PricingResult memory r = seriesMath.price(kD, aWad, fNet, premiumWad);
        seniorDeployed = r.seniorDeployed;
        juniorDeployed = r.juniorDeployed;
        poolRateWad = r.poolRateWad;
        seniorRateWad = r.seniorRateWad;
        seniorClaim = r.seniorClaim;
        attachmentWad = r.attachmentWad;
        negativeCarry = r.negativeCarry;

        uint256 returnS = seniorAllocated - r.seniorDeployed;
        uint256 returnJ = juniorAllocated - r.juniorDeployed;

        _sweepRaw();
        uint256 balance = PARKING.totalAssets(address(this));

        uint256 undeployed = returnS + returnJ;
        uint256 extraS;
        uint256 extraJ;
        if (balance >= undeployed) {
            uint256 extra = balance - undeployed;
            extraS = extra.mulDivDown(wadMath.WAD - aWad, wadMath.WAD);
            extraJ = extra - extraS;
        } else {
            uint256 shortfall = undeployed - balance;
            uint256 shortfallS = shortfall.mulDivDown(wadMath.WAD - aWad, wadMath.WAD);
            returnS -= shortfallS;
            returnJ -= (shortfall - shortfallS);
        }

        uint256 totalToSenior = returnS + extraS;
        uint256 totalToJunior = returnJ + extraJ;
        if (totalToSenior + totalToJunior > 0) PARKING.transferPosition(CORE, totalToSenior + totalToJunior);
        iSeriesCoreMinimal(CORE).receiveReturn(totalToSenior, totalToJunior);

        totalFilled = kD;
        tFinalize = block.timestamp;
        state = SeriesState.LOCKED;

        emit Finalized(
            kD,
            r.seniorDeployed,
            r.juniorDeployed,
            fGross,
            fNet,
            aWad,
            utilizationWad,
            premiumWad,
            r.poolRateWad,
            r.seniorRateWad,
            r.seniorClaim,
            r.attachmentWad,
            passThrough,
            r.negativeCarry
        );
    }

    function _returnAllCashToCore() internal {
        _sweepRaw();
        uint256 balance = PARKING.totalAssets(address(this));

        uint256 kAlloc = seniorAllocated + juniorAllocated;
        uint256 aWad = kAlloc == 0 ? 0 : juniorAllocated.wDivDown(kAlloc);
        uint256 toSenior = balance.mulDivDown(wadMath.WAD - aWad, wadMath.WAD);
        uint256 toJunior = balance - toSenior;

        if (balance > 0) PARKING.transferPosition(CORE, balance);
        iSeriesCoreMinimal(CORE).receiveReturn(toSenior, toJunior);

        emit Canceled(toSenior, toJunior);
    }

    function _sweepRaw() internal {
        uint256 raw = iErc20Like(USDC).balanceOf(address(this));
        if (raw == 0) return;
        ERC20Lib.safeApprove(USDC, address(PARKING), raw);
        PARKING.deposit(raw);
    }
}
