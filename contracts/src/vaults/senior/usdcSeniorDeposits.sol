// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: srUSDC's synchronous ERC-4626 entry, gated by pause, the stress gate and senior capacity.
// @author adiii.eth

pragma solidity 0.8.34;

import {usdcVaultBase} from "../shared/usdcVaultBase.sol";
import {iErc20Like} from "../../interfaces/iErc20Like.sol";

/// @notice Synchronous ERC-4626 deposits, limited by senior capacity and the stress gate.
abstract contract usdcSeniorDeposits is usdcVaultBase {
    error StressGateClosed();
    error CapacityExceeded();

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    /// @notice Assets that can be deposited now.
    function maxDeposit(address) public view returns (uint256) {
        if (CORE.paused() || !CORE.stressGateOpen()) return 0;
        uint256 assetsNow = CORE.seniorAssets();
        uint256 capacity = CORE.seniorCapacity();
        return assetsNow >= capacity ? 0 : capacity - assetsNow;
    }

    /// @notice Shares that can be minted now.
    function maxMint(address receiver) external view returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    /// @notice Shares a deposit would mint.
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    /// @notice Assets a mint would cost.
    function previewMint(uint256 shares) external view returns (uint256) {
        return _convertToAssetsUp(shares);
    }

    /// @notice Deposits assets for shares.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(assets > 0, ZeroAssets());
        require(!CORE.paused(), DepositsPaused());
        require(CORE.stressGateOpen(), StressGateClosed());
        CORE.syncAll();
        require(CORE.seniorAssets() + assets <= CORE.seniorCapacity(), CapacityExceeded());

        shares = convertToShares(assets);
        require(shares > 0, ZeroShares());

        require(iErc20Like(USDC).transferFrom(msg.sender, address(CORE), assets), "transfer failed");
        CORE.depositFor(true, assets);

        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Mints shares for assets.
    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        require(shares > 0, ZeroShares());
        require(!CORE.paused(), DepositsPaused());
        require(CORE.stressGateOpen(), StressGateClosed());
        CORE.syncAll();

        assets = _convertToAssetsUp(shares);
        require(assets > 0, ZeroAssets());
        require(CORE.seniorAssets() + assets <= CORE.seniorCapacity(), CapacityExceeded());

        require(iErc20Like(USDC).transferFrom(msg.sender, address(CORE), assets), "transfer failed");
        CORE.depositFor(true, assets);

        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }
}
