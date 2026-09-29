// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: adversarial parking venues for stress plan V.7: a lying venue that over-reports assets, a
// short-paying venue that withdraws less than asked, and a reentrant venue that calls back into the core.
// @author adiii.eth

pragma solidity 0.8.34;

import {iParking} from "../../src/parking/iParking.sol";
import {iErc20Like} from "../../src/interfaces/iErc20Like.sol";

interface iCoreSyncLike {
    function syncAll() external;
    function pruneSeries() external;
}

contract AdversarialParking is iParking {
    enum Mode {
        Honest,
        Lying,
        ShortPay,
        Reentrant
    }

    iErc20Like public immutable USDC;
    mapping(address => uint256) public balanceOf;
    Mode public mode;
    uint256 public lieBps = 1_000;
    uint256 public shortBps = 1_000;
    address public reentryTarget;
    uint256 public reentries;

    constructor(address usdc) {
        USDC = iErc20Like(usdc);
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setReentryTarget(address target) external {
        reentryTarget = target;
    }

    function deposit(uint256 assets) external {
        require(USDC.transferFrom(msg.sender, address(this), assets), "pull failed");
        balanceOf[msg.sender] += assets;
    }

    function withdraw(uint256 assets, address to) external {
        balanceOf[msg.sender] -= assets;
        uint256 sent = mode == Mode.ShortPay ? assets * (10_000 - shortBps) / 10_000 : assets;
        if (mode == Mode.Reentrant && reentryTarget != address(0)) {
            reentries++;
            iCoreSyncLike(reentryTarget).syncAll();
            iCoreSyncLike(reentryTarget).pruneSeries();
        }
        require(USDC.transfer(to, sent), "send failed");
    }

    function transferPosition(address to, uint256 assets) external {
        balanceOf[msg.sender] -= assets;
        balanceOf[to] += assets;
    }

    function totalAssets(address account) external view returns (uint256) {
        uint256 b = balanceOf[account];
        return mode == Mode.Lying ? b * (10_000 + lieBps) / 10_000 : b;
    }

    function maxWithdraw(address account) external view returns (uint256) {
        uint256 b = balanceOf[account];
        return mode == Mode.Lying ? b * (10_000 + lieBps) / 10_000 : b;
    }
}
