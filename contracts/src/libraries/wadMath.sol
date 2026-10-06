// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: full-precision fixed-point math shared by every pricing and accounting library.
// @author adiii.eth

pragma solidity 0.8.34;

/// @notice Full-precision multiply-then-divide with explicit rounding.
library wadMath {
    uint256 internal constant WAD = 1e18;

    error DivisionByZero();
    error MulDivOverflow();

    /// @notice x times y divided by d, rounded down, without intermediate overflow.
    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        if (d == 0) revert DivisionByZero();

        uint256 prod0;
        uint256 prod1;
        assembly ("memory-safe") {
            let mm := mulmod(x, y, not(0))
            prod0 := mul(x, y)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        if (prod1 == 0) {
            unchecked {
                return prod0 / d;
            }
        }

        if (d <= prod1) revert MulDivOverflow();

        unchecked {
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(x, y, d)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = d & (~d + 1);
            assembly ("memory-safe") {
                d := div(d, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inv = (3 * d) ^ 2;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;

            result = prod0 * inv;
        }
    }

    /// @notice x times y divided by d, rounded up.
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        result = mulDivDown(x, y, d);
        unchecked {
            if (mulmod(x, y, d) > 0) {
                if (result == type(uint256).max) revert MulDivOverflow();
                result += 1;
            }
        }
    }

    /// @notice x times y in WAD, rounded down.
    function wMulDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, y, WAD);
    }

    /// @notice x times y in WAD, rounded up.
    function wMulUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, y, WAD);
    }

    /// @notice x divided by y in WAD, rounded down.
    function wDivDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, WAD, y);
    }

    /// @notice x divided by y in WAD, rounded up.
    function wDivUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, WAD, y);
    }
}
