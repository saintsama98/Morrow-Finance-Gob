// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the tranche-mechanics fork suite rerun with idle cash lent in the real Blue market.
// @author adiii.eth

pragma solidity 0.8.34;

import {ForkTrancheMechanicsTest} from "./ForkTrancheMechanics.t.sol";

contract ForkTrancheMechanicsOnBlueTest is ForkTrancheMechanicsTest {
    function _useBlueParking() internal pure override returns (bool) {
        return true;
    }
}
