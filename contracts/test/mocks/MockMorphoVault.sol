// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: ERC-4626 stand-in for a Morpho vault, with yield, loss and liquidity controls for tests.
// @author adiii.eth

pragma solidity 0.8.34;

import {MockUSDC} from "./MockUSDC.sol";

contract MockMorphoVault {
    MockUSDC public immutable USDC;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint256 public liquidityCap = type(uint256).max;
    uint256 public depositCap = type(uint256).max;

    constructor(MockUSDC usdc) {
        USDC = usdc;
    }

    function asset() external view returns (address) {
        return address(USDC);
    }

    function totalAssets() public view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets * (totalSupply + 1) / (totalAssets() + 1);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * (totalAssets() + 1) / (totalSupply + 1);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    function maxDeposit(address) external view returns (uint256) {
        return depositCap;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        uint256 owned = convertToAssets(balanceOf[owner]);
        return owned < liquidityCap ? owned : liquidityCap;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(assets <= depositCap, "deposit cap");
        shares = convertToShares(assets);
        require(USDC.transferFrom(msg.sender, address(this), assets), "transferFrom");
        balanceOf[receiver] += shares;
        totalSupply += shares;
        if (depositCap != type(uint256).max) depositCap -= assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        require(msg.sender == owner, "owner only");
        require(assets <= liquidityCap, "illiquid");
        uint256 supply = totalSupply;
        shares = (assets * (supply + 1) + totalAssets()) / (totalAssets() + 1);
        balanceOf[owner] -= shares;
        totalSupply = supply - shares;
        if (liquidityCap != type(uint256).max) liquidityCap -= assets;
        require(USDC.transfer(receiver, assets), "transfer");
    }

    function accrueBps(uint256 bps) external {
        USDC.mint(address(this), totalAssets() * bps / 10_000);
    }

    function loseBps(uint256 bps) external {
        uint256 loss = totalAssets() * bps / 10_000;
        require(USDC.transfer(address(0xdead), loss), "transfer");
    }

    function setLiquidityCap(uint256 cap) external {
        liquidityCap = cap;
    }

    function setDepositCap(uint256 cap) external {
        depositCap = cap;
    }
}
