// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the minimal slice of Midnight's own interface this codebase calls.
// @author adiii.eth

pragma solidity 0.8.34;

import {Market, Offer, CollateralParams} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";

/// @notice The part of Midnight the protocol calls.
interface iMidnightMinimal {
    /// @notice Takes an offer.
    function take(
        Offer memory offer,
        bytes memory ratifierData,
        uint256 units,
        address taker,
        address receiverIfTakerIsSeller,
        address takerCallback,
        bytes memory takerCallbackData
    ) external returns (uint256 buyerAssets, uint256 sellerAssets);

    /// @notice Withdraws repaid units from a market.
    function withdraw(Market memory market, uint256 units, address onBehalf, address receiver) external;

    /// @notice Whether an address may act for another.
    function isAuthorized(address authorizer, address authorized) external view returns (bool);

    /// @notice Sets an authorization.
    function setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external;

    /// @notice Marks an offer group amount as consumed.
    function setConsumed(bytes32 group, uint128 amount, address onBehalf) external;

    /// @notice Settlement fee for a market at a time to maturity.
    function settlementFee(bytes32 id, uint256 timeToMaturity) external view returns (uint256);

    /// @notice Creates a market if needed and returns its id.
    function touchMarket(Market memory market) external returns (bytes32);

    /// @notice Market parameters for an id.
    function toMarket(bytes32 id) external view returns (Market memory);

    /// @notice Position credit and fees after accrual, without writing.
    function updatePositionView(Market memory market, bytes32 id, address user)
        external
        view
        returns (uint128 newCredit, uint128 newPendingFee, uint128 accruedFee);

    /// @notice Accrues and writes a position.
    function updatePosition(Market memory market, address user)
        external
        returns (uint128 newCredit, uint128 newPendingFee, uint128 accruedFee);

    /// @notice Cash withdrawable from a market.
    function withdrawable(bytes32 id) external view returns (uint128);

    /// @notice Market totals, loss factor and fee state.
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
