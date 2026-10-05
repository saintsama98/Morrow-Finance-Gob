// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: replay of a Medusa sequence: a real exit fill holds the coverage floor; yield rounding may not.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {MorrowCrytic} from "./MorrowCrytic.sol";

contract MorrowCryticReproTest is Test {
    MorrowCrytic h;

    function setUp() public {
        h = new MorrowCrytic();
    }

    function _cov() internal view returns (uint256) {
        uint256 sA = h.core().seniorAssets();
        uint256 jA = h.core().juniorAssets();
        return jA * 1e18 / (sA + jA);
    }

    function _floor() internal view returns (uint256 floorWad) {
        (,,, floorWad,,,,,,,,,,,,,,,) = h.core().policy();
    }

    function test_medusaSequence_exitFillHoldsCoverageFloor_noOpFillIsNotABreach() public {
        vm.warp(27);
        vm.roll(27);
        h.juniorRequestRedeem(
            1289959351253254865863018962536399739358185852530476392046511604479894199348,
            39724689063375933865179155749098351454073223922244473998568484775283782049833
        );
        h.curatorCloseJuniorRedeem();
        vm.warp(269337);
        vm.roll(28);
        h.curatorFillJuniorDeposit(7412020321097303492622622520771725687708868369201198942474186019552529609);
        (, uint256 r0,,,,) = h.jv().redeemEpochs(1);
        h.strangerFillJuniorRedeem(
            10029986813470979812764978450723524241169429903389526387885177697703818087011,
            94717005971727023074913020812633171603667196545132772576609554699176296213643
        );
        (, uint256 r1,,,,) = h.jv().redeemEpochs(1);
        assertGt(r0 - r1, 0, "step 4 is a real exit fill");
        assertGe(_cov(), _floor(), "a real exit fill must keep junior coverage at or above the floor");
        h.venueAccrue(1469015524293433661809732731935121893147546313636973094727139393196239403);
        uint256 afterAccrue = _cov();
        h.strangerFillJuniorRedeem(
            21416842402757076646970079722353174924796944307351751268275256751,
            5509255600956783120961353598252390427458833900854069399145362334263989884578
        );
        (, uint256 r2,,,,) = h.jv().redeemEpochs(1);
        assertEq(r1 - r2, 0, "at the floor, a further exit fill moves nothing");
        assertEq(_cov(), afterAccrue, "a no-op fill leaves coverage untouched");
        assertFalse(h.ghostCoverageBreach(), "the harness flags only fills that moved shares");
    }
}
