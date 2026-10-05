// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: properties of the junior-first idle loss allocation (Halmos check_ targets with fuzz twins).
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {idleLossMath} from "../../src/libraries/idleLossMath.sol";

contract IdleLossMathTest is Test {
    uint256 constant PRICE_SCALE = 1e36;
    uint256 constant VIRTUAL = 1e6;

    function _run(uint256 s, uint256 j, uint256 parked, uint256 mark)
        internal
        pure
        returns (uint256 so, uint256 jo, uint256 loss)
    {
        return idleLossMath.effectiveClaims(s, j, s + j + VIRTUAL, parked, mark);
    }

    function _bounds(uint256 s, uint256 j, uint256 parked, uint256 mark) internal pure returns (bool) {
        return s <= type(uint96).max && j <= type(uint96).max && parked <= type(uint96).max
            && mark <= idleLossMath.claimPrice(type(uint96).max, s + j + VIRTUAL);
    }

    function check_conservation(uint256 s, uint256 j, uint256 parked, uint256 mark) public pure {
        vm.assume(_bounds(s, j, parked, mark));
        (uint256 so, uint256 jo,) = _run(s, j, parked, mark);
        assert(so + jo == s + j);
    }

    function check_onlyJuniorToSenior_andBounded(uint256 s, uint256 j, uint256 parked, uint256 mark) public pure {
        vm.assume(_bounds(s, j, parked, mark));
        (uint256 so, uint256 jo,) = _run(s, j, parked, mark);
        assert(so >= s && jo <= j);
        assert(so - s <= j);
    }

    function check_noMoveAtOrAboveTheMark(uint256 s, uint256 j, uint256 parked, uint256 mark) public pure {
        vm.assume(_bounds(s, j, parked, mark));
        vm.assume(idleLossMath.claimPrice(parked, s + j + VIRTUAL) >= mark);
        (uint256 so, uint256 jo, uint256 loss) = _run(s, j, parked, mark);
        assert(so == s && jo == j && loss == 0);
    }

    function check_seniorKeepsItsMarkedValue_whileJuniorCovers(uint256 s, uint256 j, uint256 parked, uint256 mark)
        public
        pure
    {
        vm.assume(_bounds(s, j, parked, mark));
        vm.assume(s > 0 && j > 0 && mark > 0);
        uint256 total = s + j + VIRTUAL;
        uint256 price = idleLossMath.claimPrice(parked, total);
        vm.assume(price < mark);
        (uint256 so, uint256 jo,) = _run(s, j, parked, mark);
        vm.assume(jo > 0);
        uint256 before = s * mark / PRICE_SCALE;
        uint256 afterValue = so * (parked + 1) / total;
        assert(afterValue + 2 + (parked + 1) / total >= before);
    }

    function testFuzz_conservation(uint256 s, uint256 j, uint256 parkedAtMark, uint256 parked) public pure {
        s = bound(s, 0, type(uint96).max);
        j = bound(j, 0, type(uint96).max);
        parkedAtMark = bound(parkedAtMark, 0, type(uint96).max);
        parked = bound(parked, 0, type(uint96).max);
        uint256 mark = idleLossMath.claimPrice(parkedAtMark, s + j + VIRTUAL);
        check_conservation(s, j, parked, mark);
        check_onlyJuniorToSenior_andBounded(s, j, parked, mark);
    }

    function testFuzz_seniorKeepsItsMarkedValue_whileJuniorCovers(
        uint256 s,
        uint256 j,
        uint256 parkedAtMark,
        uint256 lossBps
    ) public pure {
        s = bound(s, 1e6, 1e15);
        j = bound(j, 1e6, 1e15);
        parkedAtMark = bound(parkedAtMark, 1e6, 1e15);
        lossBps = bound(lossBps, 1, 10_000);
        uint256 total = s + j + VIRTUAL;
        uint256 mark = idleLossMath.claimPrice(parkedAtMark, total);
        uint256 parked = parkedAtMark - parkedAtMark * lossBps / 10_000;
        (uint256 so, uint256 jo,) = _run(s, j, parked, mark);
        if (jo == 0) return;
        uint256 before = s * mark / PRICE_SCALE;
        uint256 afterValue = so * (parked + 1) / total;
        assertGe(
            afterValue + 2 + (parked + 1) / total, before, "senior keeps its value at the mark while junior covers"
        );
    }

    function testFuzz_seniorKeepsItsExactPreLossValue_atProtocolClaimScale(
        uint256 seniorAssets,
        uint256 juniorAssets,
        uint256 yieldBps,
        uint256 lossBps
    ) public pure {
        seniorAssets = bound(seniorAssets, 1e6, 1e17);
        juniorAssets = bound(juniorAssets, 1e6, 1e17);
        yieldBps = bound(yieldBps, 0, 5_000);
        lossBps = bound(lossBps, 1, 10_000);
        uint256 s = seniorAssets * VIRTUAL;
        uint256 j = juniorAssets * VIRTUAL;
        uint256 total = s + j + VIRTUAL;
        uint256 parkedAtMark = (seniorAssets + juniorAssets) * (10_000 + yieldBps) / 10_000;
        uint256 mark = idleLossMath.claimPrice(parkedAtMark, total);
        uint256 exactBefore = s * (parkedAtMark + 1) / total;
        uint256 parked = parkedAtMark - parkedAtMark * lossBps / 10_000;
        (uint256 so, uint256 jo,) = _run(s, j, parked, mark);
        if (jo == 0) return;
        uint256 afterValue = so * (parked + 1) / total;
        assertGe(afterValue + 2, exactBefore, "senior keeps its exact pre-loss value while junior covers");
    }
}
