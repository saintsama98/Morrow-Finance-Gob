// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: test-only parking adapter that can be told to realize a real value loss (S10).
// @author adiii.eth

pragma solidity 0.8.34;

import {iParking} from "../../src/parking/iParking.sol";

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract LossyParking is iParking {
    error InsufficientBalance();

    IERC20Like public immutable USDC;
    mapping(address account => uint256) public balanceOf;

    constructor(address usdc) {
        USDC = IERC20Like(usdc);
    }

    function deposit(uint256 assets) external {
        require(USDC.transferFrom(msg.sender, address(this), assets), InsufficientBalance());
        balanceOf[msg.sender] += assets;
    }

    function withdraw(uint256 assets, address to) external {
        balanceOf[msg.sender] -= assets;
        require(USDC.transfer(to, assets), InsufficientBalance());
    }

    function transferPosition(address to, uint256 assets) external {
        require(to != address(0), InsufficientBalance());
        balanceOf[msg.sender] -= assets;
        balanceOf[to] += assets;
    }

    function totalAssets(address account) external view returns (uint256) {
        return balanceOf[account];
    }

    function maxWithdraw(address account) external view returns (uint256) {
        return balanceOf[account];
    }

    function applyLoss(address account, uint256 bps) external returns (uint256 loss) {
        loss = balanceOf[account] * bps / 10_000;
        balanceOf[account] -= loss;
        require(USDC.transfer(address(0xdead), loss), InsufficientBalance());
    }
}
