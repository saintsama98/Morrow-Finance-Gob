// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {WadMath} from "./WadMath.sol";

/// @dev Pro-rata epoch fulfillment math shared by SeniorVault and JuniorVault, sections 21.3, 22.2, 22.3. No
/// storage access. Every share/asset conversion rounds against the party being serviced (down), matching section
/// 5.4's "vault share mint on deposit: down, against the depositor" / "vault assets paid on redemption: down,
/// against the redeemer" rules, extended here to per-controller pro-rata claims of a shared epoch fulfillment.
library EpochMath {
    using WadMath for uint256;

    uint256 internal constant WAD = 1e18;

    /// @dev Redemption fulfillment price, section 21.3/22.3: min(close snapshot, fulfillment-time price). No
    /// escaping a loss realized while the request waits.
    function redemptionPriceWad(uint256 ppsCloseWad, uint256 ppsNowWad) internal pure returns (uint256) {
        return ppsCloseWad < ppsNowWad ? ppsCloseWad : ppsNowWad;
    }

    /// @dev Junior deposit fulfillment price, section 22.2: max(close snapshot, fulfillment-time price). No
    /// capturing a recovery jump while the request waits.
    function depositPriceWad(uint256 ppsCloseWad, uint256 ppsNowWad) internal pure returns (uint256) {
        return ppsCloseWad > ppsNowWad ? ppsCloseWad : ppsNowWad;
    }

    /// @dev How many of the remaining requested shares can be redeemed given the assets on hand, at `priceWad`.
    /// shares = min(remainingShares, floor(availableAssets * WAD / priceWad)); flooring here (rather than
    /// ceiling) ensures the resulting `assetsForShares` never exceeds `availableAssets`.
    function sharesFillable(uint256 remainingShares, uint256 availableAssets, uint256 priceWad)
        internal
        pure
        returns (uint256)
    {
        if (priceWad == 0) return 0;
        uint256 fillableByAssets = availableAssets.mulDivDown(WAD, priceWad);
        return remainingShares < fillableByAssets ? remainingShares : fillableByAssets;
    }

    /// @dev assets = floor(shares * priceWad / WAD). Section 21.3 step 3: "rounded down".
    function assetsForShares(uint256 shares, uint256 priceWad) internal pure returns (uint256) {
        return shares.mulDivDown(priceWad, WAD);
    }

    /// @dev shares = floor(assets * WAD / priceWad). Section 22.2: "rounded down" (against the junior depositor).
    function sharesForAssets(uint256 assets, uint256 priceWad) internal pure returns (uint256) {
        if (priceWad == 0) return 0;
        return assets.mulDivDown(WAD, priceWad);
    }

    /// @dev Per controller, section 21.3 step 4: claimable shares = requested * sharesFulfilled / totalShares -
    /// sharesClaimed. Every controller in the epoch gets the same pro-rata fill, floor-rounded against the
    /// claimant so the sum over all controllers never exceeds sharesFulfilled.
    function claimableShares(uint256 requested, uint256 sharesFulfilled, uint256 totalShares, uint256 alreadyClaimed)
        internal
        pure
        returns (uint256)
    {
        if (totalShares == 0) return 0;
        uint256 entitled = requested.mulDivDown(sharesFulfilled, totalShares);
        return entitled > alreadyClaimed ? entitled - alreadyClaimed : 0;
    }

    /// @dev Matching share of assetsFulfilled for the same controller, same pro-rata rounding.
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
