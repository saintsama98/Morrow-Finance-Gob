// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: Midnight's buyer callback interface, exactly as Midnight itself declares it.
// @author adiii.eth

pragma solidity 0.8.34;

import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";

interface iBuyCallback {
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
