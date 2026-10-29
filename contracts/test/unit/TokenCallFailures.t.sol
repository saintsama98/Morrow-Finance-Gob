// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: unit tests for USDC calls that return false: every such call reverts with a custom error.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {SeriesFactory} from "../../src/series/SeriesFactory.sol";
import {SeriesCore} from "../../src/core/SeriesCore.sol";
import {CoreStorage} from "../../src/core/modules/CoreStorage.sol";
import {USDCSeniorVault} from "../../src/vaults/senior/USDCSeniorVault.sol";
import {USDCJuniorVault} from "../../src/vaults/junior/USDCJuniorVault.sol";
import {IMidnightMinimal} from "../../src/interfaces/IMidnightMinimal.sol";
import {IParking} from "../../src/parking/IParking.sol";
import {IdleParking} from "../../src/parking/IdleParking.sol";
import {USDCVaultBase} from "../../src/vaults/shared/USDCVaultBase.sol";

contract TokenCallFailuresTest is Test {
    MockUSDC usdc;
    IdleParking parking;
    SeriesFactory factory;
    SeriesCore core;
    USDCSeniorVault seniorVault;
    USDCJuniorVault juniorVault;

    address governance = makeAddr("governance");
    address allocator = makeAddr("allocator");
    address curator = makeAddr("curator");
    address sentinel = makeAddr("sentinel");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockUSDC();
        parking = new IdleParking(address(usdc));
        factory = new SeriesFactory(IMidnightMinimal(address(0x1)), address(0x2), address(usdc), governance, 0.86e18, 4);
        core = new SeriesCore(
            address(usdc), factory, IParking(address(parking)), governance, allocator, curator, sentinel
        );
        vm.prank(governance);
        factory.setCore(address(core));

        seniorVault = new USDCSeniorVault(core, address(usdc));
        juniorVault = new USDCJuniorVault(core, address(usdc));
        vm.prank(governance);
        core.setVaults(address(seniorVault), address(juniorVault));

        usdc.mint(alice, 10_000_000e6);
        usdc.mint(bob, 10_000_000e6);
    }

    function _fundJunior(address who, uint256 assets) internal {
        vm.startPrank(who);
        usdc.approve(address(juniorVault), assets);
        uint256 epochId = juniorVault.requestDeposit(assets, who, who);
        vm.stopPrank();

        vm.prank(curator);
        juniorVault.closeDepositEpoch();
        vm.prank(curator);
        juniorVault.fulfillDeposit(epochId, assets);

        vm.prank(who);
        juniorVault.claimDeposit(epochId);
    }

    function _failTransfer() internal {
        vm.mockCall(address(usdc), abi.encodeWithSelector(MockUSDC.transfer.selector), abi.encode(false));
    }

    function _failTransferFrom() internal {
        vm.mockCall(address(usdc), abi.encodeWithSelector(MockUSDC.transferFrom.selector), abi.encode(false));
    }

    function test_seniorDeposit_revertsWhenTransferFromReturnsFalse() public {
        _fundJunior(bob, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(seniorVault), 500_000e6);
        _failTransferFrom();
        vm.expectRevert(USDCVaultBase.TransferFailed.selector);
        seniorVault.deposit(500_000e6, alice);
        vm.stopPrank();
    }

    function test_seniorMint_revertsWhenTransferFromReturnsFalse() public {
        _fundJunior(bob, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(seniorVault), 500_000e6);
        _failTransferFrom();
        vm.expectRevert(USDCVaultBase.TransferFailed.selector);
        seniorVault.mint(500_000e6 * 1e12, alice);
        vm.stopPrank();
    }

    function test_juniorRequestDeposit_revertsWhenTransferFromReturnsFalse() public {
        vm.startPrank(alice);
        usdc.approve(address(juniorVault), 100_000e6);
        _failTransferFrom();
        vm.expectRevert(USDCVaultBase.TransferFailed.selector);
        juniorVault.requestDeposit(100_000e6, alice, alice);
        vm.stopPrank();
    }

    function test_depositToBook_revertsWhenApproveReturnsFalse() public {
        _fundJunior(bob, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(seniorVault), 500_000e6);
        vm.mockCall(address(usdc), abi.encodeWithSelector(MockUSDC.approve.selector), abi.encode(false));
        vm.expectRevert(CoreStorage.ApproveFailed.selector);
        seniorVault.deposit(500_000e6, alice);
        vm.stopPrank();
    }

    function test_removePendingJunior_revertsWhenTransferReturnsFalse() public {
        usdc.mint(address(core), 100_000e6);
        vm.startPrank(address(juniorVault));
        core.addPendingJunior(100_000e6);
        _failTransfer();
        vm.expectRevert(CoreStorage.TransferFailed.selector);
        core.removePendingJunior(100_000e6, alice);
        vm.stopPrank();
    }

    function test_payFrom_revertsWhenTransferReturnsFalse() public {
        _fundJunior(bob, 1_000_000e6);
        vm.startPrank(address(juniorVault));
        core.reserveFor(false, 100_000e6);
        _failTransfer();
        vm.expectRevert(CoreStorage.TransferFailed.selector);
        core.payFrom(false, alice, 100_000e6);
        vm.stopPrank();
    }

    function test_idleParking_revertsWhenTokenCallsReturnFalse() public {
        vm.startPrank(alice);
        usdc.approve(address(parking), 100_000e6);
        parking.deposit(100_000e6);

        _failTransfer();
        vm.expectRevert(IdleParking.TransferFailed.selector);
        parking.withdraw(100_000e6, alice);

        _failTransferFrom();
        vm.expectRevert(IdleParking.TransferFailed.selector);
        parking.deposit(100_000e6);
        vm.stopPrank();
    }
}
