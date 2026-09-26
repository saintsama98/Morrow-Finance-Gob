// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: unit and fuzz tests for epochMath's pro-rata epoch fulfillment.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {epochMath} from "../../src/libraries/epochMath.sol";
import {wadMath} from "../../src/libraries/wadMath.sol";

contract EpochMathTest is Test {
    using wadMath for uint256;

    uint256 constant WAD = 1e18;

    function test_redemptionPrice_minRule() public pure {
        assertEq(epochMath.redemptionPriceWad(1.1e18, 1.0e18), 1.0e18, "must pick the lower price");
        assertEq(epochMath.redemptionPriceWad(0.9e18, 1.0e18), 0.9e18, "must pick the lower price");
        assertEq(epochMath.redemptionPriceWad(1.0e18, 1.0e18), 1.0e18);
    }

    function test_depositPrice_maxRule() public pure {
        assertEq(epochMath.depositPriceWad(1.1e18, 1.0e18), 1.1e18, "must pick the higher price");
        assertEq(epochMath.depositPriceWad(0.9e18, 1.0e18), 1.0e18, "must pick the higher price");
    }

    function testFuzz_minMaxRules_alwaysBetweenInputs(uint256 a, uint256 b) public pure {
        uint256 lo = epochMath.redemptionPriceWad(a, b);
        uint256 hi = epochMath.depositPriceWad(a, b);
        assertLe(lo, hi);
        assertTrue(lo == a || lo == b);
        assertTrue(hi == a || hi == b);
    }

    function test_sharesFillable_assetsForShares_roundTrip() public pure {
        uint256 price = 1.05e18;
        uint256 available = 1_000_000e6;
        uint256 remaining = 2_000_000e18;

        uint256 shares = epochMath.sharesFillable(remaining, available, price);
        uint256 assets = epochMath.assetsForShares(shares, price);

        assertLe(assets, available, "must never draw more assets than were available");
        assertLt(shares, remaining, "should be capped by available assets, not the full request");
    }

    function test_sharesFillable_cappedByRemainingShares() public pure {
        uint256 price = 1.0e18;
        uint256 available = 1_000_000e6 * 1e12;
        uint256 remaining = 500e18;

        uint256 shares = epochMath.sharesFillable(remaining, available, price);
        assertEq(shares, remaining, "should be capped by the remaining request, not assets");
    }

    function testFuzz_fullFill_exactProRata(uint256[10] memory rawRequests) public pure {
        uint256 totalShares;
        uint256[] memory requests = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            requests[i] = bound(rawRequests[i], 0, 1_000_000e18);
            totalShares += requests[i];
        }
        vm.assume(totalShares > 0);

        uint256 sumClaimable;
        for (uint256 i = 0; i < 10; i++) {
            uint256 claimable = epochMath.claimableShares(requests[i], totalShares, totalShares, 0);
            assertEq(claimable, requests[i], "full fill: claimable must equal the exact request, no rounding");
            sumClaimable += claimable;
        }
        assertEq(sumClaimable, totalShares, "full fill: sum of claimable must equal sharesFulfilled exactly");
    }

    function testFuzz_partialFill_boundedDust(uint256[20] memory rawRequests, uint256 fillBps) public pure {
        fillBps = bound(fillBps, 0, 10_000);
        uint256 totalShares;
        uint256[] memory requests = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            requests[i] = bound(rawRequests[i], 0, 1_000_000e18);
            totalShares += requests[i];
        }
        vm.assume(totalShares > 0);

        uint256 sharesFulfilled = totalShares.mulDivDown(fillBps, 10_000);

        uint256 sumClaimable;
        for (uint256 i = 0; i < 20; i++) {
            sumClaimable += epochMath.claimableShares(requests[i], sharesFulfilled, totalShares, 0);
        }

        assertLe(sumClaimable, sharesFulfilled, "sum of claimable must never exceed sharesFulfilled");
        assertLe(sharesFulfilled - sumClaimable, 20, "dust must be bounded by controller count");
    }

    function testFuzz_claimableAssets_sumNeverExceedsAssetsFulfilled(
        uint256[15] memory rawRequests,
        uint256 assetsFulfilled
    ) public pure {
        uint256 totalShares;
        uint256[] memory requests = new uint256[](15);
        for (uint256 i = 0; i < 15; i++) {
            requests[i] = bound(rawRequests[i], 0, 1_000_000e18);
            totalShares += requests[i];
        }
        vm.assume(totalShares > 0);
        assetsFulfilled = bound(assetsFulfilled, 0, 1_000_000_000e6);

        uint256 sumClaimable;
        for (uint256 i = 0; i < 15; i++) {
            sumClaimable += epochMath.claimableAssets(requests[i], assetsFulfilled, totalShares, 0);
        }

        assertLe(sumClaimable, assetsFulfilled, "sum of claimable assets must never exceed assetsFulfilled");
    }

    function testFuzz_multiRoundClaim_monotoneAndBounded(uint256 requested, uint256 fill1Bps, uint256 fill2Bps)
        public
        pure
    {
        requested = bound(requested, 1, 1_000_000e18);
        uint256 totalShares = requested * 3;
        fill1Bps = bound(fill1Bps, 0, 10_000);
        fill2Bps = bound(fill2Bps, fill1Bps, 10_000);

        uint256 sharesFulfilled1 = totalShares.mulDivDown(fill1Bps, 10_000);
        uint256 sharesFulfilled2 = totalShares.mulDivDown(fill2Bps, 10_000);

        uint256 claim1 = epochMath.claimableShares(requested, sharesFulfilled1, totalShares, 0);
        uint256 claim2 = epochMath.claimableShares(requested, sharesFulfilled2, totalShares, claim1);

        assertLe(claim1 + claim2, requested, "cumulative claims must never exceed the original request");
        assertLe(claim1, claim2 + claim1, "second-round claim must not go backwards");
    }
}
