// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: unit tests for usdcJuniorVault: deposit and redemption epochs, and pro-rata claims.
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

contract JuniorVaultTest is Test {
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

    function _requestDeposit(address who, uint256 assets) internal returns (uint256 epochId) {
        vm.startPrank(who);
        usdc.approve(address(juniorVault), assets);
        epochId = juniorVault.requestDeposit(assets, who, who);
        vm.stopPrank();
    }

    function test_requestDeposit_queuesPendingOnCore() public {
        _requestDeposit(alice, 500_000e6);

        (,, uint256 pending) = core.junior();
        assertEq(pending, 500_000e6, "requested cash must sit as pending on the core");
        assertEq(usdc.balanceOf(address(core)), 500_000e6, "cash must move straight to the core");
        assertEq(juniorVault.requestedAssets(1, alice), 500_000e6);
    }

    function test_closeDepositEpoch_fulfill_claim_mintsAtGenesisPrice() public {
        uint256 epochId = _requestDeposit(alice, 500_000e6);

        vm.prank(curator);
        juniorVault.closeDepositEpoch();
        vm.prank(curator);
        juniorVault.fulfillDeposit(epochId, 500_000e6);

        vm.prank(alice);
        uint256 shares = juniorVault.claimDeposit(epochId);

        assertEq(shares, 500_000e6 * 1e12, "genesis price is 1 USDC per whole share");
        assertEq(juniorVault.balanceOf(alice), shares);
        assertEq(core.juniorAssets(), 500_000e6);
    }

    function test_fulfillDeposit_beforeClose_reverts() public {
        uint256 epochId = _requestDeposit(alice, 500_000e6);
        vm.prank(curator);
        vm.expectRevert(usdcVaultBase.EpochNotClosed.selector);
        juniorVault.fulfillDeposit(epochId, 500_000e6);
    }

    function test_claimDeposit_paysProRata_twoUsers() public {
        uint256 epochId = _requestDeposit(alice, 300_000e6);
        _requestDeposit(bob, 700_000e6);

        vm.prank(curator);
        juniorVault.closeDepositEpoch();
        vm.prank(curator);
        juniorVault.fulfillDeposit(epochId, 1_000_000e6);

        vm.prank(alice);
        uint256 aliceShares = juniorVault.claimDeposit(epochId);
        vm.prank(bob);
        uint256 bobShares = juniorVault.claimDeposit(epochId);

        assertApproxEqAbs(aliceShares * 7, bobShares * 3, 10, "shares must split pro rata by requested assets");
        assertEq(aliceShares + bobShares, core.juniorAssets() * 1e12, "sum of claimed shares must match total invested");
    }

    function test_cancelDepositRequest_thenClaim_refundsFullAmount() public {
        uint256 epochId = _requestDeposit(alice, 1_000_000e6);

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        juniorVault.cancelDepositRequest(epochId, alice);
        uint256 pending = juniorVault.claimableCancelDepositRequest(epochId, alice);
        assertEq(
            pending, 1_000_000e6, "with the epoch still open nothing has been invested, so the full request cancels"
        );
        assertEq(usdc.balanceOf(alice), balanceBefore, "stage 1 must not move any cash yet");

        vm.prank(alice);
        juniorVault.claimCancelDepositRequest(epochId, alice, alice);
        assertEq(usdc.balanceOf(alice), balanceBefore + pending);
    }

    function test_cancelDepositRequest_afterEpochCloses_reverts() public {
        uint256 epochId = _requestDeposit(alice, 1_000_000e6);
        vm.prank(curator);
        juniorVault.closeDepositEpoch();

        vm.prank(alice);
        vm.expectRevert(usdcVaultBase.EpochAlreadyClosed.selector);
        juniorVault.cancelDepositRequest(epochId, alice);
    }

    function _fundJunior(address who, uint256 assets) internal returns (uint256 shares) {
        uint256 epochId = _requestDeposit(who, assets);
        vm.prank(curator);
        juniorVault.closeDepositEpoch();
        vm.prank(curator);
        juniorVault.fulfillDeposit(epochId, assets);
        vm.prank(who);
        shares = juniorVault.claimDeposit(epochId);
    }

    function test_requestRedeem_escrowsShares() public {
        uint256 shares = _fundJunior(alice, 1_000_000e6);

        vm.prank(alice);
        uint256 epochId = juniorVault.requestRedeem(shares, alice, alice);

        assertEq(juniorVault.balanceOf(alice), 0);
        assertEq(juniorVault.balanceOf(address(juniorVault)), shares);
        assertEq(juniorVault.requestedShares(epochId, alice), shares);
    }

    function test_fulfillRedeem_boundedByJuniorRedeemable() public {
        uint256 shares = _fundJunior(alice, 1_000_000e6);
        vm.startPrank(bob);
        usdc.approve(address(seniorVault), 3_000_000e6);
        seniorVault.deposit(3_000_000e6, bob);
        vm.stopPrank();

        vm.prank(alice);
        uint256 epochId = juniorVault.requestRedeem(shares, alice, alice);
        vm.prank(curator);
        juniorVault.closeRedeemEpoch();

        uint256 available = core.juniorRedeemable();
        assertLt(available, 1_000_000e6, "coverage floor must bound redeemable junior assets");

        vm.prank(curator);
        juniorVault.fulfillRedeem(epochId, type(uint256).max);

        (uint256 totalRequested,, uint256 sharesFulfilled, uint256 assetsFulfilled,,) =
            juniorVault.redeemEpochs(epochId);
        assertEq(totalRequested, shares);
        assertLt(sharesFulfilled, shares, "fulfillment must be partial, bounded by the coverage floor");
        assertEq(assetsFulfilled, available);
    }

    function test_claimRedeem_multiRound() public {
        uint256 shares = _fundJunior(alice, 1_000_000e6);

        vm.prank(alice);
        uint256 epochId = juniorVault.requestRedeem(shares, alice, alice);
        vm.prank(curator);
        juniorVault.closeRedeemEpoch();

        vm.prank(curator);
        juniorVault.fulfillRedeem(epochId, 100_000e6);
        vm.prank(alice);
        uint256 claim1 = juniorVault.claimRedeem(epochId);
        assertEq(claim1, 100_000e6);

        vm.prank(curator);
        juniorVault.fulfillRedeem(epochId, 100_000e6);
        vm.prank(alice);
        uint256 claim2 = juniorVault.claimRedeem(epochId);
        assertEq(claim2, 100_000e6);
    }

    function test_cancelRedeemRequest_thenClaim_returnsFullAmount() public {
        uint256 shares = _fundJunior(alice, 1_000_000e6);

        vm.prank(alice);
        uint256 epochId = juniorVault.requestRedeem(shares, alice, alice);

        vm.prank(alice);
        juniorVault.cancelRedeemRequest(epochId, alice);
        uint256 pending = juniorVault.claimableCancelRedeemRequest(epochId, alice);
        assertEq(pending, shares, "with the epoch still open nothing has been filled, so the whole request cancels");
        assertEq(juniorVault.balanceOf(alice), 0, "stage 1 must not move any shares yet");

        vm.prank(alice);
        juniorVault.claimCancelRedeemRequest(epochId, alice, alice);
        assertEq(juniorVault.balanceOf(alice), pending);
    }

    function test_cancelRedeemRequest_afterEpochCloses_reverts() public {
        uint256 shares = _fundJunior(alice, 1_000_000e6);

        vm.prank(alice);
        uint256 epochId = juniorVault.requestRedeem(shares, alice, alice);
        vm.prank(curator);
        juniorVault.closeRedeemEpoch();

        vm.prank(alice);
        vm.expectRevert(usdcVaultBase.EpochAlreadyClosed.selector);
        juniorVault.cancelRedeemRequest(epochId, alice);
    }
}
