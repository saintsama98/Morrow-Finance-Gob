// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {IdLib} from "@morpho-org/midnight/src/libraries/IdLib.sol";
import {IMidnightMinimal} from "../interfaces/IMidnightMinimal.sol";

/// @dev Thin read wrappers over IMidnightMinimal, isolating every call site that depends on a live Midnight
/// read (section 3.2, section 12.1: "read live through MidnightReader, never estimated"). Nothing here is
/// pure -- every function either reads or writes Midnight state -- so this is a stateless library of
/// passthrough helpers, not a math library.
library MidnightReader {
    /// @dev section 7.2: on-chain eligibility reads the market config for a proposed basket entry.
    function marketConfig(IMidnightMinimal midnight, bytes32 id) internal view returns (Market memory) {
        return midnight.toMarket(id);
    }

    function marketId(Market memory market) internal pure returns (bytes32) {
        return IdLib.toId(market);
    }

    /// @dev section 12.2: E_i(t) = credit_i(t) - pendingFee_i(t), the "projected redeemable amount" per
    /// Midnight's own natspec. View-only (does not accrue/realize the latest loss factor on chain).
    function projectedRedeemableView(IMidnightMinimal midnight, Market memory market, bytes32 id, address series)
        internal
        view
        returns (uint256 faceValue, uint128 credit, uint128 pendingFee)
    {
        (credit, pendingFee,) = midnight.updatePositionView(market, id, series);
        faceValue = uint256(credit) - uint256(pendingFee);
    }

    /// @dev Same as projectedRedeemableView, but writes the latest loss factor and fee accrual on chain first
    /// (section 12.3 `sync`). Permissionless on Midnight's side.
    function projectedRedeemableSynced(IMidnightMinimal midnight, Market memory market, address series)
        internal
        returns (uint256 faceValue, uint128 credit, uint128 pendingFee)
    {
        (credit, pendingFee,) = midnight.updatePosition(market, series);
        faceValue = uint256(credit) - uint256(pendingFee);
    }

    /// @dev section 2.5: `withdrawable` is shared by all lenders in the market, first come first served, and
    /// grows with every repayment or liquidation before or after maturity.
    function withdrawableLiquidity(IMidnightMinimal midnight, bytes32 id) internal view returns (uint128) {
        return midnight.withdrawable(id);
    }
}
