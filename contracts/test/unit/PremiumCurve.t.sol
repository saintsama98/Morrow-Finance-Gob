// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: unit and fuzz tests for the PremiumCurve piecewise-linear pricing curve.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {PremiumCurve} from "../../src/libraries/PremiumCurve.sol";

contract PremiumCurveTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant UT = 0.9e18;
    uint256 constant PI0 = 0.1e18;
    uint256 constant PIT = 0.2e18;
    uint256 constant PI1 = 0.35e18;
    uint256 constant COV = 0.15e18;

    function test_exactReferenceTable() public pure {
        assertEq(PremiumCurve.pi(1.0e18, UT, PI0, PIT, PI1), 0.35e18);

        uint256 piAt825 = PremiumCurve.pi(0.825e18, UT, PI0, PIT, PI1);
        assertApproxEqAbs(piAt825, 191666666666666667, 1, "u=0.825");

        uint256 piAt75 = PremiumCurve.pi(0.75e18, UT, PI0, PIT, PI1);
        assertApproxEqAbs(piAt75, 183333333333333334, 1, "u=0.75");

        uint256 piAt60 = PremiumCurve.pi(0.6e18, UT, PI0, PIT, PI1);
        assertApproxEqAbs(piAt60, 166666666666666667, 1, "u=0.60");

        uint256 piAt50 = PremiumCurve.pi(0.5e18, UT, PI0, PIT, PI1);
        assertApproxEqAbs(piAt50, 155555555555555556, 1, "u=0.50");

        assertEq(PremiumCurve.pi(0, UT, PI0, PIT, PI1), PI0, "u=0");

        assertEq(PremiumCurve.pi(UT, UT, PI0, PIT, PI1), PIT, "u=uT");
    }

    function test_continuityAtKink() public pure {
        uint256 atKink = PremiumCurve.pi(UT, UT, PI0, PIT, PI1);
        assertEq(atKink, PIT, "pi(uT) must equal piT exactly");

        assertEq(PIT - 0, atKink, "lower-branch formula at u=uT must agree with the upper branch's value");
    }

    function testFuzz_stepSizeNearKink_boundedBySlope(uint256 offset) public pure {
        offset = bound(offset, 1, 1000);
        uint256 belowSlopeCeil = (PIT - PI0) / UT + 2;
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
