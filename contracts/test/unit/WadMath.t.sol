// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: unit and fuzz tests for wadMath against OpenZeppelin's mulDiv.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {wadMath} from "../../src/libraries/wadMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract WadMathHarness {
    function mulDivDown(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return wadMath.mulDivDown(x, y, d);
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return wadMath.mulDivUp(x, y, d);
    }
}

contract WadMathTest is Test {
    WadMathHarness harness;

    function setUp() public {
        harness = new WadMathHarness();
    }

    function testFuzz_mulDivDown_matchesOZ(uint256 x, uint256 y, uint256 d) public {
        d = bound(d, 1, type(uint256).max);
        vm.assume(!_overflows(x, y, d));

        uint256 expected = Math.mulDiv(x, y, d);
        uint256 actual = wadMath.mulDivDown(x, y, d);
        assertEq(actual, expected, "mulDivDown mismatch vs OZ Math.mulDiv");
    }

    function testFuzz_mulDivUp_matchesOZ(uint256 x, uint256 y, uint256 d) public {
        d = bound(d, 1, type(uint256).max);
        vm.assume(!_overflows(x, y, d));

        uint256 down = Math.mulDiv(x, y, d);
        uint256 remainder = mulmod(x, y, d);
        if (remainder != 0 && down == type(uint256).max) {
            vm.expectRevert(wadMath.MulDivOverflow.selector);
            this.mulDivUpExternal(x, y, d);
            return;
        }
        uint256 expectedUp = remainder == 0 ? down : down + 1;

        uint256 actual = wadMath.mulDivUp(x, y, d);
        assertEq(actual, expectedUp, "mulDivUp mismatch vs OZ Math.mulDiv + remainder");
    }

    function testFuzz_upMinusDown_isZeroOrOne(uint256 x, uint256 y, uint256 d) public {
        d = bound(d, 1, type(uint256).max);
        vm.assume(!_overflows(x, y, d));
        uint256 down = wadMath.mulDivDown(x, y, d);
        vm.assume(down < type(uint256).max);
        uint256 up = wadMath.mulDivUp(x, y, d);
        assertLe(up - down, 1, "mulDivUp - mulDivDown must be 0 or 1");
    }

    function test_mulDivDown_maxValues() public pure {
        uint256 max = type(uint256).max;
        assertEq(wadMath.mulDivDown(max, max, max), max);
    }

    function test_mulDivDown_knownVectors() public pure {
        assertEq(wadMath.mulDivDown(10, 3, 2), 15);
        assertEq(wadMath.mulDivUp(10, 3, 2), 15);
        assertEq(wadMath.mulDivDown(7, 3, 2), 10);
        assertEq(wadMath.mulDivUp(7, 3, 2), 11);
        assertEq(wadMath.mulDivDown(0, 100, 7), 0);
    }

    function test_mulDivDown_revertsOnZeroDenominator() public {
        vm.expectRevert(wadMath.DivisionByZero.selector);
        harness.mulDivDown(1, 1, 0);
    }

    function test_mulDivDown_revertsOnOverflow() public {
        vm.expectRevert(wadMath.MulDivOverflow.selector);
        harness.mulDivDown(type(uint256).max, type(uint256).max, 1);
    }

    function testFuzz_wMulDown_wDivDown_roundTrip(uint128 x, uint128 y) public pure {
        vm.assume(y > 0);
        uint256 xw = uint256(x);
        uint256 yw = uint256(y) * 1e10;
        vm.assume(yw > 0);
        uint256 product = wadMath.wMulDown(xw, yw);
        uint256 back = yw == 0 ? 0 : wadMath.wDivDown(product, yw);
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

    function test_mulDivUp_revertsWhenRoundingUpOverflows() public {
        uint256 max = type(uint256).max;
        vm.expectRevert(wadMath.MulDivOverflow.selector);
        this.mulDivUpExternal(max - 2, max - 1, max - 3);
    }

    function mulDivUpExternal(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return wadMath.mulDivUp(x, y, d);
    }
}
