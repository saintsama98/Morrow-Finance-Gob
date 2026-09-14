// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {WadMath} from "../../src/libraries/WadMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Morrow Finance — unit and fuzz tests for WadMath against OpenZeppelin's mulDiv.
// @author adiii.eth

/// @dev Thin external wrapper so revert-testing cheatcodes see a real sub-call frame; WadMath's functions are
/// `internal` and get inlined when called directly from the test contract, which foundry cannot always intercept.
contract WadMathHarness {
    function mulDivDown(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return WadMath.mulDivDown(x, y, d);
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return WadMath.mulDivUp(x, y, d);
    }
}

/// @notice mulDivDown/mulDivUp against OpenZeppelin Math.mulDiv on 10,000 random triples including max uint
/// values, and mulDivUp - mulDivDown in {0, 1}.
contract WadMathTest is Test {
    WadMathHarness harness;

    function setUp() public {
        harness = new WadMathHarness();
    }

    function testFuzz_mulDivDown_matchesOZ(uint256 x, uint256 y, uint256 d) public {
        d = bound(d, 1, type(uint256).max);
        // Bound to avoid OZ's own overflow revert path so we compare like-for-like on valid inputs.
        vm.assume(!_overflows(x, y, d));

        uint256 expected = Math.mulDiv(x, y, d);
        uint256 actual = WadMath.mulDivDown(x, y, d);
        assertEq(actual, expected, "mulDivDown mismatch vs OZ Math.mulDiv");
    }

    function testFuzz_mulDivUp_matchesOZ(uint256 x, uint256 y, uint256 d) public {
        d = bound(d, 1, type(uint256).max);
        vm.assume(!_overflows(x, y, d));

        uint256 down = Math.mulDiv(x, y, d);
        uint256 remainder = mulmod(x, y, d);
        uint256 expectedUp = remainder == 0 ? down : down + 1;
        vm.assume(expectedUp >= down); // exclude the single case where +1 would overflow type(uint256).max

        uint256 actual = WadMath.mulDivUp(x, y, d);
        assertEq(actual, expectedUp, "mulDivUp mismatch vs OZ Math.mulDiv + remainder");
    }

    function testFuzz_upMinusDown_isZeroOrOne(uint256 x, uint256 y, uint256 d) public {
        d = bound(d, 1, type(uint256).max);
        vm.assume(!_overflows(x, y, d));
        uint256 down = WadMath.mulDivDown(x, y, d);
        vm.assume(down < type(uint256).max);
        uint256 up = WadMath.mulDivUp(x, y, d);
        assertLe(up - down, 1, "mulDivUp - mulDivDown must be 0 or 1");
    }

    function test_mulDivDown_maxValues() public pure {
        // (2^256 - 1) * (2^256 - 1) / (2^256 - 1) == 2^256 - 1
        uint256 max = type(uint256).max;
        assertEq(WadMath.mulDivDown(max, max, max), max);
    }

    function test_mulDivDown_knownVectors() public pure {
        assertEq(WadMath.mulDivDown(10, 3, 2), 15);
        assertEq(WadMath.mulDivUp(10, 3, 2), 15);
        assertEq(WadMath.mulDivDown(7, 3, 2), 10);
        assertEq(WadMath.mulDivUp(7, 3, 2), 11);
        assertEq(WadMath.mulDivDown(0, 100, 7), 0);
    }

    function test_mulDivDown_revertsOnZeroDenominator() public {
        vm.expectRevert(WadMath.DivisionByZero.selector);
        harness.mulDivDown(1, 1, 0);
    }

    function test_mulDivDown_revertsOnOverflow() public {
        vm.expectRevert(WadMath.MulDivOverflow.selector);
        harness.mulDivDown(type(uint256).max, type(uint256).max, 1);
    }

    function testFuzz_wMulDown_wDivDown_roundTrip(uint128 x, uint128 y) public pure {
        vm.assume(y > 0);
        uint256 xw = uint256(x);
        uint256 yw = uint256(y) * 1e10; // keep y within a sane WAD-ish range to avoid trivial 0 cases
        vm.assume(yw > 0);
        uint256 product = WadMath.wMulDown(xw, yw);
        uint256 back = yw == 0 ? 0 : WadMath.wDivDown(product, yw);
        assertLe(back, xw, "round trip through wMul/wDiv must not exceed original (down-rounding)");
    }

    function _overflows(uint256 x, uint256 y, uint256 d) private pure returns (bool) {
        if (x == 0 || y == 0) return false;
        uint256 hi;
        assembly ("memory-safe") {
            let mm := mulmod(x, y, not(0))
            let lo := mul(x, y)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
        return hi >= d;
    }
}
