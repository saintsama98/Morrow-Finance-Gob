// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: one collateral crash hits a series market and the Blue parking market together; junior absorbs first.
// @author adiii.eth

pragma solidity 0.8.34;

import {console} from "forge-std/console.sol";
import {MorphoScenarioBase} from "./MorphoScenarioBase.t.sol";
import {SeriesRegistry} from "../invariant/handlers/SeriesRegistry.sol";
import {SeriesRegistryBlueParking} from "../invariant/handlers/SeriesRegistryBlueParking.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";

contract CorrelatedCrashBlueTest is MorphoScenarioBase {
    address borrower = makeAddr("borrower");
    address seniorDepositor = makeAddr("seniorDepositor");
    address juniorDepositor = makeAddr("juniorDepositor");

    uint256 constant SENIOR_IN = 1_000_000e6;
    uint256 constant JUNIOR_IN = 1_000_000e6;

    function _newVenueRegistry() internal override returns (SeriesRegistry, address, address) {
        SeriesRegistryBlueParking r = new SeriesRegistryBlueParking();
        return (r, address(r.knobs()), address(r.blueParkingAdapter()));
    }

    function liquidateExt(uint256 maturity) external {
        _liquidate(maturity, borrower);
    }

    function _cell(uint256 crashBps, uint256 blueLossBps) internal returns (int256 seniorBps, int256 juniorBps) {
        _juniorDeposit(juniorDepositor, JUNIOR_IN);
        _seniorDeposit(seniorDepositor, SENIOR_IN);
        uint256 maturity = vm.getBlockTimestamp() + 90 days;
        (address seriesAddr,) = _openSeries(700_000e6, 150_000e6, maturity);
        _registerAndFill(seriesAddr, maturity, 800_000e6, borrower);
        _finalize(seriesAddr);
        creditSeries series = creditSeries(seriesAddr);

        vm.warp(vm.getBlockTimestamp() + 20 days);
        core.syncAll();
        _crashOracle(crashBps);
        try this.liquidateExt(maturity) {} catch {}
        if (blueLossBps > 0) vault.loseBps(blueLossBps);
        _restoreOracle();

        vm.warp(maturity + 1);
        series.startSettlement();
        uint256 debt = _debtOf(_marketIdOf(series), borrower);
        if (debt > 0) _repay(maturity, borrower, debt);
        series.collect(0);
        series.settle();

        uint256 s = core.seniorAssets();
        uint256 j = core.juniorAssets();
        seniorBps = (int256(s) - int256(SENIOR_IN)) * 10_000 / int256(SENIOR_IN);
        juniorBps = (int256(j) - int256(JUNIOR_IN)) * 10_000 / int256(JUNIOR_IN);
        _assertBooksReconcile();
    }

    function test_correlatedCrash_grid_juniorAlwaysAbsorbsFirst() public {
        uint16[3] memory crashes = [uint16(2_000), 3_000, 4_000];
        uint16[4] memory blueLosses = [uint16(0), 200, 500, 1_500];
        console.log("crash bps | Blue parking loss bps | senior return bps | junior return bps");
        for (uint256 c = 0; c < crashes.length; c++) {
            for (uint256 b = 0; b < blueLosses.length; b++) {
                uint256 snap = vm.snapshotState();
                (int256 sBps, int256 jBps) = _cell(crashes[c], blueLosses[b]);
                console.log(crashes[c], blueLosses[b]);
                console.logInt(sBps);
                console.logInt(jBps);
                assertGe(sBps, jBps, "senior's return is never below junior's");
                if (crashes[c] <= 2_000 && blueLosses[b] <= 500) {
                    assertGe(sBps, 0, "a mild correlated crash leaves senior whole");
                }
                vm.revertToState(snap);
                vm.deleteStateSnapshot(snap);
            }
        }
    }
}
