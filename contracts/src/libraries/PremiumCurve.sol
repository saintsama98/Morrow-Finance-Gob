// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {WadMath} from "./WadMath.sol";

/// @dev Three-anchor premium curve, section 9.2. `pi(u)` is the junior premium as a function of coverage
/// utilization `u = COV / a`, kinked at `uT` (0.9e18 by convention, but passed explicitly so it stays pure).
/// Every intermediate rounds so the published `pi` never understates the premium junior is owed (rounds up
/// overall), matching section 5.4's rounding table.
library PremiumCurve {
    using WadMath for uint256;

    uint256 internal constant WAD = 1e18;

    error InvalidAnchors();

    /// @param u coverage utilization, wad, expected in (0, WAD] by the caller (section 8.2's check C1).
    /// @param uT the kink, wad (0.9e18 by default).
    /// @param pi0 premium at u -> 0 (limit), wad.
    /// @param piT premium at u == uT, wad.
    /// @param pi1 premium at u == WAD, wad.
    function pi(uint256 u, uint256 uT, uint256 pi0, uint256 piT, uint256 pi1) internal pure returns (uint256) {
        if (!(pi0 <= piT && piT <= pi1 && pi1 < WAD)) revert InvalidAnchors();

        // Clamp u to WAD: u can exceed WAD only from a caller bug (COV > a), never a valid state.
        if (u > WAD) u = WAD;

        if (u < uT) {
            // pi = piT - mulDivDown(uT - u, piT - pi0, uT)  -- the subtracted term rounds down, so pi rounds up.
            uint256 delta = (uT - u).mulDivDown(piT - pi0, uT);
            return piT - delta;
        } else {
            // pi = piT + mulDivUp(u - uT, pi1 - piT, WAD - uT)  -- rounds pi up.
            uint256 delta = (u - uT).mulDivUp(pi1 - piT, WAD - uT);
            return piT + delta;
        }
    }
}
