// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: unit tests for usdcSeniorVault: deposits, redemption epochs, and pro-rata claims.
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
import {usdcSeniorDeposits} from "../../src/vaults/senior/usdcSeniorDeposits.sol";

contract SeniorVaultTest is Test {
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
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

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

        usdc.mint(alice, 10_000_000e6);
        usdc.mint(bob, 10_000_000e6);
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

    function test_deposit_mintsAtGenesisPrice() public {
        _fundJunior(bob, 1_000_000e6);

        vm.startPrank(alice);
        usdc.approve(address(seniorVault), 500_000e6);
        uint256 shares = seniorVault.deposit(500_000e6, alice);
        vm.stopPrank();

        assertEq(shares, 500_000e6 * 1e12, "genesis price is 1 USDC per whole share");
        assertEq(seniorVault.balanceOf(alice), shares);
        assertEq(core.seniorAssets(), 500_000e6);
    }

    function test_deposit_revertsWhenCapacityExceeded() public {
        _fundJunior(bob, 100_000e6);

        vm.startPrank(alice);
        usdc.approve(address(seniorVault), 500_000e6);
        vm.expectRevert(usdcSeniorDeposits.CapacityExceeded.selector);
        seniorVault.deposit(500_000e6, alice);
        vm.stopPrank();
    }

    function test_deposit_revertsWhenStressGateClosed() public {
        _fundJunior(bob, 1_000_000e6);
        vm.mockCall(address(core), abi.encodeWithSelector(core.stressGateOpen.selector), abi.encode(false));

        vm.startPrank(alice);
        usdc.approve(address(seniorVault), 100e6);
        vm.expectRevert(usdcSeniorDeposits.StressGateClosed.selector);
        seniorVault.deposit(100e6, alice);
        vm.stopPrank();
    }

    function test_deposit_revertsWhenPaused() public {
        _fundJunior(bob, 1_000_000e6);
        vm.prank(curator);
        core.pause();

        vm.startPrank(alice);
        usdc.approve(address(seniorVault), 100e6);
        vm.expectRevert(usdcVaultBase.DepositsPaused.selector);
        seniorVault.deposit(100e6, alice);
        vm.stopPrank();
    }

    function test_requestRedeem_escrowsShares() public {
        _fundJunior(bob, 1_000_000e6);
        uint256 shares = _depositSenior(alice, 500_000e6);

        vm.prank(alice);
        uint256 epochId = seniorVault.requestRedeem(shares, alice, alice);

        assertEq(epochId, 1);
        assertEq(seniorVault.balanceOf(alice), 0, "shares must leave the redeemer's balance");
        assertEq(seniorVault.balanceOf(address(seniorVault)), shares, "shares must be escrowed in the vault");
        assertEq(seniorVault.requestedShares(epochId, alice), shares);
    }

    function test_closeEpoch_onlyOperator() public {
        vm.expectRevert(usdcVaultBase.NotOperator.selector);
        seniorVault.closeEpoch();
    }

    function test_fulfill_boundedByIdleAvailable() public {
        _fundJunior(bob, 1_000_000e6);
        uint256 shares = _depositSenior(alice, 400_000e6);

        vm.prank(alice);
        uint256 epochId = seniorVault.requestRedeem(shares, alice, alice);
        vm.prank(curator);
        seniorVault.closeEpoch();

        uint256 available = core.idleAvailable(true);
        assertLt(available, 400_000e6, "idle floor must bound what's fulfillable");

        vm.prank(curator);
        seniorVault.fulfill(epochId, type(uint256).max);

        (uint256 totalRequested,, uint256 sharesFulfilled, uint256 assetsFulfilled,,) = seniorVault.epochs(epochId);
        assertEq(totalRequested, shares);
        assertLt(sharesFulfilled, shares, "fulfillment must be partial, bounded by the idle floor");
        assertEq(assetsFulfilled, available);
    }

    function test_fulfill_multiRound_claimIsMonotonicAndBounded() public {
        _fundJunior(bob, 4_000_000e6);
        uint256 shares = _depositSenior(alice, 1_000_000e6);

        vm.prank(alice);
        uint256 epochId = seniorVault.requestRedeem(shares, alice, alice);
        vm.prank(curator);
        seniorVault.closeEpoch();

        uint256 available1 = core.idleAvailable(true);
        vm.prank(curator);
        seniorVault.fulfill(epochId, 300_000e6);
        vm.prank(alice);
        uint256 claim1 = seniorVault.claim(epochId);
        assertEq(claim1, 300_000e6 < available1 ? 300_000e6 : available1);

        uint256 available2 = core.idleAvailable(true);
        vm.prank(curator);
        seniorVault.fulfill(epochId, 700_000e6);
        vm.prank(alice);
        uint256 claim2 = seniorVault.claim(epochId);
        assertEq(claim2, 700_000e6 < available2 ? 700_000e6 : available2);

        assertGt(claim2, 0, "second round must still make progress");
        assertLe(claim1 + claim2, 1_000_000e6, "cumulative claims must never exceed the requested redemption");
    }

    function test_claim_paysProRata_twoUsers() public {
        _fundJunior(bob, 4_000_000e6);
        uint256 aliceShares = _depositSenior(alice, 300_000e6);
        uint256 bobShares = _depositSenior(bob, 700_000e6);

        vm.prank(alice);
        uint256 epochId = seniorVault.requestRedeem(aliceShares, alice, alice);
        vm.prank(bob);
        seniorVault.requestRedeem(bobShares, bob, bob);
        vm.prank(curator);
        seniorVault.closeEpoch();

        vm.prank(curator);
        seniorVault.fulfill(epochId, type(uint256).max);

        vm.prank(alice);
        uint256 aliceAssets = seniorVault.claim(epochId);
        vm.prank(bob);
        uint256 bobAssets = seniorVault.claim(epochId);

        assertApproxEqAbs(aliceAssets * 7, bobAssets * 3, 10, "claims must split pro rata by request size");
    }

    function test_cancelRedeemRequest_thenClaim_returnsFullAmount() public {
        _fundJunior(bob, 4_000_000e6);
        uint256 shares = _depositSenior(alice, 1_000_000e6);

        vm.prank(alice);
        uint256 epochId = seniorVault.requestRedeem(shares, alice, alice);

        vm.prank(alice);
        seniorVault.cancelRedeemRequest(epochId, alice);
        uint256 pending = seniorVault.claimableCancelRedeemRequest(epochId, alice);
        assertEq(pending, shares, "with the epoch still open nothing has been filled, so the whole request cancels");
        assertEq(seniorVault.balanceOf(alice), 0, "stage 1 must not move any shares yet");

        vm.prank(alice);
        seniorVault.claimCancelRedeemRequest(epochId, alice, alice);
        assertEq(seniorVault.balanceOf(alice), pending, "stage 2 must pay out exactly the pending-canceled shares");
    }

    function test_cancelRedeemRequest_afterEpochCloses_reverts() public {
        _fundJunior(bob, 4_000_000e6);
        uint256 shares = _depositSenior(alice, 1_000_000e6);

        vm.prank(alice);
        uint256 epochId = seniorVault.requestRedeem(shares, alice, alice);
        vm.prank(curator);
        seniorVault.closeEpoch();

        vm.prank(alice);
        vm.expectRevert(usdcVaultBase.EpochAlreadyClosed.selector);
        seniorVault.cancelRedeemRequest(epochId, alice);
    }

    function _depositSenior(address who, uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(seniorVault), assets);
        shares = seniorVault.deposit(assets, who);
        vm.stopPrank();
    }
}
