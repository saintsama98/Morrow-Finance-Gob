// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";

/// @dev Matches src/interfaces/IRatifier.sol in the pinned Midnight commit exactly.
interface IRatifier {
    function isRatified(Offer memory offer, bytes memory ratifierData, address taker) external view returns (bytes32);
}
