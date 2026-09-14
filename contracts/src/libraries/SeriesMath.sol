// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {WadMath} from "./WadMath.sol";

// Morrow Finance — pricing, nav, and waterfall math for a single credit series.
// @author adiii.eth

/// @notice Pricing, nav, and waterfall math for one series. No storage access: every input is passed in and
/// every output is deterministic given those inputs.
/// @dev Assets are USDC base units (6 decimals); ratios (`a`, `pi`, `r_pool`, `r_s`, `theta`) are wad. The
/// senior claim and every payout always round down; junior is the exact residual, so conservation is exact to
/// the wei and dust accrues to junior.
library SeriesMath {
    using WadMath for uint256;

    uint256 internal constant WAD = 1e18;

    /// @notice Pricing outputs computed once at finalize and frozen for the life of the series.
    struct PricingResult {
        uint256 seniorDeployed; // senior principal actually deployed
        uint256 juniorDeployed; // junior principal actually deployed
        uint256 poolRateWad; // realized term rate on deployed capital (0 if negativeCarry)
        uint256 seniorRateWad; // senior's share of the pool rate after the junior premium
        uint256 seniorClaim; // senior's fixed claim at maturity
        uint256 attachmentWad; // fraction of face value protecting senior from loss
        int256 buffer0; // face net of fees minus the senior claim, signed (negative carry can flip it)
        bool negativeCarry;
    }

    /// @notice Splits deployed capital into senior and junior legs by junior share `a`.
    /// @param kDeployed Total capital actually deployed.
    /// @param juniorShareWad Junior's share of deployed capital, wad.
    /// @return seniorDeployed Senior's leg, rounded down.
    /// @return juniorDeployed Junior's leg, the exact residual (seniorDeployed + juniorDeployed == kDeployed).
    function allocationSplit(uint256 kDeployed, uint256 juniorShareWad)
        internal
        pure
        returns (uint256 seniorDeployed, uint256 juniorDeployed)
    {
        seniorDeployed = kDeployed.mulDivDown(WAD - juniorShareWad, WAD);
        juniorDeployed = kDeployed - seniorDeployed;
    }

    /// @notice Prices a series at finalize: splits capital, derives the realized pool rate, and freezes the
    /// senior claim and attachment point.
    /// @param kDeployed Total capital actually deployed into the basket.
    /// @param juniorShareWad Junior's share of deployed capital, wad.
    /// @param faceNetAtFinalize Projected redeemable face value at finalize, net of protocol fees.
    /// @param piWad The junior premium at this series' utilization (from PremiumCurve.pi).
    /// @return r The full pricing result; see PricingResult.
    function price(uint256 kDeployed, uint256 juniorShareWad, uint256 faceNetAtFinalize, uint256 piWad)
        internal
        pure
        returns (PricingResult memory r)
    {
        (r.seniorDeployed, r.juniorDeployed) = allocationSplit(kDeployed, juniorShareWad);

        if (faceNetAtFinalize <= kDeployed) {
            // Non-positive pool rate: senior is still first but earns nothing. Rate floors on every market
            // should prevent this; handled defensively in case they don't.
            r.negativeCarry = true;
            r.poolRateWad = 0;
            r.seniorRateWad = 0;
            r.seniorClaim = r.seniorDeployed;
        } else {
            r.poolRateWad = faceNetAtFinalize.mulDivDown(WAD, kDeployed) - WAD;
            r.seniorRateWad = r.poolRateWad.mulDivDown(WAD - piWad, WAD);
            r.seniorClaim = r.seniorDeployed + r.seniorDeployed.mulDivDown(r.seniorRateWad, WAD);
        }

        // Rounds the attachment down so it never overstates the protection senior actually has.
        // faceNetAtFinalize > 0 is guaranteed by the caller (a series with zero face never reaches pricing).
        uint256 claimOverFace = r.seniorClaim.mulDivUp(WAD, faceNetAtFinalize);
        r.attachmentWad = claimOverFace >= WAD ? 0 : WAD - claimOverFace;

        // forge-lint: disable-next-line(unsafe-typecast) USDC face/claim amounts stay far below 2^255
        r.buffer0 = int256(faceNetAtFinalize) - int256(r.seniorClaim);
    }

    /// @notice Marks a locked series to market: linear accretion toward the frozen targets, capped at maturity
    /// and reduced immediately by any realized loss.
    /// @param elapsed Seconds since finalize.
    /// @param tau Seconds from finalize to maturity.
    /// @param kDeployed Total capital deployed at finalize.
    /// @param faceNetAtFinalize Projected redeemable face value frozen at finalize.
    /// @param faceLoss Realized face loss since finalize (>= 0, read live from the lending protocol).
    /// @param seniorDeployed Senior's deployed leg.
    /// @param seniorClaim Senior's frozen claim.
    /// @param juniorDeployed Junior's deployed leg.
    /// @param thetaWad Operator fee rate on junior's profit, wad.
    /// @return navS Senior's current mark.
    /// @return navJ Junior's current mark, net of the accrued operator fee.
    /// @return feeAccrued Operator fee accrued so far on junior's profit.
    function nav(
        uint256 elapsed,
        uint256 tau,
        uint256 kDeployed,
        uint256 faceNetAtFinalize,
        uint256 faceLoss,
        uint256 seniorDeployed,
        uint256 seniorClaim,
        uint256 juniorDeployed,
        uint256 thetaWad
    ) internal pure returns (uint256 navS, uint256 navJ, uint256 feeAccrued) {
        uint256 s = elapsed > tau ? tau : elapsed;

        uint256 v = _poolValueMark(s, tau, kDeployed, faceNetAtFinalize, faceLoss);
        navS = _seniorMark(s, tau, seniorDeployed, seniorClaim, v);

        uint256 navJGross = v - navS; // always >= 0 since navS <= v by construction
        feeAccrued = navJGross > juniorDeployed ? (navJGross - juniorDeployed).mulDivDown(thetaWad, WAD) : 0;
        navJ = navJGross - feeAccrued;
    }

    /// @dev Marks the whole pool: deployed capital plus linear accretion toward face value, floored at 0 after
    /// subtracting any realized loss.
    function _poolValueMark(uint256 s, uint256 tau, uint256 kDeployed, uint256 faceNetAtFinalize, uint256 faceLoss)
        private
        pure
        returns (uint256)
    {
        uint256 accretion = (tau > 0 && faceNetAtFinalize >= kDeployed)
            ? (faceNetAtFinalize - kDeployed).mulDivDown(s, tau)
            : 0; // faceNetAtFinalize < kDeployed only in the negativeCarry case, where accretion is meaningless.
        uint256 grossV = kDeployed + accretion;
        return grossV > faceLoss ? grossV - faceLoss : 0;
    }

    /// @dev Marks senior's leg: deployed capital plus linear accretion toward its claim, capped at the pool's
    /// own mark so senior can never show more value than the pool actually holds.
    function _seniorMark(uint256 s, uint256 tau, uint256 seniorDeployed, uint256 seniorClaim, uint256 v)
        private
        pure
        returns (uint256)
    {
        uint256 seniorAccretion =
            (tau > 0 && seniorClaim >= seniorDeployed) ? (seniorClaim - seniorDeployed).mulDivDown(s, tau) : 0;
        uint256 seniorMark = seniorDeployed + seniorAccretion;
        return seniorMark < v ? seniorMark : v;
    }

    /// @notice Marks a pass-through series (below the minimum fill threshold): both legs share the pool's mark
    /// pro rata, with no premium, no subordination, and no fee.
    /// @param v The pool's current mark.
    /// @param seniorDeployed Senior's deployed leg.
    /// @param kDeployed Total capital deployed.
    /// @return navS Senior's pro-rata mark.
    /// @return navJ Junior's pro-rata mark, the exact residual.
    function navPassThrough(uint256 v, uint256 seniorDeployed, uint256 kDeployed)
        internal
        pure
        returns (uint256 navS, uint256 navJ)
    {
        navS = kDeployed == 0 ? 0 : v.mulDivDown(seniorDeployed, kDeployed);
        navJ = v - navS;
    }

    /// @notice Recomputes the full waterfall from cumulative proceeds. Idempotent and safe to call repeatedly
    /// as more proceeds arrive: conservation (seniorPaid + juniorPaid + fee == proceeds) and monotonicity in
    /// proceeds both hold at every call.
    /// @param proceeds Cumulative assets collected so far.
    /// @param seniorClaim Senior's frozen claim.
    /// @param juniorDeployed Junior's deployed leg (junior's cost basis for profit-fee purposes).
    /// @param thetaWad Operator fee rate on junior's profit, wad.
    /// @return seniorPaid min(seniorClaim, proceeds).
    /// @return juniorPaid The exact residual after senior and the fee.
    /// @return fee Operator fee on junior's profit above its deployed capital.
    function waterfall(uint256 proceeds, uint256 seniorClaim, uint256 juniorDeployed, uint256 thetaWad)
        internal
        pure
        returns (uint256 seniorPaid, uint256 juniorPaid, uint256 fee)
    {
        seniorPaid = proceeds < seniorClaim ? proceeds : seniorClaim;
        uint256 residualToJunior = proceeds - seniorPaid;
        fee = residualToJunior > juniorDeployed ? (residualToJunior - juniorDeployed).mulDivDown(thetaWad, WAD) : 0;
        juniorPaid = residualToJunior - fee;
    }

    /// @notice Waterfall for a pass-through series: both legs get the market outcome pro rata, no premium and
    /// no fee.
    /// @param proceeds Cumulative assets collected so far.
    /// @param seniorDeployed Senior's deployed leg.
    /// @param kDeployed Total capital deployed.
    /// @return seniorPaid Senior's pro-rata share.
    /// @return juniorPaid Junior's pro-rata share, the exact residual.
    function waterfallPassThrough(uint256 proceeds, uint256 seniorDeployed, uint256 kDeployed)
        internal
        pure
        returns (uint256 seniorPaid, uint256 juniorPaid)
    {
        seniorPaid = kDeployed == 0 ? 0 : proceeds.mulDivDown(seniorDeployed, kDeployed);
        juniorPaid = proceeds - seniorPaid;
    }
}
