// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Market, Offer, CollateralParams} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";

// Morrow Finance — the minimal slice of Midnight's own interface this codebase calls.
// @author adiii.eth

/// @notice Only the Midnight functions this codebase calls.
/// @dev Struct types (`Market`, `Offer`, `CollateralParams`) are imported directly from the pinned Midnight
/// commit rather than redeclared, so layout can never drift from what's actually deployed.
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

    function setConsumed(bytes32 group, uint128 amount, address onBehalf) external;

    /// @notice Piecewise-linear interpolation between a market's settlement fee breakpoints.
    function settlementFee(bytes32 id, uint256 timeToMaturity) external view returns (uint256);

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
