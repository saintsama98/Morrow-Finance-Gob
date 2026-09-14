// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";

// Morrow Finance — Midnight's buyer callback interface, exactly as Midnight itself declares it.
// @author adiii.eth

/// @notice Midnight's buyer callback interface, invoked on every fill against one of our bids.
/// @dev `pendingFeeIncrease` must stay `uint256`: typing it `uint128` would change the function selector
/// Midnight actually calls, and every fill would silently fail.
interface IBuyCallback {
    function onBuy(
        bytes32 id,
        Market memory market,
        uint256 buyerAssets,
        uint256 units,
        uint256 pendingFeeIncrease,
        address buyer,
        bytes memory data
    ) external returns (bytes32);
}
