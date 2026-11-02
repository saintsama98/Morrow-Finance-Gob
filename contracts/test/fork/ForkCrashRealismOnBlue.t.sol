// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the crash-realism fork suite rerun with idle cash lent in the real Blue market.
// @author adiii.eth

pragma solidity 0.8.34;

import {ForkCrashRealismTest} from "./ForkCrashRealism.t.sol";

contract ForkCrashRealismOnBlueTest is ForkCrashRealismTest {
    function _useBlueParking() internal pure override returns (bool) {
        return true;
    }
}
