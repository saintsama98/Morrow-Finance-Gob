// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: pulling one requester out of a batch never dilutes the others and keeps the batch ledger valid.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {wadMath} from "../../src/libraries/wadMath.sol";

contract EpochDetachMathTest is Test {
    using wadMath for uint256;

    function _isFloorDiv(uint256 q, uint256 x, uint256 y, uint256 d) internal pure returns (bool) {
        unchecked {
            return q * d <= x * y && x * y < (q + 1) * d;
        }
    }

    function _detachHolds(uint256 total, uint256 filled, uint256 requested, uint256 other) internal pure {
        uint256 liveOut = requested.mulDivDown(filled, total);
        uint256 otherBefore = other.mulDivDown(filled, total);
        assert(_isFloorDiv(liveOut, requested, filled, total));
        assert(_isFloorDiv(otherBefore, other, filled, total));

        uint256 totalAfter = total - requested;
        uint256 filledAfter = filled - liveOut;

        assert(filledAfter <= totalAfter);
        assert(requested - liveOut == (total - filled) - (totalAfter - filledAfter));
        if (totalAfter > 0) {
            uint256 otherAfter = other.mulDivDown(filledAfter, totalAfter);
            assert(_isFloorDiv(otherAfter, other, filledAfter, totalAfter));
            assert(otherAfter >= otherBefore);
            assert(otherAfter <= other);
        }
    }

    function check_detachNeverDilutesOthers(
        uint64 total,
        uint64 filled,
        uint64 requested,
        uint64 other,
        uint64 liveOut,
        uint64 otherBefore,
        uint64 otherAfter
    ) public pure {
        vm.assume(total > 0 && filled <= total && requested > 0);
        vm.assume(uint256(requested) + other <= total);
        vm.assume(_isFloorDiv(liveOut, requested, filled, total));
        vm.assume(_isFloorDiv(otherBefore, other, filled, total));

        assert(liveOut <= filled);
        uint256 totalAfter;
        uint256 filledAfter;
        unchecked {
            totalAfter = uint256(total) - requested;
            filledAfter = uint256(filled) - liveOut;
        }
        assert(filledAfter <= totalAfter);

        if (totalAfter > 0) {
            vm.assume(_isFloorDiv(otherAfter, other, filledAfter, totalAfter));
            assert(otherAfter >= otherBefore);
            assert(otherAfter <= other);
        }
    }

    function testFuzz_detachNeverDilutesOthers(uint128 total, uint128 filled, uint128 requested, uint128 other)
        public
        pure
    {
        total = uint128(bound(total, 1, type(uint128).max));
        filled = uint128(bound(filled, 0, total));
        requested = uint128(bound(requested, 1, total));
        other = uint128(bound(other, 0, total - requested));
        _detachHolds(total, filled, requested, other);
    }
}
