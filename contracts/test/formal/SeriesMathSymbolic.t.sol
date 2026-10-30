// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: symbolic properties of the series waterfall, allocation split, pricing and marks (Halmos check_ targets with fuzz twins).
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SeriesMath} from "../../src/libraries/SeriesMath.sol";

contract SeriesMathSymbolicTest is Test {
    uint256 constant WAD = 1e18;

    // ---- waterfall ----

    function check_waterfall_conserves(uint256 proceeds, uint256 claim, uint256 jDeployed, uint256 theta) public pure {
        vm.assume(proceeds <= type(uint128).max && claim <= type(uint128).max && jDeployed <= type(uint128).max);
        vm.assume(theta <= WAD);
        (uint256 s, uint256 j, uint256 fee) = SeriesMath.waterfall(proceeds, claim, jDeployed, theta);
        assert(s + j + fee == proceeds);
    }

    function check_waterfall_seniorFirst(uint256 proceeds, uint256 claim, uint256 jDeployed, uint256 theta)
        public
        pure
    {
        vm.assume(proceeds <= type(uint128).max && claim <= type(uint128).max && jDeployed <= type(uint128).max);
        vm.assume(theta <= WAD);
        (uint256 s, uint256 j, uint256 fee) = SeriesMath.waterfall(proceeds, claim, jDeployed, theta);
        assert(s == (proceeds < claim ? proceeds : claim));
        if (proceeds <= claim) assert(j == 0 && fee == 0);
    }

    function reach_waterfall_juniorPaid(uint256 proceeds, uint256 claim, uint256 jDeployed, uint256 theta) public pure {
        vm.assume(proceeds <= type(uint128).max && claim <= type(uint128).max && jDeployed <= type(uint128).max);
        vm.assume(theta <= WAD);
        (, uint256 j, uint256 fee) = SeriesMath.waterfall(proceeds, claim, jDeployed, theta);
        assert(j == 0 || fee == 0);
    }

    function check_waterfallPassThrough_conserves(uint256 proceeds, uint256 sDeployed, uint256 k) public pure {
        vm.assume(proceeds <= type(uint128).max && k <= type(uint128).max && sDeployed <= k);
        (uint256 s, uint256 j) = SeriesMath.waterfallPassThrough(proceeds, sDeployed, k);
        assert(s + j == proceeds);
        assert(s <= proceeds);
    }

    // ---- allocation split ----

    function check_allocationSplit_conservesAndJuniorRoundsUp(uint256 k, uint256 share) public pure {
        vm.assume(k <= type(uint128).max && share <= WAD);
        (uint256 s, uint256 j) = SeriesMath.allocationSplit(k, share);
        assert(s + j == k);
        // senior never takes more than its exact share, so any rounding lands on junior
        assert(s * WAD <= k * (WAD - share));
    }

    function reach_allocationSplit_rounds(uint256 k, uint256 share) public pure {
        vm.assume(k <= type(uint128).max && share <= WAD);
        (uint256 s,) = SeriesMath.allocationSplit(k, share);
        assert(s * WAD == k * (WAD - share));
    }

    // ---- pricing ----

    function check_price_negativeCarryClamped(uint256 k, uint256 share, uint256 face, uint256 piWad) public pure {
        vm.assume(k > 0 && k <= type(uint128).max && share <= WAD && piWad <= WAD);
        vm.assume(face > 0 && face <= k);
        SeriesMath.PricingResult memory r = SeriesMath.price(k, share, face, piWad);
        assert(r.negativeCarry && r.poolRateWad == 0 && r.seniorRateWad == 0);
        assert(r.seniorClaim == r.seniorDeployed);
    }

    function check_price_seniorRateCeilingAndCushion(uint256 k, uint256 share, uint256 face, uint256 piWad)
        public
        pure
    {
        vm.assume(k > 0 && k <= type(uint128).max && share <= WAD && piWad <= WAD);
        vm.assume(face > k && face <= type(uint128).max);
        SeriesMath.PricingResult memory r = SeriesMath.price(k, share, face, piWad);
        assert(r.seniorRateWad <= r.poolRateWad);
        assert(r.attachmentWad <= WAD);
        assert(r.buffer0 == int256(face) - int256(r.seniorClaim));
    }

    // ---- marks ----

    function check_nav_conserves(
        uint256 elapsed,
        uint256 tau,
        uint256 k,
        uint256 face,
        uint256 loss,
        uint256 sDeployed,
        uint256 claim,
        uint256 theta
    ) public pure {
        vm.assume(elapsed <= type(uint64).max && tau <= type(uint64).max);
        vm.assume(k <= type(uint64).max && face <= type(uint64).max && loss <= type(uint64).max);
        vm.assume(sDeployed <= k && claim <= type(uint64).max && theta <= WAD);
        uint256 jDeployed = k - sDeployed;
        (uint256 navS, uint256 navJ, uint256 fee) =
            SeriesMath.nav(elapsed, tau, k, face, loss, sDeployed, claim, jDeployed, theta);
        uint256 s = elapsed > tau ? tau : elapsed;
        uint256 accretion = (tau > 0 && face >= k) ? (face - k) * s / tau : 0;
        uint256 v = k + accretion > loss ? k + accretion - loss : 0;
        assert(navS + navJ + fee == v);
    }

    function check_nav_convergesToWaterfallAtMaturity(
        uint256 tau,
        uint256 k,
        uint256 face,
        uint256 loss,
        uint256 sDeployed,
        uint256 claim,
        uint256 theta
    ) public pure {
        vm.assume(tau > 0 && tau <= type(uint64).max);
        vm.assume(k <= type(uint64).max && face <= type(uint64).max && loss <= type(uint64).max);
        vm.assume(sDeployed <= k && claim >= sDeployed && claim <= type(uint64).max && theta <= WAD);
        uint256 jDeployed = k - sDeployed;
        (uint256 navS, uint256 navJ, uint256 fee) =
            SeriesMath.nav(tau, tau, k, face, loss, sDeployed, claim, jDeployed, theta);
        uint256 grossV = face >= k ? face : k;
        uint256 v = grossV > loss ? grossV - loss : 0;
        (uint256 wS, uint256 wJ, uint256 wFee) = SeriesMath.waterfall(v, claim, jDeployed, theta);
        assert(navS == wS && navJ == wJ && fee == wFee);
    }

    // ---- fuzz twins, so `forge test` exercises every property ----

    function testFuzz_waterfall(uint256 proceeds, uint256 claim, uint256 jDeployed, uint256 theta) public pure {
        proceeds = bound(proceeds, 0, type(uint128).max);
        claim = bound(claim, 0, type(uint128).max);
        jDeployed = bound(jDeployed, 0, type(uint128).max);
        theta = bound(theta, 0, WAD);
        check_waterfall_conserves(proceeds, claim, jDeployed, theta);
        check_waterfall_seniorFirst(proceeds, claim, jDeployed, theta);
    }

    function testFuzz_waterfallPassThrough(uint256 proceeds, uint256 sDeployed, uint256 k) public pure {
        proceeds = bound(proceeds, 0, type(uint128).max);
        k = bound(k, 0, type(uint128).max);
        sDeployed = bound(sDeployed, 0, k);
        check_waterfallPassThrough_conserves(proceeds, sDeployed, k);
    }

    function testFuzz_allocationSplit(uint256 k, uint256 share) public pure {
        check_allocationSplit_conservesAndJuniorRoundsUp(bound(k, 0, type(uint128).max), bound(share, 0, WAD));
    }

    function testFuzz_price(uint256 k, uint256 share, uint256 face, uint256 piWad) public pure {
        k = bound(k, 1, type(uint128).max);
        share = bound(share, 0, WAD);
        piWad = bound(piWad, 0, WAD);
        check_price_negativeCarryClamped(k, share, bound(face, 1, k), piWad);
        if (k < type(uint128).max) {
            check_price_seniorRateCeilingAndCushion(k, share, bound(face, k + 1, type(uint128).max), piWad);
        }
    }

    function testFuzz_nav(uint256 elapsed, uint256 tau, uint256 k, uint256 face, uint256 loss, uint256 sDeployed)
        public
        pure
    {
        tau = bound(tau, 1, type(uint64).max);
        k = bound(k, 0, type(uint64).max);
        face = bound(face, 0, type(uint64).max);
        loss = bound(loss, 0, type(uint64).max);
        sDeployed = bound(sDeployed, 0, k);
        uint256 claim = bound(face, sDeployed, type(uint64).max);
        check_nav_conserves(bound(elapsed, 0, type(uint64).max), tau, k, face, loss, sDeployed, claim, WAD / 10);
        check_nav_convergesToWaterfallAtMaturity(tau, k, face, loss, sDeployed, claim, WAD / 10);
    }
}
