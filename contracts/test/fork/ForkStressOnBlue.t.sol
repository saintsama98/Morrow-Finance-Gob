// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the tranche-mechanics and crash-realism fork suites rerun with idle cash lent in the real Blue market.
// @author adiii.eth

pragma solidity 0.8.34;

import {ForkTrancheMechanicsTest} from "./ForkTrancheMechanics.t.sol";
import {ForkCrashRealismTest} from "./ForkCrashRealism.t.sol";

contract ForkTrancheMechanicsOnBlueTest is ForkTrancheMechanicsTest {
    function _useBlueParking() internal pure override returns (bool) {
        return true;
    }
}

contract ForkCrashRealismOnBlueTest is ForkCrashRealismTest {
    function _useBlueParking() internal pure override returns (bool) {
        return true;
    }
}
