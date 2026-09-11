// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Market, Offer, CollateralParams} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";

/// @dev Only the Midnight functions this codebase calls, per spec section 4. Struct types (`Market`, `Offer`,
/// `CollateralParams`) are imported directly from the pinned Midnight commit (lib/midnight, see
/// docs/VERIFY_LOG.md) rather than redeclared, so layout can never drift from what's actually deployed.
/// Signatures verified against the pinned commit in M0 (docs/VERIFY_LOG.md section 2.1-2.5); notably
/// `onBuy`'s `pendingFeeIncrease` is `uint256`, not the `uint128` the build spec's section 10.4 listing shows.
interface IMidnightMinimal {
    function take(
        Offer memory offer,
        bytes memory ratifierData,
        uint256 units,
        address taker,
        address receiverIfTakerIsSeller,
        address takerCallback,
        bytes memory takerCallbackData
    ) external returns (uint256 buyerAssets, uint256 sellerAssets);

    function withdraw(Market memory market, uint256 units, address onBehalf, address receiver) external;

    function isAuthorized(address authorizer, address authorized) external view returns (bool);

    function setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external;

    function touchMarket(Market memory market) external returns (bytes32);

    function toMarket(bytes32 id) external view returns (Market memory);

    function updatePositionView(Market memory market, bytes32 id, address user)
        external
        view
        returns (uint128 newCredit, uint128 newPendingFee, uint128 accruedFee);

    function updatePosition(Market memory market, address user)
        external
        returns (uint128 newCredit, uint128 newPendingFee, uint128 accruedFee);

    function withdrawable(bytes32 id) external view returns (uint128);

    function marketState(bytes32 id)
        external
        view
        returns (
            uint128 totalUnits,
            uint128 lossFactor,
            uint128 withdrawable_,
            uint128 continuousFeeCredit,
            uint16 settlementFeeCbp0,
            uint16 settlementFeeCbp1,
            uint16 settlementFeeCbp2,
            uint16 settlementFeeCbp3,
            uint16 settlementFeeCbp4,
            uint16 settlementFeeCbp5,
            uint16 settlementFeeCbp6,
            uint32 continuousFee,
            uint8 tickSpacing
        );
}
