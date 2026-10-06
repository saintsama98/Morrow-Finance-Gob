// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: pro-rata epoch fulfillment math shared by the senior and junior vaults.
// @author adiii.eth

pragma solidity 0.8.34;

import {wadMath} from "./wadMath.sol";

/// @notice Batch prices and pro-rata entitlements for queued entries and exits.
library epochMath {
    using wadMath for uint256;

    uint256 internal constant WAD = 1e18;

    /// @notice Exit price: the lower of the close and current prices.
    function redemptionPriceWad(uint256 ppsCloseWad, uint256 ppsNowWad) internal pure returns (uint256) {
        return ppsCloseWad < ppsNowWad ? ppsCloseWad : ppsNowWad;
    }

    /// @notice Entry price: the higher of the close and current prices.
    function depositPriceWad(uint256 ppsCloseWad, uint256 ppsNowWad) internal pure returns (uint256) {
        return ppsCloseWad > ppsNowWad ? ppsCloseWad : ppsNowWad;
    }

    /// @notice Shares a batch can fill with the assets available, rounded down.
    function sharesFillable(uint256 remainingShares, uint256 availableAssets, uint256 priceWad)
        internal
        pure
        returns (uint256)
    {
        if (priceWad == 0) return 0;
        uint256 fillableByAssets = availableAssets.mulDivDown(WAD, priceWad);
        return remainingShares < fillableByAssets ? remainingShares : fillableByAssets;
    }

    /// @notice Assets paid for shares at a price, rounded down.
    function assetsForShares(uint256 shares, uint256 priceWad) internal pure returns (uint256) {
        return shares.mulDivDown(priceWad, WAD);
    }

    /// @notice Shares minted for assets at a price, rounded down.
    function sharesForAssets(uint256 assets, uint256 priceWad) internal pure returns (uint256) {
        if (priceWad == 0) return 0;
        return assets.mulDivDown(WAD, priceWad);
    }

    /// @notice A requester's pro-rata filled shares not yet claimed.
    function claimableShares(uint256 requested, uint256 sharesFulfilled, uint256 totalShares, uint256 alreadyClaimed)
        internal
        pure
        returns (uint256)
    {
        if (totalShares == 0) return 0;
        uint256 entitled = requested.mulDivDown(sharesFulfilled, totalShares);
        return entitled > alreadyClaimed ? entitled - alreadyClaimed : 0;
    }

    /// @notice A requester's pro-rata filled assets not yet claimed.
    function claimableAssets(uint256 requested, uint256 assetsFulfilled, uint256 totalShares, uint256 alreadyClaimed)
        internal
        pure
        returns (uint256)
    {
        if (totalShares == 0) return 0;
        uint256 entitled = requested.mulDivDown(assetsFulfilled, totalShares);
        return entitled > alreadyClaimed ? entitled - alreadyClaimed : 0;
    }
}
