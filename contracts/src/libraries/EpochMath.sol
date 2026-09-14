// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {WadMath} from "./WadMath.sol";

// Morrow Finance — pro-rata epoch fulfillment math shared by the senior and junior vaults.
// @author adiii.eth

/// @notice Pro-rata epoch fulfillment math shared by the senior and junior vaults. No storage access.
/// @dev Every share/asset conversion rounds against the party being serviced (down), extended here to
/// per-controller pro-rata claims of a shared epoch fulfillment.
library EpochMath {
    using WadMath for uint256;

    uint256 internal constant WAD = 1e18;

    /// @notice Redemption fulfillment price: min(close snapshot, fulfillment-time price). No escaping a loss
    /// realized while the request waits.
    function redemptionPriceWad(uint256 ppsCloseWad, uint256 ppsNowWad) internal pure returns (uint256) {
        return ppsCloseWad < ppsNowWad ? ppsCloseWad : ppsNowWad;
    }

    /// @notice Junior deposit fulfillment price: max(close snapshot, fulfillment-time price). No capturing a
    /// value jump while the request waits.
    function depositPriceWad(uint256 ppsCloseWad, uint256 ppsNowWad) internal pure returns (uint256) {
        return ppsCloseWad > ppsNowWad ? ppsCloseWad : ppsNowWad;
    }

    /// @notice How many of the remaining requested shares can be redeemed given the assets on hand.
    /// @dev shares = min(remainingShares, floor(availableAssets * WAD / priceWad)); flooring here (rather than
    /// ceiling) ensures the resulting assetsForShares never exceeds availableAssets.
    function sharesFillable(uint256 remainingShares, uint256 availableAssets, uint256 priceWad)
        internal
        pure
        returns (uint256)
    {
        if (priceWad == 0) return 0;
        uint256 fillableByAssets = availableAssets.mulDivDown(WAD, priceWad);
        return remainingShares < fillableByAssets ? remainingShares : fillableByAssets;
    }

    /// @notice assets = floor(shares * priceWad / WAD), rounded down.
    function assetsForShares(uint256 shares, uint256 priceWad) internal pure returns (uint256) {
        return shares.mulDivDown(priceWad, WAD);
    }

    /// @notice shares = floor(assets * WAD / priceWad), rounded down against the depositor.
    function sharesForAssets(uint256 assets, uint256 priceWad) internal pure returns (uint256) {
        if (priceWad == 0) return 0;
        return assets.mulDivDown(WAD, priceWad);
    }

    /// @notice A single controller's claimable share of an epoch's fulfillment so far.
    /// @dev Every controller in the epoch gets the same pro-rata fill, floor-rounded against the claimant so
    /// the sum over all controllers never exceeds sharesFulfilled.
    function claimableShares(uint256 requested, uint256 sharesFulfilled, uint256 totalShares, uint256 alreadyClaimed)
        internal
        pure
        returns (uint256)
    {
        if (totalShares == 0) return 0;
        uint256 entitled = requested.mulDivDown(sharesFulfilled, totalShares);
        return entitled > alreadyClaimed ? entitled - alreadyClaimed : 0;
    }

    /// @notice Matching claimable share of assetsFulfilled for the same controller, same pro-rata rounding.
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
