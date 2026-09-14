// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SeriesMath} from "../../src/libraries/SeriesMath.sol";
import {PremiumCurve} from "../../src/libraries/PremiumCurve.sol";
import {WadMath} from "../../src/libraries/WadMath.sol";

// Morrow Finance — unit and fuzz tests for SeriesMath: pricing, waterfall, and nav.
// @author adiii.eth

/// @notice Pricing reproduces a worked reference example to the wei (6-decimal USDC base units), waterfall
/// matches the reference table with conservation at every row, nav satisfies its structural properties. Exact
/// expected integers below were cross-checked against the Python twin before being baked in here.
contract SeriesMathTest is Test {
    using WadMath for uint256;

    uint256 constant WAD = 1e18;
    uint256 constant USDC = 1e6;

    // reference example inputs
    uint256 constant J = 200_000 * USDC;
    uint256 constant S = 900_000 * USDC;
    uint256 constant K_ALLOC = S + J;
    uint256 constant K_D = 1_000_000 * USDC;
    uint256 constant F_NET = 1_010_000 * USDC;
    uint256 constant COV = 0.15e18;
    uint256 constant UT = 0.9e18;
    uint256 constant PI0 = 0.10e18;
    uint256 constant PIT = 0.20e18;
    uint256 constant PI1 = 0.35e18;
    uint256 constant THETA = 0.10e18;

    // exact expected values, cross-checked against sim/series_math.py
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

    function _pricingResult() internal pure returns (SeriesMath.PricingResult memory r, uint256 a, uint256 u, uint256 pi) {
        a = uint256(J).wDivDown(K_ALLOC);
        u = COV.wDivUp(a);
        pi = PremiumCurve.pi(u, UT, PI0, PIT, PI1);
        r = SeriesMath.price(K_D, a, F_NET, pi);
    }

    function test_referenceExample_allocationAndPricing() public pure {
        (SeriesMath.PricingResult memory r, uint256 a, uint256 u, uint256 pi) = _pricingResult();

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

        // S_d + J_d == K_d exactly (conservation of the allocation split).
        assertEq(r.seniorDeployed + r.juniorDeployed, K_D);
    }

    function test_referenceExample_waterfall_noLoss() public pure {
        (SeriesMath.PricingResult memory r,,,) = _pricingResult();
        uint256 P = F_NET; // no loss
        (uint256 xs, uint256 xj, uint256 fee) = SeriesMath.waterfall(P, r.seniorClaim, r.juniorDeployed, THETA);

        assertEq(xs, 824795454544, "XS");
        assertEq(xj, 184865909093, "XJ");
        assertEq(fee, 338636363, "fee");
        assertEq(xs + xj + fee, P, "conservation");
    }

    function test_referenceExample_waterfall_150kLoss() public pure {
        (SeriesMath.PricingResult memory r,,,) = _pricingResult();
        uint256 P = F_NET - 150_000 * USDC;
        (uint256 xs, uint256 xj, uint256 fee) = SeriesMath.waterfall(P, r.seniorClaim, r.juniorDeployed, THETA);

        assertEq(xs, 824795454544, "XS unchanged, senior still fully covered");
        assertEq(xj, 35204545456, "XJ");
        assertEq(fee, 0, "no fee when junior is below par");
        assertEq(xs + xj + fee, P, "conservation");
    }

    function test_referenceExample_waterfall_200kLoss_seniorImpaired() public pure {
        (SeriesMath.PricingResult memory r,,,) = _pricingResult();
        uint256 P = F_NET - 200_000 * USDC;
        (uint256 xs, uint256 xj, uint256 fee) = SeriesMath.waterfall(P, r.seniorClaim, r.juniorDeployed, THETA);

        assertEq(xs, 810_000 * USDC, "senior impaired: XS == P since P < C_S");
        assertEq(xj, 0, "junior wiped");
        assertEq(fee, 0);
        assertEq(xs + xj + fee, P, "conservation");
        assertLt(xs, r.seniorClaim, "senior must be impaired below its claim");
    }

    /// @dev XS, XJ and fee are non-decreasing in P; every delta >= 0.
    function testFuzz_waterfall_monotoneInProceeds(uint256 seniorClaim, uint256 juniorDeployed, uint256 pLow, uint256 pHigh)
        public
        pure
    {
        seniorClaim = bound(seniorClaim, 0, 1e15 * USDC);
        juniorDeployed = bound(juniorDeployed, 0, 1e15 * USDC);
        pLow = bound(pLow, 0, 2e15 * USDC);
        pHigh = bound(pHigh, pLow, 2e15 * USDC);

        (uint256 xsLow, uint256 xjLow, uint256 feeLow) = SeriesMath.waterfall(pLow, seniorClaim, juniorDeployed, THETA);
        (uint256 xsHigh, uint256 xjHigh, uint256 feeHigh) =
            SeriesMath.waterfall(pHigh, seniorClaim, juniorDeployed, THETA);

        assertGe(xsHigh, xsLow, "XS non-decreasing");
        assertGe(xjHigh, xjLow, "XJ non-decreasing");
        assertGe(feeHigh, feeLow, "fee non-decreasing");
    }

    /// @dev XS + XJ + fee == P at every P, including P=0, P<C_S, P==C_S, very large P, J_d==0.
    function testFuzz_waterfall_conservation(uint256 proceeds, uint256 seniorClaim, uint256 juniorDeployed) public pure {
        proceeds = bound(proceeds, 0, 1e15 * USDC);
        seniorClaim = bound(seniorClaim, 0, 1e15 * USDC);
        juniorDeployed = bound(juniorDeployed, 0, 1e15 * USDC);

        (uint256 xs, uint256 xj, uint256 fee) = SeriesMath.waterfall(proceeds, seniorClaim, juniorDeployed, THETA);
        assertEq(xs + xj + fee, proceeds, "conservation must hold at every P");
    }

    function test_waterfall_edgeCases() public pure {
        // P = 0
        (uint256 xs, uint256 xj, uint256 fee) = SeriesMath.waterfall(0, 1000 * USDC, 500 * USDC, THETA);
        assertEq(xs, 0);
        assertEq(xj, 0);
        assertEq(fee, 0);

        // P exactly == C_S
        (xs, xj, fee) = SeriesMath.waterfall(1000 * USDC, 1000 * USDC, 500 * USDC, THETA);
        assertEq(xs, 1000 * USDC);
        assertEq(xj, 0);
        assertEq(fee, 0);

        // J_d == 0 guard: every residual above senior is junior "profit" from wei one
        (xs, xj, fee) = SeriesMath.waterfall(1500 * USDC, 1000 * USDC, 0, THETA);
        assertEq(xs, 1000 * USDC);
        // residual = 500, fee = 10% of 500 = 50, junior = 450
        assertEq(fee, 50 * USDC);
        assertEq(xj, 450 * USDC);
        assertEq(xs + xj + fee, 1500 * USDC);
    }

    /// @dev Nav's structural properties, checked directly (not the reference example's numbers, which have a
    /// fee and are checked at nav convergence separately below).
    function test_nav_zeroLossZeroFee_matchesV1Formula() public pure {
        uint256 tau = 56 days;
        uint256 elapsed = tau / 2;
        uint256 kD = 1_000_000 * USDC;
        uint256 fNet = 1_010_000 * USDC;
        uint256 sD = 818181 * USDC;
        uint256 cS = 824795 * USDC;
        uint256 jD = kD - sD; // must satisfy S_d + J_d == K_d exactly, per allocationSplit's invariant

        (uint256 navS, uint256 navJ, uint256 feeAccrued) = SeriesMath.nav(elapsed, tau, kD, fNet, 0, sD, cS, jD, 0);

        // With L=0 and theta=0: NAV_J = J_d + (B_0 - J_d) * s / tau  (the v1 pdf junior formula).
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
        fNet = bound(fNet, kD, 2 * kD); // non-negative carry regime
        faceLoss = bound(faceLoss, 0, fNet);
        sD = bound(sD, 0, kD);
        jD = kD - sD;
        rSWad = bound(rSWad, 0, 1e18);
        uint256 cS = sD + sD.mulDivDown(rSWad, WAD);

        (uint256 navS, uint256 navJ, uint256 feeAccrued) =
            SeriesMath.nav(elapsed, tau, kD, fNet, faceLoss, sD, cS, jD, THETA);

        uint256 s = elapsed > tau ? tau : elapsed;
        uint256 accretion = fNet >= kD ? (fNet - kD).mulDivDown(s, tau) : 0;
        uint256 grossV = kD + accretion;
        uint256 v = grossV > faceLoss ? grossV - faceLoss : 0;

        assertEq(navS + navJ + feeAccrued, v, "NAV_S + NAV_J + feeAccrued == V(t) always");
    }

    /// @dev At t = T with every market resolved, NAV_S == XS, NAV_J == XJ and feeAccrued == fee from the
    /// waterfall. Convergence at s = tau, faceLoss = 0 (no loss, matching the reference example's no-loss row).
    function test_nav_convergesToWaterfall_atMaturity() public pure {
        (SeriesMath.PricingResult memory r,,,) = _pricingResult();
        uint256 tau = 56 days;

        (uint256 navS, uint256 navJ, uint256 feeAccrued) =
            SeriesMath.nav(tau, tau, K_D, F_NET, 0, r.seniorDeployed, r.seniorClaim, r.juniorDeployed, THETA);

        (uint256 xs, uint256 xj, uint256 fee) = SeriesMath.waterfall(F_NET, r.seniorClaim, r.juniorDeployed, THETA);

        assertEq(navS, xs, "NAV_S must equal XS at maturity");
        assertEq(navJ, xj, "NAV_J must equal XJ at maturity");
        assertEq(feeAccrued, fee, "feeAccrued must equal the waterfall fee at maturity");
    }

    function test_passThrough_waterfallAndNav_proRata() public pure {
        uint256 kD = 1_000_000 * USDC;
        uint256 sD = 700_000 * USDC;

        (uint256 xs, uint256 xj) = SeriesMath.waterfallPassThrough(900_000 * USDC, sD, kD);
        assertEq(xs, (900_000 * USDC * 7) / 10, "pass-through senior pro rata");
        assertEq(xs + xj, 900_000 * USDC, "conservation");

        (uint256 navS, uint256 navJ) = SeriesMath.navPassThrough(900_000 * USDC, sD, kD);
        assertEq(navS, xs, "passthrough nav must match passthrough waterfall pro rata split");
        assertEq(navS + navJ, 900_000 * USDC);
    }
}
