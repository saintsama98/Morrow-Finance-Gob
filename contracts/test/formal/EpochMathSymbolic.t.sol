// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: symbolic properties of batch prices and pro-rata entitlements (Halmos check_ targets with fuzz twins).
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {EpochMath} from "../../src/libraries/EpochMath.sol";

contract EpochMathSymbolicTest is Test {
    function check_exitAtLowerPrice_entryAtHigherPrice(uint256 close, uint256 current) public pure {
        uint256 exitPrice = EpochMath.redemptionPriceWad(close, current);
        uint256 entryPrice = EpochMath.depositPriceWad(close, current);
        assert(exitPrice <= close && exitPrice <= current);
        assert(exitPrice == close || exitPrice == current);
        assert(entryPrice >= close && entryPrice >= current);
        assert(entryPrice == close || entryPrice == current);
    }

    function check_zeroPriceFillsNothing(uint256 remaining, uint256 assets) public pure {
        assert(EpochMath.sharesFillable(remaining, assets, 0) == 0);
        assert(EpochMath.sharesForAssets(assets, 0) == 0);
    }

    function check_sharesFillable_boundedByRequestAndAssets(uint256 remaining, uint256 assets, uint256 priceWad)
        public
        pure
    {
        vm.assume(remaining <= type(uint64).max && assets <= type(uint64).max);
        vm.assume(priceWad > 0 && priceWad <= type(uint64).max);
        uint256 fill = EpochMath.sharesFillable(remaining, assets, priceWad);
        assert(fill <= remaining);
        // paying for the fill never needs more assets than are available
        assert(EpochMath.assetsForShares(fill, priceWad) <= assets);
    }

    function check_claimable_neverUnderflowsOrExceedsEntitlement(
        uint256 requested,
        uint256 fulfilled,
        uint256 total,
        uint256 claimed
    ) public pure {
        vm.assume(requested <= total && total <= type(uint64).max && fulfilled <= type(uint64).max);
        uint256 shares = EpochMath.claimableShares(requested, fulfilled, total, claimed);
        uint256 assets = EpochMath.claimableAssets(requested, fulfilled, total, claimed);
        uint256 entitled = total == 0 ? 0 : requested * fulfilled / total;
        assert(shares <= entitled && assets <= entitled);
        assert(shares + claimed >= entitled);
        assert(entitled <= fulfilled);
    }

    function reach_claimable_positive(uint256 requested, uint256 fulfilled, uint256 total, uint256 claimed)
        public
        pure
    {
        vm.assume(requested <= total && total <= type(uint64).max && fulfilled <= type(uint64).max);
        assert(EpochMath.claimableShares(requested, fulfilled, total, claimed) == 0);
    }

    function testFuzz_prices(uint256 close, uint256 current) public pure {
        check_exitAtLowerPrice_entryAtHigherPrice(close, current);
    }

    function testFuzz_fills(uint256 remaining, uint256 assets, uint256 priceWad) public pure {
        remaining = bound(remaining, 0, type(uint128).max);
        assets = bound(assets, 0, type(uint128).max);
        check_zeroPriceFillsNothing(remaining, assets);
        check_sharesFillable_boundedByRequestAndAssets(
            bound(remaining, 0, type(uint64).max),
            bound(assets, 0, type(uint64).max),
            bound(priceWad, 1, type(uint64).max)
        );
    }

    function testFuzz_claimable(uint256 requested, uint256 fulfilled, uint256 total, uint256 claimed) public pure {
        total = bound(total, 0, type(uint64).max);
        requested = bound(requested, 0, total);
        fulfilled = bound(fulfilled, 0, type(uint64).max);
        check_claimable_neverUnderflowsOrExceedsEntitlement(requested, fulfilled, total, claimed);
    }
}
