// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {IParking} from "./IParking.sol";

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// Morrow Finance — default parking adapter: holds USDC as-is, no yield.
// @author adiii.eth

/// @notice Holds deposited USDC one-to-one per depositor, no yield, no rehypothecation.
contract IdleParking is IParking {
    error InsufficientBalance();

    IERC20Like public immutable USDC;
    mapping(address account => uint256) public balanceOf; // each depositor's parked balance, in asset units

    constructor(address usdc) {
        USDC = IERC20Like(usdc);
    }

    /// @notice Pulls `assets` of USDC from the caller, who must have approved this contract beforehand.
    function deposit(uint256 assets) external {
        require(USDC.transferFrom(msg.sender, address(this), assets), InsufficientBalance());
        balanceOf[msg.sender] += assets;
    }

    /// @notice Sends `assets` of the caller's own balance to `to`.
    function withdraw(uint256 assets, address to) external {
        balanceOf[msg.sender] -= assets;
        require(USDC.transfer(to, assets), InsufficientBalance());
    }

    /// @notice Returns the account's parked balance.
    function totalAssets(address account) external view returns (uint256) {
        return balanceOf[account];
    }
}
