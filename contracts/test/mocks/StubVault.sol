// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {SeriesCore} from "../../src/core/SeriesCore.sol";

interface IERC20Mintable {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Minimal stand-in for SeniorVault/JuniorVault (M6/M7), exposing thin passthroughs to SeriesCore's
/// vault-only functions so SeriesCore's own accounting can be tested before the real vaults exist (M5, mirrors
/// StubCore's role for Series in M2).
contract StubVault {
    SeriesCore public core;
    address public usdc;
    bool public isSenior;

    constructor(SeriesCore core_, address usdc_, bool isSenior_) {
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
