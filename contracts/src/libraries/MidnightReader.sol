// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {IdLib} from "@morpho-org/midnight/src/libraries/IdLib.sol";
import {IMidnightMinimal} from "../interfaces/IMidnightMinimal.sol";

// Morrow Finance — thin read wrappers isolating every live call site into the Midnight protocol.
// @author adiii.eth

/// @notice Thin read wrappers over IMidnightMinimal, isolating every call site that depends on a live Midnight
/// read.
/// @dev Nothing here is pure: every function either reads or writes Midnight state, so this is a stateless
/// library of passthrough helpers, not a math library.
library MidnightReader {
    /// @notice Reads the canonical market struct for a market id, straight from Midnight.
    function marketConfig(IMidnightMinimal midnight, bytes32 id) internal view returns (Market memory) {
        return midnight.toMarket(id);
    }

    /// @notice Computes a market's id from its full struct.
    function marketId(Market memory market) internal pure returns (bytes32) {
        return IdLib.toId(market);
    }

    /// @notice Reads a series' projected redeemable face value in one market: credit minus pending fee. View
    /// only; does not accrue or realize the latest loss factor on chain.
    /// @return faceValue credit - pendingFee, the projected redeemable amount.
    /// @return credit The position's raw credit.
    /// @return pendingFee The position's raw pending fee.
    function projectedRedeemableView(IMidnightMinimal midnight, Market memory market, bytes32 id, address series)
        internal
        view
        returns (uint256 faceValue, uint128 credit, uint128 pendingFee)
    {
        (credit, pendingFee,) = midnight.updatePositionView(market, id, series);
        faceValue = uint256(credit) - uint256(pendingFee);
    }

    /// @notice Same as projectedRedeemableView, but writes the latest loss factor and fee accrual on chain
    /// first. Permissionless on Midnight's side.
    function projectedRedeemableSynced(IMidnightMinimal midnight, Market memory market, address series)
        internal
        returns (uint256 faceValue, uint128 credit, uint128 pendingFee)
    {
        (credit, pendingFee,) = midnight.updatePosition(market, series);
        faceValue = uint256(credit) - uint256(pendingFee);
    }

    /// @notice Reads how much a market's shared, first-come-first-served withdrawable liquidity currently
    /// holds.
    function withdrawableLiquidity(IMidnightMinimal midnight, bytes32 id) internal view returns (uint128) {
        return midnight.withdrawable(id);
    }
}
