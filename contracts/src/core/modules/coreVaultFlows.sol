// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the vault-only entry points that move USDC into, between and out of the core's books.
// @author adiii.eth

pragma solidity 0.8.34;

import {coreGovernance} from "./coreGovernance.sol";
import {iErc20Like} from "../../interfaces/iErc20Like.sol";

abstract contract coreVaultFlows is coreGovernance {
    function depositFor(bool isSenior, uint256 assets) external {
        _requireVault(isSenior);
        _depositToBook(isSenior, assets);
    }

    function addPendingJunior(uint256 assets) external onlyJuniorVault {
        junior.pendingDeposits += assets;
    }

    function removePendingJunior(uint256 assets, address to) external onlyJuniorVault {
        junior.pendingDeposits -= assets;
        require(iErc20Like(USDC).transfer(to, assets), "transfer failed");
    }

    function investPendingJunior(uint256 assets) external onlyJuniorVault {
        junior.pendingDeposits -= assets;
        _depositToBook(false, assets);
    }

    function reserveFor(bool isSenior, uint256 assets) external {
        _requireVault(isSenior);
        uint256 liquid = PARKING.maxWithdraw(address(this));
        require(assets <= liquid, ParkingIlliquid(assets, liquid));
        if (isSenior) {
            _removeFromBooks(assets, 0);
            senior.reservedAssets += assets;
        } else {
            _removeFromBooks(0, assets);
            junior.reservedAssets += assets;
        }
        PARKING.withdraw(assets, address(this));
    }

    function payFrom(bool isSenior, address to, uint256 assets) external {
        _requireVault(isSenior);
        if (isSenior) senior.reservedAssets -= assets;
        else junior.reservedAssets -= assets;
        require(iErc20Like(USDC).transfer(to, assets), "transfer failed");
    }

    function _requireVault(bool isSenior) internal view {
        if (isSenior) {
            require(msg.sender == seniorVault, NotSeniorVault());
        } else {
            require(msg.sender == juniorVault, NotJuniorVault());
        }
    }
}
