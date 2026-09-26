// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: parking adapter that earns yield in one Morpho ERC-4626 vault while keeping a USDC buffer.
// @author adiii.eth

pragma solidity 0.8.34;

import {iParking} from "./iParking.sol";
import {iErc20Like} from "../interfaces/iErc20Like.sol";
import {iErc4626Like} from "../interfaces/iErc4626Like.sol";
import {wadMath} from "../libraries/wadMath.sol";

contract morphoParking is iParking {
    using wadMath for uint256;

    error ZeroAddress();
    error AssetMismatch();
    error InvalidBuffer();
    error InsufficientBalance();
    error Illiquid(uint256 asked, uint256 available);
    error Reentrancy();
    error ZeroShares();
    error TransferFailed();

    event Deposited(address indexed account, uint256 assets, uint256 shares);
    event Withdrawn(address indexed account, address indexed to, uint256 assets, uint256 shares);
    event Transferred(address indexed from, address indexed to, uint256 assets, uint256 shares);
    event Rebalanced(uint256 buffer, uint256 vaultAssets);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant VIRTUAL_SHARES = 1e12;

    uint256 public constant DUST_ASSETS = 100;

    iErc20Like public immutable USDC;
    iErc4626Like public immutable VAULT;
    uint256 public immutable BUFFER_WAD;

    mapping(address account => uint256) public sharesOf;
    uint256 public totalShares;

    uint256 private _lock = 1;

    modifier nonReentrant() {
        require(_lock == 1, Reentrancy());
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address usdc, address vault, uint256 bufferWad) {
        require(usdc != address(0) && vault != address(0), ZeroAddress());
        require(iErc4626Like(vault).asset() == usdc, AssetMismatch());
        require(bufferWad <= WAD, InvalidBuffer());
        USDC = iErc20Like(usdc);
        VAULT = iErc4626Like(vault);
        BUFFER_WAD = bufferWad;
    }

    function deposit(uint256 assets) external nonReentrant {
        if (assets == 0) return;
        uint256 pool = poolAssets();
        uint256 shares = assets.mulDivDown(totalShares + VIRTUAL_SHARES, pool + 1);
        require(shares > 0, ZeroShares());

        sharesOf[msg.sender] += shares;
        totalShares += shares;
        require(USDC.transferFrom(msg.sender, address(this), assets), TransferFailed());
        emit Deposited(msg.sender, assets, shares);

        _investExcess();
    }

    function withdraw(uint256 assets, address to) external nonReentrant {
        if (assets == 0) return;
        require(to != address(0), ZeroAddress());
        uint256 shares = _burnFor(msg.sender, assets);

        _ensureBuffer(assets);
        require(USDC.transfer(to, assets), TransferFailed());
        emit Withdrawn(msg.sender, to, assets, shares);

        _refillIfLow();
    }

    function transferPosition(address to, uint256 assets) external nonReentrant {
        if (assets == 0) return;
        require(to != address(0), ZeroAddress());
        uint256 shares = _burnFor(msg.sender, assets);
        sharesOf[to] += shares;
        totalShares += shares;
        emit Transferred(msg.sender, to, assets, shares);
    }

    function totalAssets(address account) public view returns (uint256) {
        return sharesOf[account].mulDivDown(poolAssets() + 1, totalShares + VIRTUAL_SHARES);
    }

    function maxWithdraw(address account) external view returns (uint256) {
        uint256 owned = totalAssets(account);
        uint256 liquid = liquidity();
        return owned < liquid ? owned : liquid;
    }

    function poolAssets() public view returns (uint256) {
        return USDC.balanceOf(address(this)) + VAULT.previewRedeem(VAULT.balanceOf(address(this)));
    }

    function liquidity() public view returns (uint256) {
        return USDC.balanceOf(address(this)) + VAULT.maxWithdraw(address(this));
    }

    function rebalance() external nonReentrant {
        uint256 target = poolAssets().mulDivDown(BUFFER_WAD, WAD);
        uint256 buffer = USDC.balanceOf(address(this));
        if (buffer > target) _supply(buffer - target);
        else if (buffer < target) _pull(target - buffer);
        emit Rebalanced(USDC.balanceOf(address(this)), VAULT.previewRedeem(VAULT.balanceOf(address(this))));
    }

    function _investExcess() internal {
        uint256 target = poolAssets().mulDivDown(BUFFER_WAD, WAD);
        uint256 buffer = USDC.balanceOf(address(this));
        if (buffer > target) _supply(buffer - target);
    }

    function _refillIfLow() internal {
        uint256 target = poolAssets().mulDivDown(BUFFER_WAD, WAD);
        uint256 buffer = USDC.balanceOf(address(this));
        if (buffer < target / 2) _pull(target - buffer);
    }

    function _supply(uint256 amount) internal {
        uint256 cap = VAULT.maxDeposit(address(this));
        if (amount > cap) amount = cap;
        if (amount == 0) return;
        require(USDC.approve(address(VAULT), amount), TransferFailed());
        VAULT.deposit(amount, address(this));
    }

    function _pull(uint256 amount) internal {
        uint256 cap = VAULT.maxWithdraw(address(this));
        if (amount > cap) amount = cap;
        if (amount == 0) return;
        VAULT.withdraw(amount, address(this), address(this));
    }

    function _ensureBuffer(uint256 assets) internal {
        uint256 buffer = USDC.balanceOf(address(this));
        if (buffer >= assets) return;
        uint256 need = assets - buffer;
        uint256 available = VAULT.maxWithdraw(address(this));
        require(need <= available, Illiquid(assets, buffer + available));
        VAULT.withdraw(need, address(this), address(this));
    }

    function _burnFor(address account, uint256 assets) internal returns (uint256 shares) {
        uint256 pool = poolAssets();
        shares = assets.mulDivUp(totalShares + VIRTUAL_SHARES, pool + 1);
        uint256 held = sharesOf[account];
        if (shares > held) {
            uint256 heldValueUp = held.mulDivUp(pool + 1, totalShares + VIRTUAL_SHARES);
            require(assets <= heldValueUp + DUST_ASSETS, InsufficientBalance());
            shares = held;
        }
        sharesOf[account] = held - shares;
        totalShares -= shares;
    }
}
