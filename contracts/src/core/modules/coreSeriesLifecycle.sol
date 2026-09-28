// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: opening, funding, crediting and retiring series: the core's side of every series' lifecycle.
// @author adiii.eth

pragma solidity 0.8.34;

import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {coreVaultFlows} from "./coreVaultFlows.sol";
import {creditSeries} from "../../series/creditSeries.sol";
import {SeriesParams, SeriesState} from "../../interfaces/iSeries.sol";
import {iMidnightMinimal} from "../../interfaces/iMidnightMinimal.sol";
import {wadMath} from "../../libraries/wadMath.sol";

abstract contract coreSeriesLifecycle is coreVaultFlows {
    using wadMath for uint256;

    function openSeries(SeriesParams calldata p, uint256 S, uint256 J)
        external
        onlyAllocator
        returns (address seriesAddr)
    {
        require(!paused, Paused());
        require(liveSeries.length < policy.maxSeries, MaxSeriesExceeded());

        uint256 kAlloc = S + J;
        require(kAlloc > 0 && kAlloc <= policy.maxPerSeriesAssets, PerSeriesCapExceeded());

        _requireParamsBound(p);

        uint256 aWad = J.mulDivDown(WAD, kAlloc);
        require(policy.covWad <= aWad && aWad <= policy.aMaxWad, CoverageBand(aWad));

        uint256 seniorAvail = idleDeployable(true);
        uint256 juniorAvail = idleDeployable(false);
        require(S <= seniorAvail, IdleInsufficient(true, S, seniorAvail));
        require(J <= juniorAvail, IdleInsufficient(false, J, juniorAvail));

        uint256 T = _maturityOfFirstMarket(p.marketIds[0]);
        uint256 windowExposure = _maturityWindowExposure(T) + kAlloc;
        uint256 totalAum = seniorAssets() + juniorAssets();
        require(windowExposure <= totalAum.mulDivDown(policy.maxPerMaturityWindowWad, WAD), MaturityWindowExceeded());

        seriesAddr = FACTORY.createSeries(p);

        _removeFromBooks(S, J);
        PARKING.transferPosition(seriesAddr, kAlloc);
        creditSeries(seriesAddr).initialize(S, J);

        liveSeries.push(seriesAddr);
        info[seriesAddr] = SeriesInfo({seniorAllocated: S, juniorAllocated: J, maturity: T, registered: true});

        emit SeriesFunded(seriesAddr, S, J);
    }

    function receiveReturn(uint256 toSenior, uint256 toJunior) external onlyRegisteredSeries {
        _creditBooks(toSenior, toJunior);

        if (uint8(creditSeries(msg.sender).state()) == uint8(SeriesState.CANCELED)) {
            _removeLive(msg.sender);
        }

        emit ReturnReceived(msg.sender, toSenior, toJunior);
    }

    function receivePayout(uint256 toSenior, uint256 toJunior) external onlyRegisteredSeries {
        _creditBooks(toSenior, toJunior);

        if (policy.backstopEnabled) {
            _applyBackstop(msg.sender);
        }

        creditSeries s = creditSeries(msg.sender);
        if (uint8(s.state()) == uint8(SeriesState.SETTLED)) {
            bool stillRecovering = _hasWrittenOffCredit(s);
            _removeLive(msg.sender);
            if (stillRecovering && recoveringSeries.length < policy.maxRecovering) {
                recoveringSeries.push(msg.sender);
            }
        }

        emit PayoutReceived(msg.sender, toSenior, toJunior);
    }

    function syncAll() external {
        uint256 length = liveSeries.length;
        for (uint256 i = 0; i < length; i++) {
            creditSeries(liveSeries[i]).navsSynced();
        }
        emit Synced(seniorAssets(), juniorAssets());
    }

    function pruneSeries() external {
        uint256 i;
        while (i < liveSeries.length) {
            creditSeries s = creditSeries(liveSeries[i]);
            uint8 st = uint8(s.state());
            if (st == uint8(SeriesState.SETTLED) || st == uint8(SeriesState.CANCELED)) {
                bool stillRecovering = st == uint8(SeriesState.SETTLED) && _hasWrittenOffCredit(s);
                address addr = liveSeries[i];
                liveSeries[i] = liveSeries[liveSeries.length - 1];
                liveSeries.pop();
                if (stillRecovering && recoveringSeries.length < policy.maxRecovering) {
                    recoveringSeries.push(addr);
                }
            } else {
                i++;
            }
        }

        uint256 j;
        while (j < recoveringSeries.length) {
            if (!_hasWrittenOffCredit(creditSeries(recoveringSeries[j]))) {
                recoveringSeries[j] = recoveringSeries[recoveringSeries.length - 1];
                recoveringSeries.pop();
            } else {
                j++;
            }
        }
    }

    function _requireParamsBound(SeriesParams calldata p) internal view {
        require(address(p.parking) == address(PARKING), WrongParking());
        require(p.allocator == allocator, WrongAllocator());
        require(p.feeRecipient == feeRecipient, WrongFeeRecipient());
        require(
            p.covWad == policy.covWad && p.pi0Wad == policy.pi0Wad && p.piTWad == policy.piTWad
                && p.pi1Wad == policy.pi1Wad && p.thetaWad == policy.thetaWad,
            PolicyMismatch()
        );
        uint256 length = p.rateFloorWad.length;
        for (uint256 i = 0; i < length; i++) {
            require(p.rateFloorWad[i] >= policy.minRateFloorWad, RateFloorBelowMin(i));
        }
        require(p.kMinAssets <= maxKMinAssets, KMinAboveCap());
        require(p.dWriteOff >= MIN_WRITE_OFF_DELAY && p.dWriteOff <= MAX_WRITE_OFF_DELAY, WriteOffDelayOutOfRange());
    }

    function _maturityOfFirstMarket(bytes32 marketId) internal view returns (uint256) {
        Market memory market = iMidnightMinimal(address(FACTORY.MIDNIGHT())).toMarket(marketId);
        return market.maturity;
    }

    function _maturityWindowExposure(uint256 T) internal view returns (uint256 exposure) {
        uint256 length = liveSeries.length;
        for (uint256 i = 0; i < length; i++) {
            SeriesInfo memory s = info[liveSeries[i]];
            uint256 diff = s.maturity > T ? s.maturity - T : T - s.maturity;
            if (diff <= 30 days) exposure += s.seniorAllocated + s.juniorAllocated;
        }
    }

    function _applyBackstop(address seriesAddr) internal {
        creditSeries s = creditSeries(seriesAddr);
        if (s.passThrough()) return;

        uint256 claim = s.seniorClaim();
        uint256 paid = s.paidS();
        if (paid >= claim) return;

        uint256 shortfall = claim - paid;
        uint256 already = backstopPaid[seriesAddr];
        if (already >= shortfall) return;
        uint256 remaining = shortfall - already;

        uint256 maxFromIdle = idle(false).mulDivDown(policy.backstopWad, WAD);
        uint256 backstop = remaining < maxFromIdle ? remaining : maxFromIdle;
        if (backstop == 0) return;

        uint256 claims = backstop.mulDivUp(totalParkingClaims + VIRTUAL_CLAIMS, _parked() + 1);
        if (claims > junior.parkingClaims) claims = junior.parkingClaims;
        junior.parkingClaims -= claims;
        senior.parkingClaims += claims;
        backstopPaid[seriesAddr] += backstop;

        emit Backstop(seriesAddr, backstop);
    }

    function _removeLive(address seriesAddr) internal {
        uint256 length = liveSeries.length;
        for (uint256 i = 0; i < length; i++) {
            if (liveSeries[i] == seriesAddr) {
                liveSeries[i] = liveSeries[length - 1];
                liveSeries.pop();
                return;
            }
        }
    }
}
