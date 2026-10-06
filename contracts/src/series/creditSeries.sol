// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: a single dated credit series, assembled from its storage, marks, deployment, funding and settlement.
// @author adiii.eth

pragma solidity 0.8.34;

import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {seriesStorage} from "./modules/seriesStorage.sol";
import {seriesSettlement} from "./modules/seriesSettlement.sol";
import {iMidnightMinimal} from "../interfaces/iMidnightMinimal.sol";
import {SeriesParams} from "../interfaces/iSeries.sol";

/// @notice One dated series: lends into a basket of Midnight markets with one maturity and pays senior first.
contract creditSeries is seriesSettlement {
    constructor(
        iMidnightMinimal midnight,
        address setterRatifier,
        address usdc,
        address core,
        Market[] memory basketMarkets,
        SeriesParams memory p
    ) seriesStorage(midnight, setterRatifier, usdc, core, basketMarkets, p) {}
}
