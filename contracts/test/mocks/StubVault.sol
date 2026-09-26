// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: minimal stand-in vault, letting seriesCore's accounting be tested before the real vaults exist.
// @author adiii.eth

pragma solidity 0.8.34;

import {seriesCore} from "../../src/core/seriesCore.sol";

interface IERC20Mintable {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract StubVault {
    seriesCore public core;
    address public usdc;
    bool public isSenior;

    constructor(seriesCore core_, address usdc_, bool isSenior_) {
        core = core_;
        usdc = usdc_;
        isSenior = isSenior_;
    }

    function deposit(uint256 assets) external {
        require(IERC20Mintable(usdc).transfer(address(core), assets), "transfer failed");
        core.depositFor(isSenior, assets);
    }

    function requestDepositJunior(uint256 assets) external {
        require(IERC20Mintable(usdc).transfer(address(core), assets), "transfer failed");
        core.addPendingJunior(assets);
    }

    function cancelDepositJunior(uint256 assets, address to) external {
        core.removePendingJunior(assets, to);
    }

    function fulfillDepositJunior(uint256 assets) external {
        core.investPendingJunior(assets);
    }

    function reserve(uint256 assets) external {
        core.reserveFor(isSenior, assets);
    }

    function pay(address to, uint256 assets) external {
        core.payFrom(isSenior, to, assets);
    }
}
