// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: three-anchor premium curve pricing the junior tranche's risk premium.
// @author adiii.eth

pragma solidity 0.8.34;

import {wadMath} from "./wadMath.sol";

/// @notice Premium senior pays junior as a function of coverage utilisation.
library premiumCurve {
    using wadMath for uint256;

    uint256 internal constant WAD = 1e18;

    error InvalidAnchors();

    /// @notice Piecewise linear premium through three anchors, with a kink at uT.
    function pi(uint256 u, uint256 uT, uint256 pi0, uint256 piT, uint256 pi1) internal pure returns (uint256) {
        if (!(pi0 <= piT && piT <= pi1 && pi1 < WAD)) revert InvalidAnchors();

        if (u > WAD) u = WAD;

        if (u < uT) {
            uint256 delta = (uT - u).mulDivDown(piT - pi0, uT);
            return piT - delta;
        } else {
            uint256 delta = (u - uT).mulDivUp(pi1 - piT, WAD - uT);
            return piT + delta;
        }
    }
}
