// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: F10: random interleaving of vault actions, no value moves except by price.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {SeriesRegistry} from "./handlers/SeriesRegistry.sol";
import {VaultHandler} from "./handlers/VaultHandler.sol";
import {EpochHandler} from "./handlers/EpochHandler.sol";

contract F10_NoValueLeakageTest is Test {
    SeriesRegistry registry;
    VaultHandler vaultHandler;
    EpochHandler epochHandler;

    function setUp() public {
        registry = new SeriesRegistry();
        vaultHandler = new VaultHandler(registry);
        epochHandler = new EpochHandler(registry);

        targetContract(address(vaultHandler));
        targetContract(address(epochHandler));

        vaultHandler.juniorRequestDeposit(0, 2_000_000e6);
        epochHandler.closeJuniorDepositEpoch();
        epochHandler.fulfillJuniorDeposit(1, type(uint128).max);
        epochHandler.claimJuniorDeposit(0, 1);
        vaultHandler.seniorDeposit(0, 2_000_000e6);

        assertGt(registry.seniorVault().totalSupply(), 0, "setUp seed senior deposit did not land");
        assertGt(registry.juniorVault().totalSupply(), 0, "setUp seed junior deposit did not land");
    }

    function invariant_F10_noValueLeakage() public view {
        uint256 grossIn = vaultHandler.ghost_grossUsdcIn();
        uint256 grossOut = vaultHandler.ghost_grossUsdcOut() + epochHandler.ghost_grossUsdcOut();
        uint256 stillInSystem = registry.usdc().balanceOf(address(registry.realCore()))
            + registry.parking().totalAssets(address(registry.realCore()));

        assertEq(
            grossIn - grossOut,
            stillInSystem,
            "F10: net gross USDC flow (in - out) must equal exactly what the core still holds, directly or via parking"
        );
    }
}
