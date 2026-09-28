// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: registerOffers accepts exactly the roots, padding and leaf hashes the Midnight SDK builds.
// @author adiii.eth

pragma solidity 0.8.34;

import {Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {HashLib} from "@morpho-org/midnight/src/ratifiers/libraries/HashLib.sol";
import {ScenarioBase} from "../scenario/ScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";

contract OfferTreeSdkDifferentialTest is ScenarioBase {
    creditSeries series;

    function setUp() public override {
        super.setUp();
        _juniorDeposit(makeAddr("juniorSeed"), 400_000e6);
        _seniorDeposit(makeAddr("seniorSeed"), 1_000_000e6);
        (address seriesAddr,) = _openSeries(400_000e6, 100_000e6, block.timestamp + 45 days);
        series = creditSeries(seriesAddr);
    }

    function _vector(uint256 n) internal view returns (bytes32 root, bytes32[] memory leaves, Offer[] memory offers) {
        string memory path = string.concat(vm.projectRoot(), "/sim/vectors/offer_tree_", vm.toString(n), ".hex");
        (root, leaves, offers) = abi.decode(vm.parseBytes(vm.readFile(path)), (bytes32, bytes32[], Offer[]));
    }

    function _check(uint256 n, uint256 padded) internal {
        (bytes32 root, bytes32[] memory leaves, Offer[] memory offers) = _vector(n);
        assertEq(offers.length, padded, "the sdk pads to the next power of two");
        for (uint256 i = 0; i < offers.length; i++) {
            assertEq(HashLib.hashOffer(offers[i]), leaves[i], "leaf hash matches the sdk");
            if (i >= n) assertEq(offers[i].maker, address(0), "padding leaves are the empty offer");
        }
        vm.prank(registry.ALLOCATOR());
        series.registerOffers(root, offers);
        assertTrue(series.rootRegistered(root), "registerOffers recomputes the sdk root");
    }

    function test_sdkTree_1() public {
        _check(1, 1);
    }

    function test_sdkTree_2() public {
        _check(2, 2);
    }

    function test_sdkTree_3_paddedTo4() public {
        _check(3, 4);
    }

    function test_sdkTree_5_paddedTo8() public {
        _check(5, 8);
    }

    function test_sdkTree_8() public {
        _check(8, 8);
    }

    function test_sdkTree_33_paddedTo64_atTheContractCap() public {
        _check(33, 64);
    }

    function test_sdkRoot_withOneLeafChanged_isRejected() public {
        (bytes32 root,, Offer[] memory offers) = _vector(5);
        offers[1].tick += 4;
        vm.prank(registry.ALLOCATOR());
        vm.expectRevert();
        series.registerOffers(root, offers);
    }
}
