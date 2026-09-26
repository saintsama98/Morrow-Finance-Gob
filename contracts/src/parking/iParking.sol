// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: adapter interface for parking idle capital between deployments.
// @author adiii.eth

pragma solidity 0.8.34;

interface iParking {
    function deposit(uint256 assets) external;

    function withdraw(uint256 assets, address to) external;

    function transferPosition(address to, uint256 assets) external;

    function totalAssets(address account) external view returns (uint256);

    function maxWithdraw(address account) external view returns (uint256);
}
