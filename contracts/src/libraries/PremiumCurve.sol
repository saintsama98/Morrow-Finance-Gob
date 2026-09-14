// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {WadMath} from "./WadMath.sol";

// Morrow Finance — three-anchor premium curve pricing the junior tranche's risk premium.
// @author adiii.eth

/// @notice Prices the junior premium `pi(u)` as a function of coverage utilization `u`, a piecewise-linear
/// curve kinked at `uT`.
/// @dev Every intermediate rounds so the published `pi` never understates the premium junior is owed (the
/// result always rounds up).
library PremiumCurve {
    using WadMath for uint256;

    uint256 internal constant WAD = 1e18;

    error InvalidAnchors();

    /// @notice Computes the junior premium at utilization `u`.
    /// @param u Coverage utilization, wad, expected in (0, WAD].
    /// @param uT The kink, wad (0.9e18 by default).
    /// @param pi0 Premium at u -> 0 (limit), wad.
    /// @param piT Premium at u == uT, wad.
    /// @param pi1 Premium at u == WAD, wad.
    /// @return The premium pi(u), wad.
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
