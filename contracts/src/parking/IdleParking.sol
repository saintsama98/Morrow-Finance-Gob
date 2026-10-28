// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: default parking adapter: holds USDC as-is, no yield.
// @author adiii.eth

pragma solidity 0.8.34;

import {IParking} from "./IParking.sol";
import {IERC20Like} from "../interfaces/IERC20Like.sol";

/// @notice Parking that holds plain USDC.
contract IdleParking is IParking {
    error TransferFailed();
    error ZeroAddress();

    IERC20Like public immutable USDC;
    mapping(address account => uint256) public balanceOf;

    constructor(address usdc) {
        USDC = IERC20Like(usdc);
    }

    /// @notice Parks assets for the caller.
    function deposit(uint256 assets) external {
        require(USDC.transferFrom(msg.sender, address(this), assets), TransferFailed());
        balanceOf[msg.sender] += assets;
    }

    /// @notice Withdraws the caller's assets to an address.
    function withdraw(uint256 assets, address to) external {
        balanceOf[msg.sender] -= assets;
        require(USDC.transfer(to, assets), TransferFailed());
    }

    /// @notice Moves part of the caller's position to another account.
    function transferPosition(address to, uint256 assets) external {
        require(to != address(0), ZeroAddress());
        balanceOf[msg.sender] -= assets;
        balanceOf[to] += assets;
    }

    /// @notice Value of an account's position.
    function totalAssets(address account) external view returns (uint256) {
        return balanceOf[account];
    }

    /// @notice Assets an account can withdraw now.
    function maxWithdraw(address account) external view returns (uint256) {
        return balanceOf[account];
    }
}
