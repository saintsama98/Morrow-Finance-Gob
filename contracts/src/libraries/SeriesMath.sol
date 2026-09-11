// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {WadMath} from "./WadMath.sol";

/// @dev Pricing, nav and waterfall math for one series, sections 9.3, 12.4, 13.5, 13.6. No storage access; every
/// input is passed in and every output is deterministic given those inputs. Assets are USDC base units (6
/// decimals); ratios (`a`, `pi`, `r_pool`, `r_s`, `theta`) are wad. Rounding directions follow section 5.4
/// exactly: senior claim and every payout round down, junior is the exact residual, so conservation is exact to
/// the wei and dust accrues to junior.
library SeriesMath {
    using WadMath for uint256;

    uint256 internal constant WAD = 1e18;

    /// @dev section 9.3, computed once at finalize.
    struct PricingResult {
        uint256 seniorDeployed; // S_d
        uint256 juniorDeployed; // J_d
        uint256 poolRateWad; // r_pool (0 in the negativeCarry case, since it would otherwise underflow)
        uint256 seniorRateWad; // r_s
        uint256 seniorClaim; // C_S
        uint256 attachmentWad; // A_F
        int256 buffer0; // B_0 = F_net - C_S, signed since negative carry can drive it negative
        bool negativeCarry;
    }

    /// @dev S_d = mulDivDown(K_d, WAD - a, WAD), J_d = K_d - S_d (residual, so S_d + J_d == K_d exactly).
    function allocationSplit(uint256 kDeployed, uint256 juniorShareWad)
        internal
        pure
        returns (uint256 seniorDeployed, uint256 juniorDeployed)
    {
        seniorDeployed = kDeployed.mulDivDown(WAD - juniorShareWad, WAD);
        juniorDeployed = kDeployed - seniorDeployed;
    }

    /// @dev section 9.3. `piWad` is the junior premium at the series' utilization, already computed by the caller
    /// (PremiumCurve.pi combined with u = COV / a). `faceNetAtFinalize` is F_net at t = tFinalize (section 12.2,
    /// equals F when fees are zero).
    function price(uint256 kDeployed, uint256 juniorShareWad, uint256 faceNetAtFinalize, uint256 piWad)
        internal
        pure
        returns (PricingResult memory r)
    {
        (r.seniorDeployed, r.juniorDeployed) = allocationSplit(kDeployed, juniorShareWad);

        if (faceNetAtFinalize <= kDeployed) {
            // Non-positive pool rate. Rate floors on every market (section 10.2) should prevent this; if it
            // happens anyway, senior is still first but earns nothing, and no premium math is meaningful.
            r.negativeCarry = true;
            r.poolRateWad = 0;
            r.seniorRateWad = 0;
            r.seniorClaim = r.seniorDeployed;
        } else {
            r.poolRateWad = faceNetAtFinalize.mulDivDown(WAD, kDeployed) - WAD;
            r.seniorRateWad = r.poolRateWad.mulDivDown(WAD - piWad, WAD);
            r.seniorClaim = r.seniorDeployed + r.seniorDeployed.mulDivDown(r.seniorRateWad, WAD);
        }

        // A_F = WAD - mulDivUp(C_S, WAD, F_net); rounds the attachment down so it never overstates protection.
        // faceNetAtFinalize > 0 is guaranteed by the caller (a series with zero face never reaches pricing).
        uint256 claimOverFace = r.seniorClaim.mulDivUp(WAD, faceNetAtFinalize);
        r.attachmentWad = claimOverFace >= WAD ? 0 : WAD - claimOverFace;

        r.buffer0 = int256(faceNetAtFinalize) - int256(r.seniorClaim);
    }

    /// @dev section 12.4, normal (non-pass-through) mode. `elapsed` and `tau` are seconds; `s = min(elapsed, tau)`
    /// is computed by the caller or here — here, for a single source of truth. `faceLoss` is L(t), realized face
    /// loss since finalize (>= 0, read live from the protocol). Returns navS, navJ (net of accrued fee),
    /// feeAccrued.
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

    /// @dev V(t) = K_d + (F_net - K_d) * s / tau - L(t), floored at 0.
    function _poolValueMark(uint256 s, uint256 tau, uint256 kDeployed, uint256 faceNetAtFinalize, uint256 faceLoss)
        private
        pure
        returns (uint256)
    {
        uint256 accretion = (tau > 0 && faceNetAtFinalize >= kDeployed)
            ? (faceNetAtFinalize - kDeployed).mulDivDown(s, tau)
            : 0; // F_net < K_d only in the negativeCarry case, where accretion is meaningless; treated as 0.
        uint256 grossV = kDeployed + accretion;
        return grossV > faceLoss ? grossV - faceLoss : 0;
    }

    /// @dev NAV_S = min(S_d + (C_S - S_d) * s / tau, V(t)).
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

    /// @dev section 12.4, pass-through mode: no premium, no subordination, no fee. NAV_S = mulDivDown(V, S_d, K_d).
    function navPassThrough(uint256 v, uint256 seniorDeployed, uint256 kDeployed)
        internal
        pure
        returns (uint256 navS, uint256 navJ)
    {
        navS = kDeployed == 0 ? 0 : v.mulDivDown(seniorDeployed, kDeployed);
        navJ = v - navS;
    }

    /// @dev section 13.5, cumulative waterfall rerun. `proceeds` is P, cumulative usdc collected so far.
    /// XS = min(C_S, P), RJ = P - XS, fee = theta * max(RJ - J_d, 0), XJ = RJ - fee (exact residual).
    /// Conservation: XS + XJ + fee == P always. Monotone non-decreasing in P.
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

    /// @dev section 13.6, pass-through mode: both books get the market outcome pro rata, no premium, no fee.
    function waterfallPassThrough(uint256 proceeds, uint256 seniorDeployed, uint256 kDeployed)
        internal
        pure
        returns (uint256 seniorPaid, uint256 juniorPaid)
    {
        seniorPaid = kDeployed == 0 ? 0 : proceeds.mulDivDown(seniorDeployed, kDeployed);
        juniorPaid = proceeds - seniorPaid;
    }
}
