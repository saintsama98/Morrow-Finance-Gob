// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: standards compliance tests for both vaults.
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
import {usdcJuniorDepositQueue} from "../../src/vaults/junior/usdcJuniorDepositQueue.sol";

contract StandardsComplianceTest is Test {
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
    address op = makeAddr("op");

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

    function _fundJuniorViaJunior(address who, uint256 assets) internal returns (uint256 shares) {
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

    function _depositSenior(address who, uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(seniorVault), assets);
        shares = seniorVault.deposit(assets, who);
        vm.stopPrank();
    }

    function test_supportsInterface_senior_exactIds() public view {
        assertTrue(seniorVault.supportsInterface(0x01ffc9a7), "erc165");
        assertTrue(seniorVault.supportsInterface(0xe3bc4e65), "erc7540 operator");
        assertTrue(seniorVault.supportsInterface(0x2f0a18c5), "erc7575");
        assertTrue(seniorVault.supportsInterface(0x620ee8e4), "erc7540 async redeem");
        assertTrue(seniorVault.supportsInterface(0xe76cffc7), "erc7887 redeem cancelation");
        assertFalse(seniorVault.supportsInterface(0xce3bbe50), "erc7540 async deposit must be false: sync deposits");
        assertFalse(seniorVault.supportsInterface(0x8bf840e3), "erc7887 deposit cancelation: no deposit requests exist");
        assertFalse(seniorVault.supportsInterface(0xdeadbeef), "unknown id must be false");
    }

    function test_supportsInterface_junior_exactIds() public view {
        assertTrue(juniorVault.supportsInterface(0x01ffc9a7), "erc165");
        assertTrue(juniorVault.supportsInterface(0xce3bbe50), "erc7540 async deposit");
        assertTrue(juniorVault.supportsInterface(0x620ee8e4), "erc7540 async redeem");
        assertTrue(juniorVault.supportsInterface(0xe3bc4e65), "erc7540 operator");
        assertTrue(juniorVault.supportsInterface(0x2f0a18c5), "erc7575");
        assertTrue(juniorVault.supportsInterface(0x8bf840e3), "erc7887 deposit cancelation");
        assertTrue(juniorVault.supportsInterface(0xe76cffc7), "erc7887 redeem cancelation");
        assertFalse(juniorVault.supportsInterface(0xdeadbeef), "unknown id must be false");
    }

    function test_previewFunctions_senior_asyncRedeemSide_revert() public {
        vm.expectRevert(usdcVaultBase.AsyncPreviewUnsupported.selector);
        seniorVault.previewRedeem(1);
        vm.expectRevert(usdcVaultBase.AsyncPreviewUnsupported.selector);
        seniorVault.previewWithdraw(1);
        vm.prank(bob);
        vm.expectRevert(usdcVaultBase.AsyncPreviewUnsupported.selector);
        seniorVault.previewRedeem(type(uint256).max);
    }

    function test_previewFunctions_junior_bothSides_revert() public {
        vm.expectRevert(usdcVaultBase.AsyncPreviewUnsupported.selector);
        juniorVault.previewDeposit(1);
        vm.expectRevert(usdcVaultBase.AsyncPreviewUnsupported.selector);
        juniorVault.previewMint(1);
        vm.expectRevert(usdcVaultBase.AsyncPreviewUnsupported.selector);
        juniorVault.previewRedeem(1);
        vm.expectRevert(usdcVaultBase.AsyncPreviewUnsupported.selector);
        juniorVault.previewWithdraw(1);
        vm.prank(bob);
        vm.expectRevert(usdcVaultBase.AsyncPreviewUnsupported.selector);
        juniorVault.previewDeposit(type(uint256).max);
    }

    function test_requestRedeem_doesNotPayOut_onlyEscrows() public {
        _fundJuniorViaJunior(bob, 4_000_000e6);
        uint256 shares = _depositSenior(alice, 500_000e6);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        seniorVault.requestRedeem(shares, alice, alice);

        assertEq(usdc.balanceOf(alice), usdcBefore, "a request must not pay out any assets");
        assertEq(seniorVault.balanceOf(alice), 0, "shares must be escrowed, not burned or returned");
    }

    function test_fulfillThenClaim_sameBlock_succeeds() public {
        _fundJuniorViaJunior(bob, 4_000_000e6);
        uint256 shares = _depositSenior(alice, 500_000e6);

        vm.prank(alice);
        uint256 epochId = seniorVault.requestRedeem(shares, alice, alice);
        vm.prank(curator);
        seniorVault.closeEpoch();

        vm.prank(curator);
        seniorVault.fulfill(epochId, type(uint256).max);
        vm.prank(alice);
        uint256 assets = seniorVault.claim(epochId);
        assertGt(assets, 0, "claim must succeed in the same block as fulfillment, with no delay");
    }

    function test_claim_nonOperator_reverts_approvedOperator_succeeds() public {
        _fundJuniorViaJunior(bob, 4_000_000e6);
        uint256 shares = _depositSenior(alice, 500_000e6);

        vm.prank(alice);
        uint256 epochId = seniorVault.requestRedeem(shares, alice, alice);
        vm.prank(curator);
        seniorVault.closeEpoch();
        vm.prank(curator);
        seniorVault.fulfill(epochId, type(uint256).max);

        uint256 claimable = seniorVault.claimableRedeemRequest(epochId, alice);

        vm.prank(bob);
        vm.expectRevert(usdcVaultBase.NotControllerOrOperator.selector);
        seniorVault.redeem(claimable, bob, alice);

        vm.prank(alice);
        seniorVault.setOperator(op, true);
        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        vm.prank(op);
        uint256 assets = seniorVault.redeem(claimable, bob, alice);
        assertGt(assets, 0, "an approved operator must be able to claim on the controller's behalf");
        assertEq(usdc.balanceOf(bob) - bobUsdcBefore, assets, "assets must land with the receiver op specified");
    }

    function test_setOperator_emitsEventAndReturnsTrue() public {
        vm.expectEmit(true, true, false, true, address(seniorVault));
        emit usdcVaultBase.OperatorSet(alice, op, true);
        vm.prank(alice);
        bool ok = seniorVault.setOperator(op, true);
        assertTrue(ok, "setOperator must return true");
        assertTrue(seniorVault.isOperator(alice, op));

        vm.prank(alice);
        seniorVault.setOperator(op, false);
        assertFalse(seniorVault.isOperator(alice, op));
    }

    function test_requestRedeem_viaAllowance_spendsIt() public {
        _fundJuniorViaJunior(bob, 4_000_000e6);
        uint256 shares = _depositSenior(alice, 500_000e6);

        vm.prank(alice);
        seniorVault.approve(bob, shares);
        assertEq(seniorVault.allowance(alice, bob), shares);

        vm.prank(bob);
        seniorVault.requestRedeem(shares, bob, alice);

        assertEq(seniorVault.allowance(alice, bob), 0, "the erc20 allowance must be spent down by the pulled shares");
    }

    function test_requestRedeem_viaOperator_doesNotTouchAllowance() public {
        _fundJuniorViaJunior(bob, 4_000_000e6);
        uint256 shares = _depositSenior(alice, 500_000e6);

        vm.prank(alice);
        seniorVault.setOperator(bob, true);
        assertEq(seniorVault.allowance(alice, bob), 0);

        vm.prank(bob);
        seniorVault.requestRedeem(shares, bob, alice);
        assertEq(
            seniorVault.balanceOf(address(seniorVault)),
            shares,
            "an operator can pull owner's shares with zero allowance"
        );
    }

    function test_requestRedeem_withoutAllowanceOrOperator_reverts() public {
        _fundJuniorViaJunior(bob, 4_000_000e6);
        uint256 shares = _depositSenior(alice, 500_000e6);

        vm.prank(bob);
        vm.expectRevert();
        seniorVault.requestRedeem(shares, bob, alice);
    }

    function test_requestDeposit_insufficientBalance_revertsEntirely_noPartial() public {
        address poor = makeAddr("poor");
        usdc.mint(poor, 100e6);
        vm.startPrank(poor);
        usdc.approve(address(juniorVault), 1_000e6);
        vm.expectRevert();
        juniorVault.requestDeposit(1_000e6, poor, poor);
        vm.stopPrank();

        assertEq(juniorVault.requestedAssets(1, poor), 0, "a reverted request must leave no partial trace");
    }

    function test_juniorDepositClaim_eventOrder_controllerFirstReceiverSecond() public {
        vm.startPrank(alice);
        usdc.approve(address(juniorVault), 500_000e6);
        uint256 epochId = juniorVault.requestDeposit(500_000e6, alice, alice);
        vm.stopPrank();
        vm.prank(curator);
        juniorVault.closeDepositEpoch();
        vm.prank(curator);
        juniorVault.fulfillDeposit(epochId, 500_000e6);

        uint256 claimable = juniorVault.claimableDepositRequest(epochId, alice);
        vm.expectEmit(true, true, false, true, address(juniorVault));
        emit usdcJuniorDepositQueue.Deposit(alice, bob, claimable, claimable * 1e12);
        vm.prank(alice);
        juniorVault.deposit(claimable, bob, alice);
    }

    function test_cancelRedeemRequest_claimPaysExactlyTheCanceledAmount() public {
        _fundJuniorViaJunior(bob, 4_000_000e6);
        uint256 shares = _depositSenior(alice, 500_000e6);

        vm.prank(alice);
        uint256 epochId = seniorVault.requestRedeem(shares, alice, alice);
        vm.prank(alice);
        seniorVault.cancelRedeemRequest(epochId, alice);
        uint256 pending = seniorVault.claimableCancelRedeemRequest(epochId, alice);

        uint256 balBefore = seniorVault.balanceOf(alice);
        vm.prank(alice);
        seniorVault.claimCancelRedeemRequest(epochId, alice, alice);
        assertEq(
            seniorVault.balanceOf(alice) - balBefore,
            pending,
            "claim must pay exactly the pending-canceled amount, no more"
        );
        assertEq(seniorVault.claimableCancelRedeemRequest(epochId, alice), 0, "nothing should remain claimable after");
    }

    function test_maxDeposit_maxMint_zeroWhenPausedOrGated() public {
        _fundJuniorViaJunior(bob, 1_000_000e6);
        assertGt(seniorVault.maxDeposit(alice), 0);
        assertGt(seniorVault.maxMint(alice), 0);

        vm.prank(curator);
        core.pause();
        assertEq(seniorVault.maxDeposit(alice), 0, "maxDeposit must be 0 while paused");
        assertEq(seniorVault.maxMint(alice), 0, "maxMint must be 0 while paused");

        vm.prank(governance);
        core.unpause();
        vm.mockCall(address(core), abi.encodeWithSelector(core.stressGateOpen.selector), abi.encode(false));
        assertEq(seniorVault.maxDeposit(alice), 0, "maxDeposit must be 0 while the stress gate is closed");
    }

    function test_maxRedeem_maxWithdraw_equalClaimableAmounts() public {
        _fundJuniorViaJunior(bob, 4_000_000e6);
        uint256 shares = _depositSenior(alice, 500_000e6);

        assertEq(seniorVault.maxRedeem(alice), 0, "nothing claimable before any request");

        vm.prank(alice);
        uint256 epochId = seniorVault.requestRedeem(shares, alice, alice);
        vm.prank(curator);
        seniorVault.closeEpoch();
        vm.prank(curator);
        seniorVault.fulfill(epochId, type(uint256).max);

        assertEq(seniorVault.maxRedeem(alice), seniorVault.claimableRedeemRequest(epochId, alice));
        assertGt(seniorVault.maxWithdraw(alice), 0);

        uint256 maxRedeemable = seniorVault.maxRedeem(alice);
        vm.prank(alice);
        seniorVault.redeem(maxRedeemable, alice, alice);
        assertEq(seniorVault.maxRedeem(alice), 0, "fully claimed request leaves nothing claimable");
    }

    function test_inflationAttack_donationDoesNotMovePricePerShare() public {
        _fundJuniorViaJunior(bob, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(seniorVault), 1);
        vm.prank(alice);
        seniorVault.deposit(1, alice);

        uint256 priceBefore = seniorVault.convertToAssets(1e18);

        usdc.mint(address(seniorVault), 1_000_000e6);
        usdc.mint(address(core), 1_000_000e6);

        uint256 priceAfter = seniorVault.convertToAssets(1e18);
        assertEq(priceAfter, priceBefore, "a raw donation must not move the price per share at all");
    }

    function testFuzz_convertRoundTrip_neverProfitable(uint256 assets) public view {
        assets = bound(assets, 1e6, 3_000_000e6);
        uint256 shares = seniorVault.convertToShares(assets);
        uint256 assetsBack = seniorVault.convertToAssets(shares);
        assertLe(assetsBack, assets, "a round trip through convertToShares/convertToAssets must never profit");
    }

    function test_previewDeposit_neverOverestimates_actualDeposit() public {
        _fundJuniorViaJunior(bob, 4_000_000e6);
        uint256 preview = seniorVault.previewDeposit(500_000e6);
        uint256 actual = _depositSenior(alice, 500_000e6);
        assertGe(actual, preview, "actual minted shares must never be fewer than the preview");
    }
}
