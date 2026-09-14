// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SeriesRegistry} from "./SeriesRegistry.sol";
import {Series} from "../../../src/series/Series.sol";
import {SeriesState} from "../../../src/interfaces/ISeries.sol";

// Morrow Finance — invariant-suite handler for series settlement and fee claims.
// @author adiii.eth

/// @notice Fuzz handler: startSettlement, collect, settle, writeOff, claimFee. Settled/written-off series are
/// deliberately kept in the registry's activeSeries list (not pruned) so collect()/claimFee() can still target
/// them afterward -- collect(i) stays callable forever, and every later receipt is a recovery. Only cancel (in
/// AllocatorHandler) removes a series, since a canceled series has no Midnight position at all.
contract SettleHandler is Test {
    SeriesRegistry public registry;

    constructor(SeriesRegistry registry_) {
        registry = registry_;
    }

    function startSettlement(uint256 seriesSeed) external {
        (address seriesAddr,) = registry.pickActive(seriesSeed);
        if (seriesAddr == address(0)) return;
        Series series = Series(seriesAddr);
        if (uint8(series.state()) != uint8(SeriesState.LOCKED)) return;

        (bool ok,) = seriesAddr.call(abi.encodeWithSelector(series.startSettlement.selector));
        registry.recordCall(this.startSettlement.selector, !ok);
    }

    function collect(uint256 seriesSeed) external {
        (address seriesAddr,) = registry.pickActive(seriesSeed);
        if (seriesAddr == address(0)) return;
        Series series = Series(seriesAddr);
        uint8 st = uint8(series.state());
        if (st != uint8(SeriesState.LOCKED) && st != uint8(SeriesState.SETTLING) && st != uint8(SeriesState.SETTLED)) {
            return;
        }

        (bool ok,) = seriesAddr.call(abi.encodeWithSelector(series.collect.selector, uint256(0)));
        registry.recordCall(this.collect.selector, !ok);
    }

    function settle(uint256 seriesSeed) external {
        (address seriesAddr,) = registry.pickActive(seriesSeed);
        if (seriesAddr == address(0)) return;
        Series series = Series(seriesAddr);
        if (uint8(series.state()) != uint8(SeriesState.SETTLING)) return;
        if (!series.resolved(0)) return;

        (bool ok,) = seriesAddr.call(abi.encodeWithSelector(series.settle.selector));
        registry.recordCall(this.settle.selector, !ok);
    }

    function writeOff(uint256 seriesSeed) external {
        (address seriesAddr,) = registry.pickActive(seriesSeed);
        if (seriesAddr == address(0)) return;
        Series series = Series(seriesAddr);
        if (uint8(series.state()) != uint8(SeriesState.SETTLING)) return;

        (bool ok,) = seriesAddr.call(abi.encodeWithSelector(series.writeOff.selector));
        registry.recordCall(this.writeOff.selector, !ok);
    }

    function claimFee(uint256 seriesSeed) external {
        (address seriesAddr,) = registry.pickActive(seriesSeed);
        if (seriesAddr == address(0)) return;
        Series series = Series(seriesAddr);

        (bool ok,) = seriesAddr.call(abi.encodeWithSelector(series.claimFee.selector));
        registry.recordCall(this.claimFee.selector, !ok);
    }
}
