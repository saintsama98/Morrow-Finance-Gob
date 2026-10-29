// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the protocol's single custody and accounting contract, assembled from its core modules.
// @author adiii.eth

pragma solidity 0.8.34;

import {CoreStorage} from "./modules/CoreStorage.sol";
import {CoreSeriesLifecycle} from "./modules/CoreSeriesLifecycle.sol";
import {SeriesFactory} from "../series/SeriesFactory.sol";
import {IParking} from "../parking/IParking.sol";

/// @notice Custody and books for both tranches: holds idle cash in parking, opens series and rolls settled cash.
contract SeriesCore is CoreSeriesLifecycle {
    constructor(
        address usdc,
        SeriesFactory factory,
        IParking parking,
        address governance_,
        address allocator_,
        address curator_,
        address sentinel_
    ) CoreStorage(usdc, factory, parking, governance_, allocator_, curator_, sentinel_) {}
}
