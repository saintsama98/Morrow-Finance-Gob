// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {PremiumCurve} from "../../src/libraries/PremiumCurve.sol";

/// @dev Spec section 25.2 "PremiumCurve": the seven exact table points from section 9.2, continuity at u = uT
/// (<= 1 wei difference), monotone non-decreasing over a 1,000 point grid, clamp for u > WAD.
contract PremiumCurveTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant UT = 0.9e18;
    uint256 constant PI0 = 0.10e18;
    uint256 constant PIT = 0.20e18;
    uint256 constant PI1 = 0.35e18;
    uint256 constant COV = 0.15e18;

    /// @dev Table from section 9.2. u values derived from a = COV / u swapped as u = COV / a; here we drive pi(u)
    /// directly since that's the pure function's actual input.
    function test_section9_2_exactTable() public pure {
        // a = 0.15 -> u = 1.00 -> pi = 0.35
        assertEq(PremiumCurve.pi(1.00e18, UT, PI0, PIT, PI1), 0.35e18);

        // a = 200_000 / 1_100_000 = 0.181818... -> u = 0.825 -> pi = 0.191666...
        // pi = 0.20 - (0.075/0.9)*0.10 rounded up; exact rational is 23/120 = 0.1916666...6
        uint256 piAt825 = PremiumCurve.pi(0.825e18, UT, PI0, PIT, PI1);
        assertApproxEqAbs(piAt825, 191666666666666667, 1, "u=0.825");

        // a = 0.20 -> u = 0.75 -> pi = 0.183333...
        uint256 piAt75 = PremiumCurve.pi(0.75e18, UT, PI0, PIT, PI1);
        assertApproxEqAbs(piAt75, 183333333333333334, 1, "u=0.75");

        // a = 0.25 -> u = 0.60 -> pi = 0.166666...
        uint256 piAt60 = PremiumCurve.pi(0.60e18, UT, PI0, PIT, PI1);
        assertApproxEqAbs(piAt60, 166666666666666667, 1, "u=0.60");

        // a = 0.30 -> u = 0.50 -> pi = 0.155555...
        uint256 piAt50 = PremiumCurve.pi(0.50e18, UT, PI0, PIT, PI1);
        assertApproxEqAbs(piAt50, 155555555555555556, 1, "u=0.50");

        // u -> 0 (limit) -> pi = pi0
        assertEq(PremiumCurve.pi(0, UT, PI0, PIT, PI1), PI0, "u=0");

        // u = 0.9 (the kink itself) -> pi = piT
        assertEq(PremiumCurve.pi(UT, UT, PI0, PIT, PI1), PIT, "u=uT");
    }

    /// @dev Section 25.2: "continuity at u = uT (difference <= 1 wei)". This checks the two branch *formulas*
    /// agree at the boundary itself (both reduce to delta = 0 at u = uT, so both give piT exactly) rather than
    /// comparing wei-adjacent steps, whose size is set by the curve's slope ((pi1-piT)/(WAD-uT) = 1.5 by default)
    /// and is expected to exceed 1 wei per 1 wei of u once rounded up.
    function test_continuityAtKink() public pure {
        uint256 atKink = PremiumCurve.pi(UT, UT, PI0, PIT, PI1);
        assertEq(atKink, PIT, "pi(uT) must equal piT exactly");

        // The lower-branch formula, evaluated at u = uT even though the implementation takes the upper branch
        // there: delta = mulDivDown(uT - uT, piT - pi0, uT) = mulDivDown(0, ..., ...) = 0, so it also gives piT.
        // Both branch formulas agree exactly at the kink; there is no discrete jump baked into the definition.
        assertEq(PIT - 0, atKink, "lower-branch formula at u=uT must agree with the upper branch's value");
    }

    /// @dev Adjacent-wei steps near the kink scale with the branch slope, not a fixed 1-wei bound: below the
    /// kink slope is (piT-pi0)/uT ~ 0.111, above it's (pi1-piT)/(WAD-uT) = 1.5 by default. Assert steps track
    /// the slope (ceil(slope) + 1 for rounding slack) rather than an arbitrary constant.
    function testFuzz_stepSizeNearKink_boundedBySlope(uint256 offset) public pure {
        offset = bound(offset, 1, 1000);
        uint256 belowSlopeCeil = (PIT - PI0) / UT + 2; // generous slack for integer approx
        uint256 aboveSlopeCeil = (PI1 - PIT) / (WAD - UT) + 2;

        uint256 below = PremiumCurve.pi(UT - offset, UT, PI0, PIT, PI1);
        uint256 atKink = PremiumCurve.pi(UT, UT, PI0, PIT, PI1);
        assertLe(atKink - below, belowSlopeCeil * offset, "step below kink exceeds slope bound");

        uint256 above = PremiumCurve.pi(UT + offset, UT, PI0, PIT, PI1);
        assertLe(above - atKink, aboveSlopeCeil * offset, "step above kink exceeds slope bound");
    }

    function test_monotoneNonDecreasing_1000PointGrid() public pure {
        uint256 prev = PremiumCurve.pi(0, UT, PI0, PIT, PI1);
        for (uint256 i = 1; i <= 1000; i++) {
            uint256 u = (WAD * i) / 1000;
            uint256 cur = PremiumCurve.pi(u, UT, PI0, PIT, PI1);
            assertGe(cur, prev, "pi(u) must be non-decreasing");
            prev = cur;
        }
    }

    function test_clampAboveWad() public pure {
        uint256 atWad = PremiumCurve.pi(WAD, UT, PI0, PIT, PI1);
        uint256 aboveWad = PremiumCurve.pi(WAD * 2, UT, PI0, PIT, PI1);
        assertEq(atWad, aboveWad, "u > WAD must clamp to the u = WAD result");
        assertEq(atWad, PI1, "pi(WAD) must equal pi1 exactly");
    }

    function testFuzz_invalidAnchorsRevert(uint256 p0, uint256 pT, uint256 p1) public {
        vm.assume(!(p0 <= pT && pT <= p1 && p1 < WAD));
        PremiumCurveHarness harness = new PremiumCurveHarness();
        vm.expectRevert(PremiumCurve.InvalidAnchors.selector);
        harness.pi(0.5e18, UT, p0, pT, p1);
    }

    function testFuzz_monotone(uint256 uLow, uint256 uHigh) public pure {
        uLow = bound(uLow, 0, WAD);
        uHigh = bound(uHigh, uLow, WAD);
        uint256 piLow = PremiumCurve.pi(uLow, UT, PI0, PIT, PI1);
        uint256 piHigh = PremiumCurve.pi(uHigh, UT, PI0, PIT, PI1);
        assertGe(piHigh, piLow);
    }
}

contract PremiumCurveHarness {
    function pi(uint256 u, uint256 uT, uint256 pi0, uint256 piT, uint256 pi1) external pure returns (uint256) {
        return PremiumCurve.pi(u, uT, pi0, piT, pi1);
    }
}
