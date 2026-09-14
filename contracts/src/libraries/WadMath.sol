// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

// Morrow Finance — full-precision fixed-point math shared by every pricing and accounting library.
// @author adiii.eth

/// @notice Full-precision (512-bit intermediate) fixed-point math. Every division direction is explicit; there
/// is never a bare `a * b / c` anywhere in this codebase.
/// @dev mulDiv is the standard 512-bit-mulmod algorithm (Remco Bloemen), the same one used by OpenZeppelin's
/// Math.mulDiv and Solady's FixedPointMathLib.fullMulDiv.
library WadMath {
    uint256 internal constant WAD = 1e18;

    error DivisionByZero();
    error MulDivOverflow();

    /// @notice Computes floor(x * y / d) without intermediate overflow, even when x * y exceeds 256 bits.
    /// @param x First factor.
    /// @param y Second factor.
    /// @param d Divisor.
    /// @return result floor(x * y / d).
    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        if (d == 0) revert DivisionByZero();

        // 512-bit multiply: [prod1 prod0] = x * y.
        uint256 prod0;
        uint256 prod1;
        assembly ("memory-safe") {
            let mm := mulmod(x, y, not(0))
            prod0 := mul(x, y)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        // Fits in 256 bits: single-word division suffices.
        if (prod1 == 0) {
            unchecked {
                return prod0 / d;
            }
        }

        if (d <= prod1) revert MulDivOverflow();

        unchecked {
            // Subtract the remainder from [prod1 prod0] to make division exact.
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(x, y, d)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of d.
            uint256 twos = d & (~d + 1);
            assembly ("memory-safe") {
                d := div(d, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Newton-Raphson inverse of d modulo 2^256 (d is odd after the factoring above).
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

    /// @notice Computes ceil(x * y / d) without intermediate overflow.
    /// @param x First factor.
    /// @param y Second factor.
    /// @param d Divisor.
    /// @return result ceil(x * y / d).
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        result = mulDivDown(x, y, d);
        unchecked {
            if (mulmod(x, y, d) > 0) {
                if (result == type(uint256).max) revert MulDivOverflow();
                result += 1;
            }
        }
    }

    /// @notice floor(x * y / WAD): multiply two wad-scaled numbers, rounding down.
    function wMulDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, y, WAD);
    }

    /// @notice ceil(x * y / WAD): multiply two wad-scaled numbers, rounding up.
    function wMulUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, y, WAD);
    }

    /// @notice floor(x * WAD / y): divide two wad-scaled numbers, rounding down.
    function wDivDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, WAD, y);
    }

    /// @notice ceil(x * WAD / y): divide two wad-scaled numbers, rounding up.
    function wDivUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, WAD, y);
    }
}
