// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: Midnight's offer-ratification interface, exactly as Midnight itself declares it.
// @author adiii.eth

pragma solidity 0.8.34;

import {Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";

/// @notice Midnight offer ratifier.
interface iRatifier {
    /// @notice Returns the success value when an offer is ratified.
    function isRatified(Offer memory offer, bytes memory ratifierData, address taker) external view returns (bytes32);
}
