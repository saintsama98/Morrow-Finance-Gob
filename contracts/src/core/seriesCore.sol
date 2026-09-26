// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the protocol's single custody and accounting contract, assembled from its core modules.
// @author adiii.eth

pragma solidity 0.8.34;

import {coreStorage} from "./modules/coreStorage.sol";
import {coreSeriesLifecycle} from "./modules/coreSeriesLifecycle.sol";
import {seriesFactory} from "../series/seriesFactory.sol";
import {iParking} from "../parking/iParking.sol";

contract seriesCore is coreSeriesLifecycle {
    constructor(
        address usdc,
        seriesFactory factory,
        iParking parking,
        address governance_,
        address allocator_,
        address curator_,
        address sentinel_
    ) coreStorage(usdc, factory, parking, governance_, allocator_, curator_, sentinel_) {}
}
