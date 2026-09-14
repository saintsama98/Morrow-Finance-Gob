// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SeriesMath} from "../../src/libraries/SeriesMath.sol";

// Morrow Finance — Solidity vs Python differential test for SeriesMath.
// @author adiii.eth

/// @notice Differential tests: SeriesMath.price / waterfall / nav vs the Python twin, 2000 vectors each.
/// Columnar JSON format (one array per field, read with parseJsonUintArray/IntArray/BoolArray).
contract SeriesMathDiffTest is Test {
    function test_diff_pricing() public {
        string memory json = vm.readFile("sim/vectors/series_pricing.json");
        uint256[] memory kDeployeds = vm.parseJsonUintArray(json, ".kDeployed");
        uint256[] memory juniorShareWads = vm.parseJsonUintArray(json, ".juniorShareWad");
        uint256[] memory faceNets = vm.parseJsonUintArray(json, ".faceNetAtFinalize");
        uint256[] memory piWads = vm.parseJsonUintArray(json, ".piWad");
        uint256[] memory expSeniorDeployed = vm.parseJsonUintArray(json, ".seniorDeployed");
        uint256[] memory expJuniorDeployed = vm.parseJsonUintArray(json, ".juniorDeployed");
        uint256[] memory expPoolRate = vm.parseJsonUintArray(json, ".poolRateWad");
        uint256[] memory expSeniorRate = vm.parseJsonUintArray(json, ".seniorRateWad");
        uint256[] memory expSeniorClaim = vm.parseJsonUintArray(json, ".seniorClaim");
        uint256[] memory expAttachment = vm.parseJsonUintArray(json, ".attachmentWad");
        int256[] memory expBuffer0 = vm.parseJsonIntArray(json, ".buffer0");
        bool[] memory expNegativeCarry = vm.parseJsonBoolArray(json, ".negativeCarry");

        assertGt(kDeployeds.length, 0);

        for (uint256 i = 0; i < kDeployeds.length; i++) {
            SeriesMath.PricingResult memory r =
                SeriesMath.price(kDeployeds[i], juniorShareWads[i], faceNets[i], piWads[i]);

            assertEq(r.seniorDeployed, expSeniorDeployed[i], "seniorDeployed");
            assertEq(r.juniorDeployed, expJuniorDeployed[i], "juniorDeployed");
            assertEq(r.poolRateWad, expPoolRate[i], "poolRateWad");
            assertEq(r.seniorRateWad, expSeniorRate[i], "seniorRateWad");
            assertEq(r.seniorClaim, expSeniorClaim[i], "seniorClaim");
            assertEq(r.attachmentWad, expAttachment[i], "attachmentWad");
            assertEq(r.buffer0, expBuffer0[i], "buffer0");
            assertEq(r.negativeCarry, expNegativeCarry[i], "negativeCarry");
        }
    }

    function test_diff_waterfall() public {
        string memory json = vm.readFile("sim/vectors/waterfall.json");
        uint256[] memory proceeds = vm.parseJsonUintArray(json, ".proceeds");
        uint256[] memory seniorClaims = vm.parseJsonUintArray(json, ".seniorClaim");
        uint256[] memory juniorDeployeds = vm.parseJsonUintArray(json, ".juniorDeployed");
        uint256[] memory thetaWads = vm.parseJsonUintArray(json, ".thetaWad");
        uint256[] memory expSeniorPaid = vm.parseJsonUintArray(json, ".seniorPaid");
        uint256[] memory expJuniorPaid = vm.parseJsonUintArray(json, ".juniorPaid");
        uint256[] memory expFee = vm.parseJsonUintArray(json, ".fee");

        assertGt(proceeds.length, 0);

        for (uint256 i = 0; i < proceeds.length; i++) {
            (uint256 xs, uint256 xj, uint256 fee) =
                SeriesMath.waterfall(proceeds[i], seniorClaims[i], juniorDeployeds[i], thetaWads[i]);

            assertEq(xs, expSeniorPaid[i], "seniorPaid");
            assertEq(xj, expJuniorPaid[i], "juniorPaid");
            assertEq(fee, expFee[i], "fee");
        }
    }

    struct NavVectors {
        uint256[] elapsed;
        uint256[] tau;
        uint256[] kDeployed;
        uint256[] faceNetAtFinalize;
        uint256[] faceLoss;
        uint256[] seniorDeployed;
        uint256[] seniorClaim;
        uint256[] juniorDeployed;
        uint256[] thetaWad;
        uint256[] navS;
        uint256[] navJ;
        uint256[] feeAccrued;
    }

    function _readNavVectors() private returns (NavVectors memory v) {
        string memory json = vm.readFile("sim/vectors/nav.json");
        v.elapsed = vm.parseJsonUintArray(json, ".elapsed");
        v.tau = vm.parseJsonUintArray(json, ".tau");
        v.kDeployed = vm.parseJsonUintArray(json, ".kDeployed");
        v.faceNetAtFinalize = vm.parseJsonUintArray(json, ".faceNetAtFinalize");
        v.faceLoss = vm.parseJsonUintArray(json, ".faceLoss");
        v.seniorDeployed = vm.parseJsonUintArray(json, ".seniorDeployed");
        v.seniorClaim = vm.parseJsonUintArray(json, ".seniorClaim");
        v.juniorDeployed = vm.parseJsonUintArray(json, ".juniorDeployed");
        v.thetaWad = vm.parseJsonUintArray(json, ".thetaWad");
        v.navS = vm.parseJsonUintArray(json, ".navS");
        v.navJ = vm.parseJsonUintArray(json, ".navJ");
        v.feeAccrued = vm.parseJsonUintArray(json, ".feeAccrued");
    }

    function test_diff_nav() public {
        NavVectors memory v = _readNavVectors();
        assertGt(v.elapsed.length, 0);

        for (uint256 i = 0; i < v.elapsed.length; i++) {
            (uint256 navS, uint256 navJ, uint256 feeAccrued) = SeriesMath.nav(
                v.elapsed[i],
                v.tau[i],
                v.kDeployed[i],
                v.faceNetAtFinalize[i],
                v.faceLoss[i],
                v.seniorDeployed[i],
                v.seniorClaim[i],
                v.juniorDeployed[i],
                v.thetaWad[i]
            );

            assertEq(navS, v.navS[i], "navS");
            assertEq(navJ, v.navJ[i], "navJ");
            assertEq(feeAccrued, v.feeAccrued[i], "feeAccrued");
        }
    }
}
