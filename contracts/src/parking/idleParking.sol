// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: default parking adapter: holds USDC as-is, no yield.
// @author adiii.eth

pragma solidity 0.8.34;

import {iParking} from "./iParking.sol";
import {iErc20Like} from "../interfaces/iErc20Like.sol";

contract idleParking is iParking {
    error InsufficientBalance();
    error ZeroAddress();

    iErc20Like public immutable USDC;
    mapping(address account => uint256) public balanceOf;

    constructor(address usdc) {
        USDC = iErc20Like(usdc);
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
        require(to != address(0), ZeroAddress());
        balanceOf[msg.sender] -= assets;
        balanceOf[to] += assets;
    }

    function totalAssets(address account) external view returns (uint256) {
        return balanceOf[account];
    }

    function maxWithdraw(address account) external view returns (uint256) {
        return balanceOf[account];
    }
}
