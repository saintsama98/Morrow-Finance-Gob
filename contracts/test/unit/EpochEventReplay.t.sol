// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: I26: an indexer can rebuild every senior exit batch, and every canceller's frozen part, from events.
// @author adiii.eth

pragma solidity 0.8.34;

import {Vm} from "forge-std/Test.sol";
import {ScenarioBase} from "../scenario/ScenarioBase.t.sol";
import {wadMath} from "../../src/libraries/wadMath.sol";

contract EpochEventReplayTest is ScenarioBase {
    using wadMath for uint256;

    struct Batch {
        uint256 total;
        uint256 remaining;
        uint256 sharesFilled;
        uint256 assetsFilled;
        uint256 pps;
        bool closed;
    }

    mapping(uint256 => Batch) replayed;
    mapping(uint256 => mapping(address => uint256)) replayRequested;
    mapping(uint256 => mapping(address => uint256)) replayFrozenShares;
    mapping(uint256 => mapping(address => uint256)) replayFrozenAssets;

    address stayer = makeAddr("stayer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    function test_seniorExitBatches_rebuildExactlyFromEvents() public {
        _juniorDeposit(makeAddr("juniorSeed"), 2_000_000e6);
        _seniorDeposit(stayer, 1_000_000e6);
        uint256 sA = _seniorDeposit(alice, 120_000e6);
        uint256 sB = _seniorDeposit(bob, 70_000e6);
        uint256 sC = _seniorDeposit(carol, 45_000e6);
        uint256 sD = _seniorDeposit(dave, 33_000e6);
        address curator = registry.CURATOR();

        vm.recordLogs();

        vm.prank(alice);
        uint256 first = seniorVault.requestRedeem(sA, alice, alice);
        vm.prank(bob);
        seniorVault.requestRedeem(sB, bob, bob);
        vm.prank(carol);
        seniorVault.requestRedeem(sC / 3, carol, carol);
        vm.prank(alice);
        seniorVault.cancelRedeemRequest(first, alice);

        vm.prank(curator);
        seniorVault.closeEpoch();
        vm.prank(curator);
        seniorVault.fulfill(first, 31_337e6);

        vm.warp(block.timestamp + seniorVault.CANCEL_AFTER_CLOSE());
        vm.prank(bob);
        seniorVault.cancelRedeemRequest(first, bob);
        vm.prank(curator);
        seniorVault.fulfill(first, type(uint128).max);

        vm.prank(dave);
        uint256 second = seniorVault.requestRedeem(sD, dave, dave);
        vm.prank(curator);
        seniorVault.closeEpoch();
        vm.prank(curator);
        seniorVault.fulfill(second, 10_000e6);

        _replay(vm.getRecordedLogs());

        address[4] memory who = [alice, bob, carol, dave];
        for (uint256 id = first; id <= second; id++) {
            (uint256 t, uint256 r, uint256 sf, uint256 af, uint256 pps, bool closed) = seniorVault.epochs(id);
            Batch storage b = replayed[id];
            assertEq(b.total, t, "I26: total requested rebuilt from events");
            assertEq(b.remaining, r, "I26: remaining rebuilt from events");
            assertEq(b.sharesFilled, sf, "I26: shares filled rebuilt from events");
            assertEq(b.assetsFilled, af, "I26: assets filled rebuilt from events");
            assertEq(b.pps, pps, "I26: close price rebuilt from events");
            assertEq(b.closed, closed, "I26: closed flag rebuilt from events");
            for (uint256 k = 0; k < who.length; k++) {
                assertEq(
                    replayRequested[id][who[k]], seniorVault.requestedShares(id, who[k]), "I26: live request rebuilt"
                );
                assertEq(
                    replayFrozenShares[id][who[k]], seniorVault.frozenShares(id, who[k]), "I26: frozen shares rebuilt"
                );
                assertEq(
                    replayFrozenAssets[id][who[k]], seniorVault.frozenAssets(id, who[k]), "I26: frozen assets rebuilt"
                );
            }
        }
        assertGt(replayFrozenShares[first][bob], 0, "sanity: the timeout cancel froze a partly filled position");
    }

    function _replay(Vm.Log[] memory logs) internal {
        bytes32 requestTopic = keccak256("RedeemRequest(address,address,uint256,address,uint256)");
        bytes32 cancelTopic = keccak256("CancelRedeemRequest(address,uint256,address)");
        bytes32 closeTopic = keccak256("EpochClosed(uint256,uint256)");
        bytes32 fillTopic = keccak256("RedeemFulfilled(uint256,uint256,uint256,uint256)");

        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];
            if (log.emitter != address(seniorVault)) continue;
            bytes32 topic = log.topics[0];

            if (topic == requestTopic) {
                address controller = address(uint160(uint256(log.topics[1])));
                uint256 id = uint256(log.topics[3]);
                (, uint256 shares) = abi.decode(log.data, (address, uint256));
                replayRequested[id][controller] += shares;
                replayed[id].total += shares;
                replayed[id].remaining += shares;
            } else if (topic == closeTopic) {
                uint256 id = uint256(log.topics[1]);
                replayed[id].closed = true;
                replayed[id].pps = abi.decode(log.data, (uint256));
            } else if (topic == fillTopic) {
                uint256 id = uint256(log.topics[1]);
                (uint256 shares, uint256 assets,) = abi.decode(log.data, (uint256, uint256, uint256));
                replayed[id].remaining -= shares;
                replayed[id].sharesFilled += shares;
                replayed[id].assetsFilled += assets;
            } else if (topic == cancelTopic) {
                address controller = address(uint160(uint256(log.topics[1])));
                uint256 id = uint256(log.topics[2]);
                Batch storage b = replayed[id];
                uint256 requested = replayRequested[id][controller];
                uint256 liveShares = requested.mulDivDown(b.sharesFilled, b.total);
                uint256 liveAssets = requested.mulDivDown(b.assetsFilled, b.total);
                replayFrozenShares[id][controller] += liveShares;
                replayFrozenAssets[id][controller] += liveAssets;
                replayRequested[id][controller] = 0;
                b.total -= requested;
                b.sharesFilled -= liveShares;
                b.assetsFilled -= liveAssets;
                b.remaining -= requested - liveShares;
            }
        }
    }
}
