// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: a third party must not be able to occupy another address's single request slot on either vault.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {seriesFactory} from "../../src/series/seriesFactory.sol";
import {seriesCore} from "../../src/core/seriesCore.sol";
import {usdcSeniorVault} from "../../src/vaults/senior/usdcSeniorVault.sol";
import {usdcJuniorVault} from "../../src/vaults/junior/usdcJuniorVault.sol";
import {iMidnightMinimal} from "../../src/interfaces/iMidnightMinimal.sol";
import {iParking} from "../../src/parking/iParking.sol";
import {idleParking} from "../../src/parking/idleParking.sol";
import {usdcVaultBase} from "../../src/vaults/shared/usdcVaultBase.sol";

contract ControllerSlotGriefingTest is Test {
    MockUSDC usdc;
    idleParking parking;
    seriesFactory factory;
    seriesCore core;
    usdcSeniorVault seniorVault;
    usdcJuniorVault juniorVault;

    address governance = makeAddr("governance");
    address allocator = makeAddr("allocator");
    address curator = makeAddr("curator");
    address sentinel = makeAddr("sentinel");
    address victim = makeAddr("victim");
    address mallory = makeAddr("mallory");

    function setUp() public {
        usdc = new MockUSDC();
        parking = new idleParking(address(usdc));
        factory = new seriesFactory(iMidnightMinimal(address(0x1)), address(0x2), address(usdc), governance, 0.86e18, 4);
        core = new seriesCore(
            address(usdc), factory, iParking(address(parking)), governance, allocator, curator, sentinel
        );
        vm.prank(governance);
        factory.setCore(address(core));
        seniorVault = new usdcSeniorVault(core, address(usdc));
        juniorVault = new usdcJuniorVault(core, address(usdc));
        vm.prank(governance);
        core.setVaults(address(seniorVault), address(juniorVault));
        usdc.mint(victim, 10_000_000e6);
        usdc.mint(mallory, 10_000_000e6);
    }

    function _fundJunior(address who, uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(juniorVault), assets);
        uint256 epochId = juniorVault.requestDeposit(assets, who, who);
        vm.stopPrank();
        vm.prank(curator);
        juniorVault.closeDepositEpoch();
        vm.prank(curator);
        juniorVault.fulfillDeposit(epochId, assets);
        vm.prank(who);
        shares = juniorVault.claimDeposit(epochId);
    }

    function _fundSenior(address who, uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(seniorVault), assets);
        shares = seniorVault.deposit(assets, who);
        vm.stopPrank();
    }

    function test_juniorRequestDeposit_forForeignController_reverts() public {
        vm.startPrank(mallory);
        usdc.approve(address(juniorVault), 1);
        vm.expectRevert(usdcVaultBase.NotControllerOrOperator.selector);
        juniorVault.requestDeposit(1, victim, mallory);
        vm.stopPrank();

        vm.startPrank(victim);
        usdc.approve(address(juniorVault), 1_000e6);
        juniorVault.requestDeposit(1_000e6, victim, victim);
        vm.stopPrank();
        assertEq(juniorVault.activeDepositRequestId(victim), 1);
    }

    function test_juniorRequestRedeem_forForeignController_reverts() public {
        _fundJunior(mallory, 1_000e6);
        vm.prank(mallory);
        vm.expectRevert(usdcVaultBase.NotControllerOrOperator.selector);
        juniorVault.requestRedeem(1, victim, mallory);
    }

    function test_seniorRequestRedeem_forForeignController_reverts() public {
        _fundJunior(victim, 1_000_000e6);
        _fundSenior(mallory, 1_000e6);
        vm.prank(mallory);
        vm.expectRevert(usdcVaultBase.NotControllerOrOperator.selector);
        seniorVault.requestRedeem(1, victim, mallory);
    }

    function test_operatorOfController_canStillRequestForIt() public {
        _fundJunior(victim, 1_000e6);
        uint256 shares = juniorVault.balanceOf(victim);
        vm.prank(victim);
        juniorVault.setOperator(mallory, true);
        vm.prank(mallory);
        juniorVault.requestRedeem(shares, victim, victim);
        assertEq(juniorVault.activeRedeemRequestId(victim), 1);
    }

    function test_dustRedeem_ownRequest_neverStrandsTheSlot() public {
        _fundJunior(victim, 1_000e6);
        vm.prank(victim);
        uint256 epochId = juniorVault.requestRedeem(1, victim, victim);
        vm.prank(curator);
        juniorVault.closeRedeemEpoch();
        vm.prank(curator);
        juniorVault.fulfillRedeem(epochId, type(uint256).max);

        assertEq(juniorVault.owedRedeemAssets(epochId, victim), 0, "one share-wei is worth zero USDC units");
        assertEq(juniorVault.claimableRedeemRequest(epochId, victim), 1);
        vm.prank(victim);
        assertEq(juniorVault.claimRedeem(epochId), 0);
        assertEq(juniorVault.activeRedeemRequestId(victim), 0, "a claim worth nothing must not hold the slot");
        uint256 shares = juniorVault.balanceOf(victim);
        vm.prank(victim);
        juniorVault.requestRedeem(shares, victim, victim);
    }

    function test_dustRedeem_partialClaimWorthNothing_stillReverts() public {
        _fundJunior(victim, 1_000e6);
        vm.prank(victim);
        uint256 epochId = juniorVault.requestRedeem(2, victim, victim);
        vm.prank(curator);
        juniorVault.closeRedeemEpoch();
        vm.prank(curator);
        juniorVault.fulfillRedeem(epochId, type(uint256).max);
        vm.prank(victim);
        vm.expectRevert(usdcVaultBase.NothingToClaim.selector);
        juniorVault.redeem(1, victim, victim);
    }

    function test_seniorDustRedeem_ownRequest_neverStrandsTheSlot() public {
        _fundJunior(mallory, 1_000_000e6);
        _fundSenior(victim, 1_000e6);
        vm.prank(victim);
        uint256 epochId = seniorVault.requestRedeem(1, victim, victim);
        vm.prank(curator);
        seniorVault.closeEpoch();
        vm.prank(curator);
        seniorVault.fulfill(epochId, type(uint256).max);
        assertEq(seniorVault.owedRedeemAssets(epochId, victim), 0);
        vm.prank(victim);
        assertEq(seniorVault.claim(epochId), 0);
        assertEq(seniorVault.activeRedeemRequestId(victim), 0, "a claim worth nothing must not hold the slot");
    }

    function test_requestDeposit_cannotPullFromAnOwnerWithStandingApproval() public {
        vm.prank(victim);
        usdc.approve(address(juniorVault), type(uint256).max);
        vm.prank(mallory);
        vm.expectRevert(usdcVaultBase.NotControllerOrOperator.selector);
        juniorVault.requestDeposit(1_000e6, mallory, victim);
        assertEq(usdc.balanceOf(victim), 10_000_000e6);
    }
}
