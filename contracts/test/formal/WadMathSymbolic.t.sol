// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: symbolic properties of the rounding helpers (Halmos check_ targets with fuzz twins).
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {WadMath} from "../../src/libraries/WadMath.sol";

contract WadMathSymbolicTest is Test {
    uint256 constant WAD = 1e18;

    /// Rounding up exceeds rounding down by at most one, and only when there is a remainder.
    function check_upMinusDownAtMostOne(uint256 x, uint256 y, uint256 d) public pure {
        vm.assume(x <= type(uint128).max && y <= type(uint128).max && d > 0);
        uint256 down = WadMath.mulDivDown(x, y, d);
        uint256 up = WadMath.mulDivUp(x, y, d);
        assert(up - down == (mulmod(x, y, d) > 0 ? 1 : 0));
    }

    /// Below 2^256 the product fits, so the full-precision path agrees with plain division.
    function check_matchesPlainDivisionWhenNoOverflow(uint256 x, uint256 y, uint256 d) public pure {
        vm.assume(x <= type(uint128).max && y <= type(uint128).max && d > 0);
        assert(WadMath.mulDivDown(x, y, d) == x * y / d);
    }

    function check_wadHelpersMatch(uint256 x, uint256 y) public pure {
        vm.assume(x <= type(uint128).max && y <= type(uint128).max && y > 0);
        assert(WadMath.wMulDown(x, y) == WadMath.mulDivDown(x, y, WAD));
        assert(WadMath.wMulUp(x, y) == WadMath.mulDivUp(x, y, WAD));
        assert(WadMath.wDivDown(x, y) == WadMath.mulDivDown(x, WAD, y));
        assert(WadMath.wDivUp(x, y) == WadMath.mulDivUp(x, WAD, y));
    }

    function testFuzz_rounding(uint256 x, uint256 y, uint256 d) public pure {
        x = bound(x, 0, type(uint128).max);
        y = bound(y, 0, type(uint128).max);
        d = bound(d, 1, type(uint256).max);
        check_upMinusDownAtMostOne(x, y, d);
        check_matchesPlainDivisionWhenNoOverflow(x, y, d);
        check_wadHelpersMatch(x, bound(y, 1, type(uint128).max));
    }
}
