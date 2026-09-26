// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: unit and fuzz tests for seriesMath: pricing, waterfall, and nav.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {seriesMath} from "../../src/libraries/seriesMath.sol";
import {premiumCurve} from "../../src/libraries/premiumCurve.sol";
import {wadMath} from "../../src/libraries/wadMath.sol";

contract SeriesMathTest is Test {
    using wadMath for uint256;

    uint256 constant WAD = 1e18;
    uint256 constant USDC = 1e6;

    uint256 constant J = 200_000 * USDC;
    uint256 constant S = 900_000 * USDC;
    uint256 constant K_ALLOC = S + J;
    uint256 constant K_D = 1_000_000 * USDC;
    uint256 constant F_NET = 1_010_000 * USDC;
    uint256 constant COV = 0.15e18;
    uint256 constant UT = 0.9e18;
    uint256 constant PI0 = 0.1e18;
    uint256 constant PIT = 0.2e18;
    uint256 constant PI1 = 0.35e18;
    uint256 constant THETA = 0.1e18;

    uint256 constant EXPECTED_A = 181818181818181818;
    uint256 constant EXPECTED_U = 825000000000000001;
    uint256 constant EXPECTED_PI = 191666666666666667;
    uint256 constant EXPECTED_S_D = 818181818181;
    uint256 constant EXPECTED_J_D = 181818181819;
    uint256 constant EXPECTED_R_POOL = 10000000000000000;
    uint256 constant EXPECTED_R_S = 8083333333333333;
    uint256 constant EXPECTED_C_S = 824795454544;
    uint256 constant EXPECTED_A_F = 183370837085148514;
    int256 constant EXPECTED_B0 = 185204545456;

    function _pricingResult()
        internal
        pure
        returns (seriesMath.PricingResult memory r, uint256 a, uint256 u, uint256 pi)
    {
        a = uint256(J).wDivDown(K_ALLOC);
        u = COV.wDivUp(a);
        pi = premiumCurve.pi(u, UT, PI0, PIT, PI1);
        r = seriesMath.price(K_D, a, F_NET, pi);
    }

    function test_referenceExample_allocationAndPricing() public pure {
        (seriesMath.PricingResult memory r, uint256 a, uint256 u, uint256 pi) = _pricingResult();

        assertEq(a, EXPECTED_A, "a");
        assertEq(u, EXPECTED_U, "u");
        assertEq(pi, EXPECTED_PI, "pi");
        assertEq(r.seniorDeployed, EXPECTED_S_D, "S_d");
        assertEq(r.juniorDeployed, EXPECTED_J_D, "J_d");
        assertEq(r.poolRateWad, EXPECTED_R_POOL, "r_pool");
        assertEq(r.seniorRateWad, EXPECTED_R_S, "r_s");
        assertEq(r.seniorClaim, EXPECTED_C_S, "C_S");
        assertEq(r.attachmentWad, EXPECTED_A_F, "A_F");
        assertEq(r.buffer0, EXPECTED_B0, "B_0");
        assertFalse(r.negativeCarry, "must not flag negative carry");

        assertEq(r.seniorDeployed + r.juniorDeployed, K_D);
    }

    function test_referenceExample_waterfall_noLoss() public pure {
        (seriesMath.PricingResult memory r,,,) = _pricingResult();
        uint256 P = F_NET;
        (uint256 xs, uint256 xj, uint256 fee) = seriesMath.waterfall(P, r.seniorClaim, r.juniorDeployed, THETA);

        assertEq(xs, 824795454544, "XS");
        assertEq(xj, 184865909093, "XJ");
        assertEq(fee, 338636363, "fee");
        assertEq(xs + xj + fee, P, "conservation");
    }

    function test_referenceExample_waterfall_150kLoss() public pure {
        (seriesMath.PricingResult memory r,,,) = _pricingResult();
        uint256 P = F_NET - 150_000 * USDC;
        (uint256 xs, uint256 xj, uint256 fee) = seriesMath.waterfall(P, r.seniorClaim, r.juniorDeployed, THETA);

        assertEq(xs, 824795454544, "XS unchanged, senior still fully covered");
        assertEq(xj, 35204545456, "XJ");
        assertEq(fee, 0, "no fee when junior is below par");
        assertEq(xs + xj + fee, P, "conservation");
    }

    function test_referenceExample_waterfall_200kLoss_seniorImpaired() public pure {
        (seriesMath.PricingResult memory r,,,) = _pricingResult();
        uint256 P = F_NET - 200_000 * USDC;
        (uint256 xs, uint256 xj, uint256 fee) = seriesMath.waterfall(P, r.seniorClaim, r.juniorDeployed, THETA);

        assertEq(xs, 810_000 * USDC, "senior impaired: XS == P since P < C_S");
        assertEq(xj, 0, "junior wiped");
        assertEq(fee, 0);
        assertEq(xs + xj + fee, P, "conservation");
        assertLt(xs, r.seniorClaim, "senior must be impaired below its claim");
    }

    function testFuzz_waterfall_monotoneInProceeds(
        uint256 seniorClaim,
        uint256 juniorDeployed,
        uint256 pLow,
        uint256 pHigh
    ) public pure {
        seniorClaim = bound(seniorClaim, 0, 1e15 * USDC);
        juniorDeployed = bound(juniorDeployed, 0, 1e15 * USDC);
        pLow = bound(pLow, 0, 2e15 * USDC);
        pHigh = bound(pHigh, pLow, 2e15 * USDC);

        (uint256 xsLow, uint256 xjLow, uint256 feeLow) = seriesMath.waterfall(pLow, seniorClaim, juniorDeployed, THETA);
        (uint256 xsHigh, uint256 xjHigh, uint256 feeHigh) =
            seriesMath.waterfall(pHigh, seniorClaim, juniorDeployed, THETA);

        assertGe(xsHigh, xsLow, "XS non-decreasing");
        assertGe(xjHigh, xjLow, "XJ non-decreasing");
        assertGe(feeHigh, feeLow, "fee non-decreasing");
    }

    function testFuzz_waterfall_conservation(uint256 proceeds, uint256 seniorClaim, uint256 juniorDeployed)
        public
        pure
    {
        proceeds = bound(proceeds, 0, 1e15 * USDC);
        seniorClaim = bound(seniorClaim, 0, 1e15 * USDC);
        juniorDeployed = bound(juniorDeployed, 0, 1e15 * USDC);

        (uint256 xs, uint256 xj, uint256 fee) = seriesMath.waterfall(proceeds, seniorClaim, juniorDeployed, THETA);
        assertEq(xs + xj + fee, proceeds, "conservation must hold at every P");
    }

    function test_waterfall_edgeCases() public pure {
        (uint256 xs, uint256 xj, uint256 fee) = seriesMath.waterfall(0, 1000 * USDC, 500 * USDC, THETA);
        assertEq(xs, 0);
        assertEq(xj, 0);
        assertEq(fee, 0);

        (xs, xj, fee) = seriesMath.waterfall(1000 * USDC, 1000 * USDC, 500 * USDC, THETA);
        assertEq(xs, 1000 * USDC);
        assertEq(xj, 0);
        assertEq(fee, 0);

        (xs, xj, fee) = seriesMath.waterfall(1500 * USDC, 1000 * USDC, 0, THETA);
        assertEq(xs, 1000 * USDC);
        assertEq(fee, 50 * USDC);
        assertEq(xj, 450 * USDC);
        assertEq(xs + xj + fee, 1500 * USDC);
    }

    function test_nav_zeroLossZeroFee_matchesV1Formula() public pure {
        uint256 tau = 56 days;
        uint256 elapsed = tau / 2;
        uint256 kD = 1_000_000 * USDC;
        uint256 fNet = 1_010_000 * USDC;
        uint256 sD = 818181 * USDC;
        uint256 cS = 824795 * USDC;
        uint256 jD = kD - sD;

        (uint256 navS, uint256 navJ, uint256 feeAccrued) = seriesMath.nav(elapsed, tau, kD, fNet, 0, sD, cS, jD, 0);

        uint256 b0 = fNet - cS;
        uint256 expectedNavJ = jD + (b0 - jD).mulDivDown(elapsed, tau);
        assertEq(navJ, expectedNavJ, "NAV_J must match the v1 junior formula when L=0, theta=0");
        assertEq(feeAccrued, 0);

        uint256 v = kD + (fNet - kD).mulDivDown(elapsed, tau);
        assertEq(navS + navJ, v, "NAV_S + NAV_J == V(t) when fee is 0");
    }

    function testFuzz_nav_sumsToV_andJuniorNeverNegative(
        uint256 elapsed,
        uint256 tau,
        uint256 kD,
        uint256 fNet,
        uint256 faceLoss,
        uint256 sD,
        uint256 jD,
        uint256 rSWad
    ) public pure {
        tau = bound(tau, 1, 365 days);
        elapsed = bound(elapsed, 0, 2 * tau);
        kD = bound(kD, 1, 1e12 * USDC);
        fNet = bound(fNet, kD, 2 * kD);
        faceLoss = bound(faceLoss, 0, fNet);
        sD = bound(sD, 0, kD);
        jD = kD - sD;
        rSWad = bound(rSWad, 0, 1e18);
        uint256 cS = sD + sD.mulDivDown(rSWad, WAD);

        (uint256 navS, uint256 navJ, uint256 feeAccrued) =
            seriesMath.nav(elapsed, tau, kD, fNet, faceLoss, sD, cS, jD, THETA);

        uint256 s = elapsed > tau ? tau : elapsed;
        uint256 accretion = fNet >= kD ? (fNet - kD).mulDivDown(s, tau) : 0;
        uint256 grossV = kD + accretion;
        uint256 v = grossV > faceLoss ? grossV - faceLoss : 0;

        assertEq(navS + navJ + feeAccrued, v, "NAV_S + NAV_J + feeAccrued == V(t) always");
    }

    function test_nav_convergesToWaterfall_atMaturity() public pure {
        (seriesMath.PricingResult memory r,,,) = _pricingResult();
        uint256 tau = 56 days;

        (uint256 navS, uint256 navJ, uint256 feeAccrued) =
            seriesMath.nav(tau, tau, K_D, F_NET, 0, r.seniorDeployed, r.seniorClaim, r.juniorDeployed, THETA);

        (uint256 xs, uint256 xj, uint256 fee) = seriesMath.waterfall(F_NET, r.seniorClaim, r.juniorDeployed, THETA);

        assertEq(navS, xs, "NAV_S must equal XS at maturity");
        assertEq(navJ, xj, "NAV_J must equal XJ at maturity");
        assertEq(feeAccrued, fee, "feeAccrued must equal the waterfall fee at maturity");
    }

    function test_passThrough_waterfallAndNav_proRata() public pure {
        uint256 kD = 1_000_000 * USDC;
        uint256 sD = 700_000 * USDC;

        (uint256 xs, uint256 xj) = seriesMath.waterfallPassThrough(900_000 * USDC, sD, kD);
        assertEq(xs, (900_000 * USDC * 7) / 10, "pass-through senior pro rata");
        assertEq(xs + xj, 900_000 * USDC, "conservation");

        (uint256 navS, uint256 navJ) = seriesMath.navPassThrough(900_000 * USDC, sD, kD);
        assertEq(navS, xs, "passthrough nav must match passthrough waterfall pro rata split");
        assertEq(navS + navJ, 900_000 * USDC);
    }
}
