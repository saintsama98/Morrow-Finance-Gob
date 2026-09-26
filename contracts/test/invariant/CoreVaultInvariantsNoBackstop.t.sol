// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the core-and-vault invariant suite, run with the cross-series backstop switched off.
// @author adiii.eth

pragma solidity 0.8.34;

import {CoreVaultInvariantsTest} from "./CoreVaultInvariants.t.sol";
import {seriesCore} from "../../src/core/seriesCore.sol";

contract CoreVaultInvariantsNoBackstopTest is CoreVaultInvariantsTest {
    function setUp() public override {
        super.setUp();
        seriesCore core = registry.realCore();
        vm.prank(registry.CURATOR());
        core.disableBackstop();
    }

    function invariant_I25_noBackstopLeakageWhenDisabled() public view {
        uint256 count = registry.activeSeriesCount();
        for (uint256 i = 0; i < count; i++) {
            address seriesAddr = registry.activeSeries(i);
            assertEq(
                registry.realCore().backstopPaid(seriesAddr),
                0,
                "backstopPaid must stay zero for every series once the backstop is disabled"
            );
        }
    }
}
