// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";

// Morrow Finance — Midnight's offer-ratification interface, exactly as Midnight itself declares it.
// @author adiii.eth

/// @notice Interface for a Midnight ratifier: proves an offer was authorized by its maker.
interface IRatifier {
    function isRatified(Offer memory offer, bytes memory ratifierData, address taker) external view returns (bytes32);
}
