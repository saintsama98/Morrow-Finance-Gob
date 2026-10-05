// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: junior-first allocation of a realized drop in the core's parking claim price.
// @author adiii.eth

pragma solidity 0.8.34;

import {wadMath} from "./wadMath.sol";

library idleLossMath {
    using wadMath for uint256;

    uint256 internal constant PRICE_SCALE = 1e36;

    function claimPrice(uint256 parked, uint256 totalClaimsWithVirtual) internal pure returns (uint256) {
        return (parked + 1).mulDivDown(PRICE_SCALE, totalClaimsWithVirtual);
    }

    function effectiveClaims(
        uint256 seniorClaims,
        uint256 juniorClaims,
        uint256 totalClaimsWithVirtual,
        uint256 parked,
        uint256 mark
    ) internal pure returns (uint256 seniorOut, uint256 juniorOut, uint256 seniorLoss) {
        seniorOut = seniorClaims;
        juniorOut = juniorClaims;
        if (mark == 0 || seniorClaims == 0 || juniorClaims == 0) return (seniorOut, juniorOut, 0);
        uint256 price = claimPrice(parked, totalClaimsWithVirtual);
        if (price >= mark) return (seniorOut, juniorOut, 0);
        seniorLoss = seniorClaims.mulDivDown(mark - price, PRICE_SCALE);
        uint256 moved = seniorLoss.mulDivDown(totalClaimsWithVirtual, parked + 1);
        if (moved > juniorClaims) moved = juniorClaims;
        seniorOut = seniorClaims + moved;
        juniorOut = juniorClaims - moved;
    }
}
