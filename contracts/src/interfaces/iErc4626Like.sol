// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the ERC-4626 surface Morrow calls on the Morpho vault behind parking.
// @author adiii.eth

pragma solidity 0.8.34;

interface iErc4626Like {
    function asset() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function maxWithdraw(address owner) external view returns (uint256);
    function maxDeposit(address receiver) external view returns (uint256);
}
