// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: fork group B: Morrow holds a live series inside real Midnight markets while the busiest real
// liquidation day (2026-07-16) is replayed transaction by transaction with the feed rounds of the time.
// @author adiii.eth

pragma solidity 0.8.34;

import {console} from "forge-std/console.sol";
import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {ForkBase, iChainlinkFeed} from "./ForkBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesState} from "../../src/interfaces/iSeries.sol";
import {iErc20Like} from "../../src/interfaces/iErc20Like.sol";

abstract contract ReplayBase is ForkBase {
    struct Replay {
        bytes32[] txs;
        uint256[] blocks;
        uint256[] stamps;
        uint256[5][] eth;
        uint256[5][] usdc;
        uint256[5][] btc;
    }

    address internal ourSafe = makeAddr("ourSafe");
    address internal ourEdge = makeAddr("ourEdge");

    function _vectorName() internal pure virtual returns (string memory);

    function _marketId() internal pure virtual returns (bytes32);

    function _afterAllowlist() internal override {
        vm.warp(forkStartTs);
    }

    function _load() internal view returns (Replay memory r) {
        string memory path = string.concat(vm.projectRoot(), "/sim/vectors/replay_", _vectorName(), ".hex");
        (r.txs, r.blocks, r.stamps, r.eth, r.usdc, r.btc) = abi.decode(
            vm.parseBytes(vm.readFile(path)),
            (bytes32[], uint256[], uint256[], uint256[5][], uint256[5][], uint256[5][])
        );
    }

    function _setFeed(address feed, uint256[5] memory round) internal {
        vm.mockCall(
            feed,
            abi.encodeWithSelector(iChainlinkFeed.latestRoundData.selector),
            abi.encode(uint80(round[0]), int256(round[1]), round[2], round[3], uint80(round[4]))
        );
    }

    function _replayDay() internal {
        Replay memory r = _load();
        _fundBooks(1_000_000e6, 400_000e6);
        Market memory m = midnight.toMarket(_marketId());
        (creditSeries s, bytes32 id) = _openSingle(m, 400_000e6, 100_000e6);
        assertEq(id, _marketId(), "the series lends into the real market");
        _borrow(s, 0, m, 150_000e6, ourSafe, 70);
        _borrow(s, 0, m, 150_000e6, ourEdge, 99);
        _checkStructure();

        uint256 creditBefore = midnight.credit(id, address(s));
        uint256 replayed;
        uint256 effects;
        for (uint256 k = 0; k < r.txs.length; k++) {
            vm.roll(r.blocks[k]);
            vm.warp(r.stamps[k]);
            _setFeed(ETH_USD_FEED, r.eth[k]);
            _setFeed(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B, r.usdc[k]);
            _setFeed(BTC_USD_FEED, r.btc[k]);
            if (_replayCall(k)) {
                replayed++;
            } else if (_replayEffect(m, k)) {
                effects++;
            }
            if (!midnight.isHealthy(m, id, ourEdge) && midnight.debt(id, ourEdge) > 0) {
                vm.prank(keeper);
                try midnight.liquidate(m, 0, 0, 1_000e6, ourEdge, false, keeper, address(0), "") {} catch {}
            }
            _checkStructure();
            (, uint128 lossNow,) = _lossView(m, id, address(s));
            assertLe(lossNow, creditBefore, "the series credit only moves through realized loss");
        }
        console.log("replayed real liquidation txs:", replayed, "of", r.txs.length);
        console.log("re-applied liquidation effects:", effects);
        assertGt(replayed + effects, 0, "real liquidations reached the fork");

        vm.clearMockedCalls();
        _finalizeByKeeper(s);
        _toSettling(s);
        _repayAll(m, id, ourSafe);
        _repayAll(m, id, ourEdge);
        vm.warp(s.T() + 1);
        _collectAll(s);
        vm.prank(keeper);
        s.settle();
        _checkStructure();
        assertEq(uint8(s.state()), uint8(SeriesState.SETTLED), "the series settles after the replayed day");
        assertEq(s.paidS(), s.seniorClaim(), "no realized loss reached senior");
        assertGt(_seniorExit(seniorVault.balanceOf(alice) / 2), 0, "senior exits still pay after the day");
    }

    address[] internal callFrom;
    address[] internal callTo;
    bytes[] internal callInput;
    uint256[] internal callValue;

    function _loadCalls() internal {
        string memory path = string.concat(vm.projectRoot(), "/sim/vectors/replay_", _vectorName(), "_calls.hex");
        (callFrom, callTo, callInput, callValue) =
            abi.decode(vm.parseBytes(vm.readFile(path)), (address[], address[], bytes[], uint256[]));
    }

    function _replayCall(uint256 k) internal returns (bool ok) {
        if (callFrom.length == 0) _loadCalls();
        vm.deal(callFrom[k], callFrom[k].balance + callValue[k] + 1 ether);
        vm.prank(callFrom[k], callFrom[k]);
        bytes memory ret;
        (ok, ret) = callTo[k].call{value: callValue[k]}(callInput[k]);
        if (!ok) console.logBytes(ret.length > 68 ? _head(ret) : ret);
    }

    address[] internal effBorrower;
    uint256[] internal effRepaid;
    bool[] internal effPost;

    function _loadEffects() internal {
        string memory path = string.concat(vm.projectRoot(), "/sim/vectors/replay_", _vectorName(), "_effects.hex");
        (,, address[] memory b,, uint256[] memory repaid, bool[] memory post,) = abi.decode(
            vm.parseBytes(vm.readFile(path)), (uint256[], address[], address[], uint256[], uint256[], bool[], uint256[])
        );
        effBorrower = b;
        effRepaid = repaid;
        effPost = post;
    }

    function _replayEffect(Market memory m, uint256 k) internal returns (bool ok) {
        if (effBorrower.length == 0) _loadEffects();
        if (k >= effBorrower.length || effRepaid[k] == 0) return false;
        _fund(USDC, keeper, effRepaid[k]);
        vm.startPrank(keeper);
        iErc20Like(USDC).approve(MIDNIGHT, effRepaid[k]);
        bytes memory ret;
        (ok, ret) = MIDNIGHT.call(
            abi.encodeCall(
                midnight.liquidate, (m, 0, 0, effRepaid[k], effBorrower[k], effPost[k], keeper, address(0), "")
            )
        );
        vm.stopPrank();
        if (!ok) console.logBytes(ret.length > 68 ? _head(ret) : ret);
    }

    function _head(bytes memory b) internal pure returns (bytes memory h) {
        h = new bytes(68);
        for (uint256 i = 0; i < 68; i++) {
            h[i] = b[i];
        }
    }

    function _lossView(Market memory m, bytes32 id, address who) internal view returns (uint128, uint128, uint128) {
        return midnight.updatePositionView(m, id, who);
    }
}

contract ForkReplayJul16WethTest is ReplayBase {
    function _pinnedBlock() internal pure override returns (uint256) {
        return 48_660_990;
    }

    function _vectorName() internal pure override returns (string memory) {
        return "jul16_we86";
    }

    function _marketId() internal pure override returns (bytes32) {
        return 0x10a033a31e0143f28ea28af165b8c931764f5679843754dea86a0c6320655eb2;
    }

    function test_B1_realLiquidationWave_wethMarket() public {
        _replayDay();
    }
}

contract ForkReplayJul16CbbtcTest is ReplayBase {
    function _pinnedBlock() internal pure override returns (uint256) {
        return 48_660_990;
    }

    function _vectorName() internal pure override returns (string memory) {
        return "jul16_cb915";
    }

    function _marketId() internal pure override returns (bytes32) {
        return 0xa28cffd5ae5f8b59335d974ef541aaf4c3d3beee5d12e28079eebfd1c5e2669f;
    }

    function test_B2_realLiquidationWave_cbbtcMarketAtTheCeiling() public {
        _replayDay();
    }
}
