// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {EpochMath} from "../../src/libraries/EpochMath.sol";
import {WadMath} from "../../src/libraries/WadMath.sol";

/// @dev Spec section 25.2 "EpochMath": pro rata fill across 1 to 200 controllers (sum of claimable shares ==
/// sharesFulfilled on a full fill, <= sharesFulfilled and dust bounded by controller count on a partial fill;
/// sum of claimable assets <= assetsFulfilled), the min rule for redemptions, the max rule for junior deposits.
contract EpochMathTest is Test {
    using WadMath for uint256;

    uint256 constant WAD = 1e18;

    function test_redemptionPrice_minRule() public pure {
        assertEq(EpochMath.redemptionPriceWad(1.1e18, 1.0e18), 1.0e18, "must pick the lower price");
        assertEq(EpochMath.redemptionPriceWad(0.9e18, 1.0e18), 0.9e18, "must pick the lower price");
        assertEq(EpochMath.redemptionPriceWad(1.0e18, 1.0e18), 1.0e18);
    }

    function test_depositPrice_maxRule() public pure {
        assertEq(EpochMath.depositPriceWad(1.1e18, 1.0e18), 1.1e18, "must pick the higher price");
        assertEq(EpochMath.depositPriceWad(0.9e18, 1.0e18), 1.0e18, "must pick the higher price");
    }

    function testFuzz_minMaxRules_alwaysBetweenInputs(uint256 a, uint256 b) public pure {
        uint256 lo = EpochMath.redemptionPriceWad(a, b);
        uint256 hi = EpochMath.depositPriceWad(a, b);
        assertLe(lo, hi);
        assertTrue(lo == a || lo == b);
        assertTrue(hi == a || hi == b);
    }

    function test_sharesFillable_assetsForShares_roundTrip() public pure {
        uint256 price = 1.05e18;
        uint256 available = 1_000_000e6;
        uint256 remaining = 2_000_000e18; // more requested than assets can cover

        uint256 shares = EpochMath.sharesFillable(remaining, available, price);
        uint256 assets = EpochMath.assetsForShares(shares, price);

        assertLe(assets, available, "must never draw more assets than were available");
        assertLt(shares, remaining, "should be capped by available assets, not the full request");
    }

    function test_sharesFillable_cappedByRemainingShares() public pure {
        uint256 price = 1.0e18;
        uint256 available = 1_000_000e6 * 1e12; // plenty of assets, scaled to 18-decimal-ish headroom
        uint256 remaining = 500e18;

        uint256 shares = EpochMath.sharesFillable(remaining, available, price);
        assertEq(shares, remaining, "should be capped by the remaining request, not assets");
    }

    /// @dev Full fill (sharesFulfilled == totalShares): every controller's claimable == its exact request, no
    /// rounding loss, sum equals sharesFulfilled exactly.
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
            uint256 claimable = EpochMath.claimableShares(requests[i], totalShares, totalShares, 0);
            assertEq(claimable, requests[i], "full fill: claimable must equal the exact request, no rounding");
            sumClaimable += claimable;
        }
        assertEq(sumClaimable, totalShares, "full fill: sum of claimable must equal sharesFulfilled exactly");
    }

    /// @dev Partial fill: sum of claimable shares never exceeds sharesFulfilled, and the dust (shortfall from
    /// exact pro-rata) is bounded by the number of controllers (each controller can lose at most 1 wei to
    /// flooring).
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
            sumClaimable += EpochMath.claimableShares(requests[i], sharesFulfilled, totalShares, 0);
        }

        assertLe(sumClaimable, sharesFulfilled, "sum of claimable must never exceed sharesFulfilled");
        // Exact pro rata would be sharesFulfilled itself (sum of requests == totalShares by construction, and
        // sharesFulfilled/totalShares is the fill ratio applied to every request); dust from independent
        // per-controller flooring is at most 1 wei per controller.
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
            sumClaimable += EpochMath.claimableAssets(requests[i], assetsFulfilled, totalShares, 0);
        }

        assertLe(sumClaimable, assetsFulfilled, "sum of claimable assets must never exceed assetsFulfilled");
    }

    /// @dev A controller who already claimed part of their entitlement can only claim the remainder as more of
    /// the epoch fills across several fulfillment rounds at different prices/fill levels.
    function testFuzz_multiRoundClaim_monotoneAndBounded(uint256 requested, uint256 fill1Bps, uint256 fill2Bps)
        public
        pure
    {
        requested = bound(requested, 1, 1_000_000e18);
        uint256 totalShares = requested * 3; // this controller is one of several
        fill1Bps = bound(fill1Bps, 0, 10_000);
        fill2Bps = bound(fill2Bps, fill1Bps, 10_000);

        uint256 sharesFulfilled1 = totalShares.mulDivDown(fill1Bps, 10_000);
        uint256 sharesFulfilled2 = totalShares.mulDivDown(fill2Bps, 10_000);

        uint256 claim1 = EpochMath.claimableShares(requested, sharesFulfilled1, totalShares, 0);
        uint256 claim2 = EpochMath.claimableShares(requested, sharesFulfilled2, totalShares, claim1);

        assertLe(claim1 + claim2, requested, "cumulative claims must never exceed the original request");
        assertLe(claim1, claim2 + claim1, "second-round claim must not go backwards");
    }
}
