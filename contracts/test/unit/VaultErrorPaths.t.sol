// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: every revert path of the two vaults and of the core's vault-only cash flows, by exact error.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {SeriesFactory} from "../../src/series/SeriesFactory.sol";
import {SeriesCore} from "../../src/core/SeriesCore.sol";
import {CoreStorage} from "../../src/core/modules/CoreStorage.sol";
import {USDCSeniorVault} from "../../src/vaults/senior/USDCSeniorVault.sol";
import {USDCJuniorVault} from "../../src/vaults/junior/USDCJuniorVault.sol";
import {USDCVaultBase} from "../../src/vaults/shared/USDCVaultBase.sol";
import {USDCJuniorRedeemQueue} from "../../src/vaults/junior/USDCJuniorRedeemQueue.sol";
import {IMidnightMinimal} from "../../src/interfaces/IMidnightMinimal.sol";
import {IParking} from "../../src/parking/IParking.sol";
import {IdleParking} from "../../src/parking/IdleParking.sol";

contract VaultErrorPathsTest is Test {
    MockUSDC usdc;
    IdleParking parking;
    SeriesFactory factory;
    SeriesCore core;
    USDCSeniorVault sv;
    USDCJuniorVault jv;

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
        sv = new USDCSeniorVault(core, address(usdc));
        jv = new USDCJuniorVault(core, address(usdc));
        vm.prank(governance);
        core.setVaults(address(sv), address(jv));

        address[3] memory users = [alice, bob, curator];
        for (uint256 i = 0; i < 3; i++) {
            usdc.mint(users[i], 10_000_000e6);
            vm.startPrank(users[i]);
            usdc.approve(address(sv), type(uint256).max);
            usdc.approve(address(jv), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _fundJunior(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        uint256 id = jv.requestDeposit(assets, who, who);
        vm.prank(curator);
        jv.closeDepositEpoch();
        vm.prank(curator);
        jv.fulfillDeposit(id, assets);
        vm.prank(who);
        shares = jv.claimDeposit(id);
    }

    function _fundSenior(address who, uint256 assets) internal returns (uint256 shares) {
        _fundJunior(bob, assets);
        vm.prank(who);
        shares = sv.deposit(assets, who);
    }

    // ---------------- senior vault ----------------

    function test_senior_zeroDepositAndMint() public {
        vm.startPrank(alice);
        vm.expectRevert(USDCVaultBase.ZeroAssets.selector);
        sv.deposit(0, alice);
        vm.expectRevert(USDCVaultBase.ZeroShares.selector);
        sv.mint(0, alice);
        vm.stopPrank();
    }

    function test_senior_requestRedeem_zeroAndTwice() public {
        uint256 shares = _fundSenior(alice, 100_000e6);
        vm.startPrank(alice);
        vm.expectRevert(USDCVaultBase.ZeroShares.selector);
        sv.requestRedeem(0, alice, alice);
        sv.requestRedeem(shares / 2, alice, alice);
        vm.expectRevert(USDCVaultBase.RequestAlreadyActive.selector);
        sv.requestRedeem(shares / 2, alice, alice);
        vm.stopPrank();
    }

    function test_senior_claimWithoutRequest() public {
        vm.startPrank(alice);
        vm.expectRevert(USDCVaultBase.NoActiveRequest.selector);
        sv.redeem(1, alice, alice);
        vm.expectRevert(USDCVaultBase.NoActiveRequest.selector);
        sv.withdraw(1, alice, alice);
        vm.stopPrank();
    }

    function test_senior_cancelTwice_andClaimNothing() public {
        uint256 shares = _fundSenior(alice, 100_000e6);
        vm.startPrank(alice);
        uint256 id = sv.requestRedeem(shares, alice, alice);
        vm.expectRevert(USDCVaultBase.NothingToCancel.selector);
        sv.claimCancelRedeemRequest(id, alice, alice);
        sv.cancelRedeemRequest(id, alice);
        vm.expectRevert(USDCVaultBase.PendingCancelation.selector);
        sv.cancelRedeemRequest(id, alice);
        sv.claimCancelRedeemRequest(id, alice, alice);
        vm.expectRevert(USDCVaultBase.NothingToCancel.selector);
        sv.claimCancelRedeemRequest(id, alice, alice);
        vm.stopPrank();
        assertEq(sv.balanceOf(alice), shares, "cancelled shares come back in full");
    }

    function test_senior_cancelAfterFullFill_hasNothingToCancel() public {
        uint256 shares = _fundSenior(alice, 100_000e6);
        vm.prank(alice);
        uint256 id = sv.requestRedeem(shares, alice, alice);
        vm.prank(curator);
        sv.closeEpoch();
        vm.prank(curator);
        sv.fulfill(id, type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + 14 days);
        vm.prank(alice);
        vm.expectRevert(USDCVaultBase.NothingToCancel.selector);
        sv.cancelRedeemRequest(id, alice);
    }

    function test_senior_strangerCannotActForController() public {
        uint256 shares = _fundSenior(alice, 100_000e6);
        vm.prank(alice);
        uint256 id = sv.requestRedeem(shares, alice, alice);
        vm.startPrank(bob);
        vm.expectRevert(USDCVaultBase.NotControllerOrOperator.selector);
        sv.cancelRedeemRequest(id, alice);
        vm.expectRevert(USDCVaultBase.NotControllerOrOperator.selector);
        sv.redeem(1, bob, alice);
        vm.stopPrank();
    }

    // ---------------- junior vault ----------------

    function test_junior_requestDeposit_zeroAndTwice() public {
        vm.startPrank(alice);
        vm.expectRevert(USDCVaultBase.ZeroAssets.selector);
        jv.requestDeposit(0, alice, alice);
        jv.requestDeposit(1_000e6, alice, alice);
        vm.expectRevert(USDCVaultBase.RequestAlreadyActive.selector);
        jv.requestDeposit(1_000e6, alice, alice);
        vm.stopPrank();
    }

    function test_junior_depositClaimWithoutRequest() public {
        vm.startPrank(alice);
        vm.expectRevert(USDCVaultBase.NoActiveRequest.selector);
        jv.deposit(1, alice, alice);
        vm.expectRevert(USDCVaultBase.NoActiveRequest.selector);
        jv.mint(1, alice, alice);
        vm.expectRevert(USDCVaultBase.NoActiveRequest.selector);
        jv.redeem(1, alice, alice);
        vm.expectRevert(USDCVaultBase.NoActiveRequest.selector);
        jv.withdraw(1, alice, alice);
        vm.stopPrank();
    }

    function test_junior_cancelDepositTwice_andClaimNothing() public {
        vm.startPrank(alice);
        uint256 id = jv.requestDeposit(1_000e6, alice, alice);
        vm.expectRevert(USDCVaultBase.NothingToCancel.selector);
        jv.claimCancelDepositRequest(id, alice, alice);
        jv.cancelDepositRequest(id, alice);
        vm.expectRevert(USDCVaultBase.PendingCancelation.selector);
        jv.cancelDepositRequest(id, alice);
        uint256 before = usdc.balanceOf(alice);
        jv.claimCancelDepositRequest(id, alice, alice);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice) - before, 1_000e6, "cancelled cash comes back in full");
        (,, uint256 pending) = core.junior();
        assertEq(pending, 0, "pending junior cash released on the core");
    }

    function test_junior_cancelDepositAfterFullFill_hasNothingToCancel() public {
        vm.prank(alice);
        uint256 id = jv.requestDeposit(1_000e6, alice, alice);
        vm.prank(curator);
        jv.closeDepositEpoch();
        vm.prank(curator);
        jv.fulfillDeposit(id, 1_000e6);
        vm.warp(vm.getBlockTimestamp() + 14 days);
        vm.prank(alice);
        vm.expectRevert(USDCVaultBase.NothingToCancel.selector);
        jv.cancelDepositRequest(id, alice);
    }

    function test_junior_requestRedeem_zeroAndTwice() public {
        uint256 shares = _fundJunior(alice, 100_000e6);
        vm.startPrank(alice);
        vm.expectRevert(USDCVaultBase.ZeroShares.selector);
        jv.requestRedeem(0, alice, alice);
        jv.requestRedeem(shares / 2, alice, alice);
        vm.expectRevert(USDCVaultBase.RequestAlreadyActive.selector);
        jv.requestRedeem(shares / 2, alice, alice);
        vm.stopPrank();
    }

    function test_junior_cancelRedeemTwice_andClaimNothing() public {
        uint256 shares = _fundJunior(alice, 100_000e6);
        vm.startPrank(alice);
        uint256 id = jv.requestRedeem(shares, alice, alice);
        vm.expectRevert(USDCVaultBase.NothingToCancel.selector);
        jv.claimCancelRedeemRequest(id, alice, alice);
        jv.cancelRedeemRequest(id, alice);
        vm.expectRevert(USDCVaultBase.PendingCancelation.selector);
        jv.cancelRedeemRequest(id, alice);
        jv.claimCancelRedeemRequest(id, alice, alice);
        vm.stopPrank();
        assertEq(jv.balanceOf(alice), shares);
    }

    /// The curator may not exit below its minimum share of jrUSDC supply.
    function test_junior_curatorBelowMinShare() public {
        uint256 cShares = _fundJunior(curator, 100_000e6);
        _fundJunior(alice, 800_000e6);
        vm.prank(curator);
        vm.expectRevert(USDCJuniorRedeemQueue.CuratorBelowMinShare.selector);
        jv.requestRedeem(cShares, curator, curator);

        // a partial exit that keeps it at or above 10% goes through
        uint256 keep = (jv.totalSupply() + 9) / 10;
        vm.prank(curator);
        jv.requestRedeem(cShares - keep, curator, curator);
    }

    // ---------------- core vault-only flows ----------------

    function test_core_vaultOnlyEntryPoints() public {
        vm.startPrank(alice);
        vm.expectRevert(CoreStorage.NotSeniorVault.selector);
        core.depositFor(true, 1);
        vm.expectRevert(CoreStorage.NotJuniorVault.selector);
        core.depositFor(false, 1);
        vm.expectRevert(CoreStorage.NotJuniorVault.selector);
        core.addPendingJunior(1);
        vm.expectRevert(CoreStorage.NotJuniorVault.selector);
        core.removePendingJunior(1, alice);
        vm.expectRevert(CoreStorage.NotJuniorVault.selector);
        core.investPendingJunior(1);
        vm.expectRevert(CoreStorage.NotSeniorVault.selector);
        core.reserveFor(true, 1);
        vm.expectRevert(CoreStorage.NotJuniorVault.selector);
        core.payFrom(false, alice, 1);
        vm.stopPrank();
    }

    function test_core_reserveFor_aboveParkingLiquidity() public {
        _fundJunior(alice, 1_000e6);
        uint256 liquid = core.parkingLiquidity();
        vm.prank(address(jv));
        vm.expectRevert(abi.encodeWithSelector(CoreStorage.ParkingIlliquid.selector, liquid + 1, liquid));
        core.reserveFor(false, liquid + 1);
    }

    function test_core_receiveHooks_onlyRegisteredSeries() public {
        vm.startPrank(alice);
        vm.expectRevert(CoreStorage.NotRegisteredSeries.selector);
        core.receiveReturn(0, 0);
        vm.expectRevert(CoreStorage.NotRegisteredSeries.selector);
        core.receivePayout(0, 0);
        vm.stopPrank();
    }

    function test_core_setVaults_onlyOnceAndOnlyGovernance() public {
        vm.prank(alice);
        vm.expectRevert(CoreStorage.NotGovernance.selector);
        core.setVaults(alice, alice);
        vm.prank(governance);
        vm.expectRevert(CoreStorage.VaultsAlreadySet.selector);
        core.setVaults(alice, alice);
    }
}
