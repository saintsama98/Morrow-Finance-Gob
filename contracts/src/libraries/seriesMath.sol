// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: pricing, nav, and waterfall math for a single credit series.
// @author adiii.eth

pragma solidity 0.8.34;

import {wadMath} from "./wadMath.sol";

library seriesMath {
    using wadMath for uint256;

    uint256 internal constant WAD = 1e18;

    struct PricingResult {
        uint256 seniorDeployed;
        uint256 juniorDeployed;
        uint256 poolRateWad;
        uint256 seniorRateWad;
        uint256 seniorClaim;
        uint256 attachmentWad;
        int256 buffer0;
        bool negativeCarry;
    }

    function allocationSplit(uint256 kDeployed, uint256 juniorShareWad)
        internal
        pure
        returns (uint256 seniorDeployed, uint256 juniorDeployed)
    {
        seniorDeployed = kDeployed.mulDivDown(WAD - juniorShareWad, WAD);
        juniorDeployed = kDeployed - seniorDeployed;
    }

    function price(uint256 kDeployed, uint256 juniorShareWad, uint256 faceNetAtFinalize, uint256 piWad)
        internal
        pure
        returns (PricingResult memory r)
    {
        (r.seniorDeployed, r.juniorDeployed) = allocationSplit(kDeployed, juniorShareWad);

        if (faceNetAtFinalize <= kDeployed) {
            r.negativeCarry = true;
            r.poolRateWad = 0;
            r.seniorRateWad = 0;
            r.seniorClaim = r.seniorDeployed;
        } else {
            r.poolRateWad = faceNetAtFinalize.mulDivDown(WAD, kDeployed) - WAD;
            r.seniorRateWad = r.poolRateWad.mulDivDown(WAD - piWad, WAD);
            r.seniorClaim = r.seniorDeployed + r.seniorDeployed.mulDivDown(r.seniorRateWad, WAD);
        }

        uint256 claimOverFace = r.seniorClaim.mulDivUp(WAD, faceNetAtFinalize);
        r.attachmentWad = claimOverFace >= WAD ? 0 : WAD - claimOverFace;

        r.buffer0 = int256(faceNetAtFinalize) - int256(r.seniorClaim);
    }

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

        uint256 navJGross = v - navS;
        feeAccrued = navJGross > juniorDeployed ? (navJGross - juniorDeployed).mulDivDown(thetaWad, WAD) : 0;
        navJ = navJGross - feeAccrued;
    }

    function _poolValueMark(uint256 s, uint256 tau, uint256 kDeployed, uint256 faceNetAtFinalize, uint256 faceLoss)
        private
        pure
        returns (uint256)
    {
        uint256 accretion =
            (tau > 0 && faceNetAtFinalize >= kDeployed) ? (faceNetAtFinalize - kDeployed).mulDivDown(s, tau) : 0;
        uint256 grossV = kDeployed + accretion;
        return grossV > faceLoss ? grossV - faceLoss : 0;
    }

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

    function navPassThrough(uint256 v, uint256 seniorDeployed, uint256 kDeployed)
        internal
        pure
        returns (uint256 navS, uint256 navJ)
    {
        navS = kDeployed == 0 ? 0 : v.mulDivDown(seniorDeployed, kDeployed);
        navJ = v - navS;
    }

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

    function waterfallPassThrough(uint256 proceeds, uint256 seniorDeployed, uint256 kDeployed)
        internal
        pure
        returns (uint256 seniorPaid, uint256 juniorPaid)
    {
        seniorPaid = kDeployed == 0 ? 0 : proceeds.mulDivDown(seniorDeployed, kDeployed);
        juniorPaid = proceeds - seniorPaid;
    }
}
