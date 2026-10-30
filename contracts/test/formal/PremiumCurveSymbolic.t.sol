// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: symbolic properties of the three-anchor premium curve (Halmos check_ targets with fuzz twins).
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {PremiumCurve} from "../../src/libraries/PremiumCurve.sol";

contract PremiumCurveSymbolicHarness {
    function pi(uint256 u, uint256 uT, uint256 pi0, uint256 piT, uint256 pi1) external pure returns (uint256) {
        return PremiumCurve.pi(u, uT, pi0, piT, pi1);
    }
}

contract PremiumCurveSymbolicTest is Test {
    uint256 constant WAD = 1e18;

    PremiumCurveSymbolicHarness internal h;

    function setUp() public {
        h = new PremiumCurveSymbolicHarness();
    }

    function _validAnchors(uint256 uT, uint256 pi0, uint256 piT, uint256 pi1) internal pure returns (bool) {
        return uT > 0 && uT < WAD && pi0 <= piT && piT <= pi1 && pi1 < WAD;
    }

    function check_boundedByEndAnchors(uint256 u, uint256 uT, uint256 pi0, uint256 piT, uint256 pi1) public pure {
        vm.assume(_validAnchors(uT, pi0, piT, pi1));
        uint256 p = PremiumCurve.pi(u, uT, pi0, piT, pi1);
        assert(pi0 <= p && p <= pi1);
        if (u < uT) assert(p <= piT);
        else assert(p >= piT);
    }

    function check_hitsTheAnchors(uint256 uT, uint256 pi0, uint256 piT, uint256 pi1) public pure {
        vm.assume(_validAnchors(uT, pi0, piT, pi1));
        assert(PremiumCurve.pi(0, uT, pi0, piT, pi1) == pi0);
        assert(PremiumCurve.pi(uT, uT, pi0, piT, pi1) == piT);
        assert(PremiumCurve.pi(WAD, uT, pi0, piT, pi1) == pi1);
    }

    function check_invalidAnchorsRevert(uint256 u, uint256 uT, uint256 pi0, uint256 piT, uint256 pi1) public view {
        vm.assume(!(pi0 <= piT && piT <= pi1 && pi1 < WAD));
        try h.pi(u, uT, pi0, piT, pi1) returns (uint256) {
            assert(false);
        } catch (bytes memory reason) {
            assert(bytes4(reason) == PremiumCurve.InvalidAnchors.selector);
        }
    }

    function testFuzz_curve(uint256 u, uint256 uT, uint256 pi0, uint256 piT, uint256 pi1) public pure {
        uT = bound(uT, 1, WAD - 1);
        pi1 = bound(pi1, 0, WAD - 1);
        piT = bound(piT, 0, pi1);
        pi0 = bound(pi0, 0, piT);
        check_boundedByEndAnchors(u, uT, pi0, piT, pi1);
        check_hitsTheAnchors(uT, pi0, piT, pi1);
    }

    function testFuzz_invalidAnchorsRevert(uint256 u, uint256 uT, uint256 piT, uint256 pi1) public view {
        pi1 = bound(pi1, 0, WAD - 2);
        piT = bound(piT, pi1 + 1, type(uint256).max);
        check_invalidAnchorsRevert(u, uT, 0, piT, pi1);
    }
}
