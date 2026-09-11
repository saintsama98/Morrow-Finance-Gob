// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {PremiumCurve} from "../../src/libraries/PremiumCurve.sol";

/// @dev Section 25.6 differential test: PremiumCurve.pi vs sim/series_math.py's premium_pi, 2000 vectors.
contract PremiumCurveDiffTest is Test {
    function test_diff_premiumCurve() public {
        string memory json = vm.readFile("sim/vectors/premium_curve.json");
        uint256[] memory us = vm.parseJsonUintArray(json, ".u");
        uint256[] memory uTs = vm.parseJsonUintArray(json, ".uT");
        uint256[] memory pi0s = vm.parseJsonUintArray(json, ".pi0");
        uint256[] memory piTs = vm.parseJsonUintArray(json, ".piT");
        uint256[] memory pi1s = vm.parseJsonUintArray(json, ".pi1");
        uint256[] memory pis = vm.parseJsonUintArray(json, ".pi");

        assertGt(us.length, 0);

        for (uint256 i = 0; i < us.length; i++) {
            uint256 result = PremiumCurve.pi(us[i], uTs[i], pi0s[i], piTs[i], pi1s[i]);
            assertEq(result, pis[i], "pi(u) mismatch vs python twin");
        }
    }
}
