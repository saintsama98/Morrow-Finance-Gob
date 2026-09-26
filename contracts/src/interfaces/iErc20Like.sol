// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the ERC-20 surface Morrow calls on USDC and on parking venues.
// @author adiii.eth

pragma solidity 0.8.34;

interface iErc20Like {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}
