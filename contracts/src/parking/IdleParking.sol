// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {IParking} from "./IParking.sol";

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @dev Holds USDC as-is, no yield. section 3.2: "IdleParking holds usdc as is".
contract IdleParking is IParking {
    error InsufficientBalance();

    IERC20Like public immutable USDC;
    mapping(address account => uint256) public balanceOf;

    constructor(address usdc) {
        USDC = IERC20Like(usdc);
    }

    /// @dev Caller must have approved this contract for `assets` beforehand.
    function deposit(uint256 assets) external {
        require(USDC.transferFrom(msg.sender, address(this), assets), InsufficientBalance());
        balanceOf[msg.sender] += assets;
    }

    function withdraw(uint256 assets, address to) external {
        balanceOf[msg.sender] -= assets;
        require(USDC.transfer(to, assets), InsufficientBalance());
    }

    function totalAssets(address account) external view returns (uint256) {
        return balanceOf[account];
    }
}
