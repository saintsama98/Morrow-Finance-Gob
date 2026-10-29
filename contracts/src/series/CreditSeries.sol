// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: a single dated credit series, assembled from its storage, marks, deployment, funding and settlement.
// @author adiii.eth

pragma solidity 0.8.34;

import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {SeriesStorage} from "./modules/SeriesStorage.sol";
import {SeriesSettlement} from "./modules/SeriesSettlement.sol";
import {IMidnightMinimal} from "../interfaces/IMidnightMinimal.sol";
import {SeriesParams} from "../interfaces/ISeries.sol";

/// @notice One dated series: lends into a basket of Midnight markets with one maturity and pays senior first.
contract CreditSeries is SeriesSettlement {
    constructor(
        IMidnightMinimal midnight,
        address setterRatifier,
        address usdc,
        address core,
        Market[] memory basketMarkets,
        SeriesParams memory p
    ) SeriesStorage(midnight, setterRatifier, usdc, core, basketMarkets, p) {}
}
