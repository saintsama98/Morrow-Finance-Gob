// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: every math library matches its Python twin on shared vectors, to the wei.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {wadMath} from "../../src/libraries/wadMath.sol";
import {premiumCurve} from "../../src/libraries/premiumCurve.sol";
import {seriesMath} from "../../src/libraries/seriesMath.sol";
import {epochMath} from "../../src/libraries/epochMath.sol";

contract MathDifferentialTest is Test {
    function _load(string memory name) internal view returns (bytes memory) {
        return vm.parseBytes(vm.readFile(string.concat(vm.projectRoot(), "/sim/vectors/", name, ".hex")));
    }

    function test_wadMath_matchesTwin() public view {
        uint256[5][] memory rows = abi.decode(_load("wad_math"), (uint256[5][]));
        assertGt(rows.length, 100, "vector set present");
        for (uint256 i = 0; i < rows.length; i++) {
            uint256[5] memory r = rows[i];
            assertEq(wadMath.mulDivDown(r[0], r[1], r[2]), r[3], "mulDivDown");
            assertEq(wadMath.mulDivUp(r[0], r[1], r[2]), r[4], "mulDivUp");
        }
    }

    function test_premiumCurve_matchesTwin() public view {
        uint256[6][] memory rows = abi.decode(_load("premium_curve"), (uint256[6][]));
        for (uint256 i = 0; i < rows.length; i++) {
            uint256[6] memory r = rows[i];
            assertEq(premiumCurve.pi(r[0], r[1], r[2], r[3], r[4]), r[5], "pi");
        }
    }

    function test_seriesPrice_matchesTwin() public view {
        (uint256[11][] memory rows, int256[] memory buffers) =
            abi.decode(_load("series_price"), (uint256[11][], int256[]));
        for (uint256 i = 0; i < rows.length; i++) {
            uint256[11] memory r = rows[i];
            seriesMath.PricingResult memory p = seriesMath.price(r[0], r[1], r[2], r[3]);
            assertEq(p.seniorDeployed, r[4], "seniorDeployed");
            assertEq(p.juniorDeployed, r[5], "juniorDeployed");
            assertEq(p.poolRateWad, r[6], "poolRateWad");
            assertEq(p.seniorRateWad, r[7], "seniorRateWad");
            assertEq(p.seniorClaim, r[8], "seniorClaim");
            assertEq(p.attachmentWad, r[9], "attachmentWad");
            assertEq(p.negativeCarry ? 1 : 0, r[10], "negativeCarry");
            assertEq(p.buffer0, buffers[i], "buffer0");
        }
    }

    function test_seriesNav_matchesTwin() public view {
        uint256[12][] memory rows = abi.decode(_load("series_nav"), (uint256[12][]));
        for (uint256 i = 0; i < rows.length; i++) {
            uint256[12] memory r = rows[i];
            (uint256 navS, uint256 navJ, uint256 fee) =
                seriesMath.nav(r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8]);
            assertEq(navS, r[9], "navS");
            assertEq(navJ, r[10], "navJ");
            assertEq(fee, r[11], "feeAccrued");
        }
    }

    function test_seriesWaterfall_matchesTwin() public view {
        uint256[7][] memory rows = abi.decode(_load("series_waterfall"), (uint256[7][]));
        for (uint256 i = 0; i < rows.length; i++) {
            uint256[7] memory r = rows[i];
            (uint256 xs, uint256 xj, uint256 fee) = seriesMath.waterfall(r[0], r[1], r[2], r[3]);
            assertEq(xs, r[4], "seniorPaid");
            assertEq(xj, r[5], "juniorPaid");
            assertEq(fee, r[6], "fee");
            assertEq(xs + xj + fee, r[0], "conservation");
        }
    }

    function test_seriesPassThrough_matchesTwin() public view {
        uint256[5][] memory rows = abi.decode(_load("series_passthrough"), (uint256[5][]));
        for (uint256 i = 0; i < rows.length; i++) {
            uint256[5] memory r = rows[i];
            (uint256 xs, uint256 xj) = seriesMath.waterfallPassThrough(r[0], r[1], r[2]);
            assertEq(xs, r[3], "seniorPaid");
            assertEq(xj, r[4], "juniorPaid");
        }
    }

    function test_seriesSplit_matchesTwin() public view {
        uint256[4][] memory rows = abi.decode(_load("series_split"), (uint256[4][]));
        for (uint256 i = 0; i < rows.length; i++) {
            uint256[4] memory r = rows[i];
            (uint256 s, uint256 j) = seriesMath.allocationSplit(r[0], r[1]);
            assertEq(s, r[2], "seniorDeployed");
            assertEq(j, r[3], "juniorDeployed");
        }
    }

    function test_epochMath_matchesTwin() public view {
        uint256[9][] memory rows = abi.decode(_load("epoch_math"), (uint256[9][]));
        for (uint256 i = 0; i < rows.length; i++) {
            uint256[9] memory r = rows[i];
            assertEq(epochMath.redemptionPriceWad(r[0], r[1]), r[4], "redemptionPrice");
            assertEq(epochMath.depositPriceWad(r[0], r[1]), r[5], "depositPrice");
            assertEq(epochMath.sharesFillable(r[2], r[3], r[4]), r[6], "sharesFillable");
            assertEq(epochMath.assetsForShares(r[2], r[4]), r[7], "assetsForShares");
            assertEq(epochMath.sharesForAssets(r[3], r[4]), r[8], "sharesForAssets");
        }
    }
}
