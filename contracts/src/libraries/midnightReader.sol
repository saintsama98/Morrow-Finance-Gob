// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: thin read wrappers isolating every live call site into the Midnight protocol.
// @author adiii.eth

pragma solidity 0.8.34;

import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {IdLib} from "@morpho-org/midnight/src/libraries/IdLib.sol";
import {iMidnightMinimal} from "../interfaces/iMidnightMinimal.sol";

library midnightReader {
    function marketConfig(iMidnightMinimal midnight, bytes32 id) internal view returns (Market memory) {
        return midnight.toMarket(id);
    }

    function marketId(Market memory market) internal pure returns (bytes32) {
        return IdLib.toId(market);
    }

    function projectedRedeemableView(iMidnightMinimal midnight, Market memory market, bytes32 id, address series)
        internal
        view
        returns (uint256 faceValue, uint128 credit, uint128 pendingFee)
    {
        (credit, pendingFee,) = midnight.updatePositionView(market, id, series);
        faceValue = uint256(credit) - uint256(pendingFee);
    }

    function projectedRedeemableSynced(iMidnightMinimal midnight, Market memory market, address series)
        internal
        returns (uint256 faceValue, uint128 credit, uint128 pendingFee)
    {
        (credit, pendingFee,) = midnight.updatePosition(market, series);
        faceValue = uint256(credit) - uint256(pendingFee);
    }

    function withdrawableLiquidity(iMidnightMinimal midnight, bytes32 id) internal view returns (uint128) {
        return midnight.withdrawable(id);
    }
}
