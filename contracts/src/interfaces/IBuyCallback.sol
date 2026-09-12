// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";

/// @dev Midnight's buyer callback interface, matching `src/interfaces/ICallbacks.sol` in the pinned commit
/// exactly (docs/VERIFY_LOG.md's M0 finding: `pendingFeeIncrease` is `uint256`, not `uint128` as the build
/// spec's section 10.4 pseudocode has it -- getting this wrong changes the function selector Midnight calls
/// and would silently break every fill).
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
