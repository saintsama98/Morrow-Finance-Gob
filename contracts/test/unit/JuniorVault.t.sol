// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {SeriesFactory} from "../../src/series/SeriesFactory.sol";
import {SeriesCore} from "../../src/core/SeriesCore.sol";
import {SeniorVault} from "../../src/vaults/SeniorVault.sol";
import {JuniorVault} from "../../src/vaults/JuniorVault.sol";
import {IMidnightMinimal} from "../../src/interfaces/IMidnightMinimal.sol";
import {IParking} from "../../src/parking/IParking.sol";
import {IdleParking} from "../../src/parking/IdleParking.sol";

// Morrow Finance — unit tests for JuniorVault: deposit and redemption epochs, and pro-rata claims.
// @author adiii.eth

/// @notice Exercises JuniorVault against a real SeriesCore and IdleParking, with no series opened, so the
/// books behave as plain idle cash and both queues can be driven end to end without any Midnight setup.
contract JuniorVaultTest is Test {
    MockUSDC usdc;
    IdleParking parking;
    SeriesFactory factory;
    SeriesCore core;
    SeniorVault seniorVault;
    JuniorVault juniorVault;

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

        seniorVault = new SeniorVault(core, address(usdc));
        juniorVault = new JuniorVault(core, address(usdc));
        vm.prank(governance);
        core.setVaults(address(seniorVault), address(juniorVault));

        usdc.mint(alice, 10_000_000e6);
        usdc.mint(bob, 10_000_000e6);
    }

    function _requestDeposit(address who, uint256 assets) internal returns (uint256 epochId) {
        vm.startPrank(who);
        usdc.approve(address(juniorVault), assets);
        epochId = juniorVault.requestDeposit(assets);
        vm.stopPrank();
    }

    // --- deposit ---------------------------------------------------------------------------------------------

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
        vm.expectRevert(JuniorVault.EpochNotClosed.selector);
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

    function test_cancelDeposit_refundsUnfilledPortion() public {
        uint256 epochId = _requestDeposit(alice, 1_000_000e6);
        vm.prank(curator);
        juniorVault.closeDepositEpoch();
        vm.prank(curator);
        juniorVault.fulfillDeposit(epochId, 400_000e6);

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 returned = juniorVault.cancelDeposit(epochId);

        assertEq(returned, 600_000e6, "only the uninvested portion is refundable");
        assertEq(usdc.balanceOf(alice), balanceBefore + returned);
    }

    // --- redeem ----------------------------------------------------------------------------------------------

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
        uint256 epochId = juniorVault.requestRedeem(shares);

        assertEq(juniorVault.balanceOf(alice), 0);
        assertEq(juniorVault.balanceOf(address(juniorVault)), shares);
        assertEq(juniorVault.requestedShares(epochId, alice), shares);
    }

    function test_fulfillRedeem_boundedByJuniorRedeemable() public {
        // senior book present too, so juniorRedeemable's coverage floor actually binds.
        uint256 shares = _fundJunior(alice, 1_000_000e6);
        vm.startPrank(bob);
        usdc.approve(address(seniorVault), 3_000_000e6);
        seniorVault.deposit(3_000_000e6, bob);
        vm.stopPrank();

        vm.prank(alice);
        uint256 epochId = juniorVault.requestRedeem(shares);
        vm.prank(curator);
        juniorVault.closeRedeemEpoch();

        uint256 available = core.juniorRedeemable();
        assertLt(available, 1_000_000e6, "coverage floor must bound redeemable junior assets");

        vm.prank(curator);
        juniorVault.fulfillRedeem(epochId, type(uint256).max);

        (uint256 totalRequested, uint256 sharesFulfilled, uint256 assetsFulfilled,,) = juniorVault.redeemEpochs(epochId);
        assertEq(totalRequested, shares);
        assertLt(sharesFulfilled, shares, "fulfillment must be partial, bounded by the coverage floor");
        assertEq(assetsFulfilled, available);
    }

    function test_claimRedeem_multiRound() public {
        uint256 shares = _fundJunior(alice, 1_000_000e6);

        vm.prank(alice);
        uint256 epochId = juniorVault.requestRedeem(shares);
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

    function test_cancelRedeem_returnsUnfilledShares() public {
        uint256 shares = _fundJunior(alice, 1_000_000e6);

        vm.prank(alice);
        uint256 epochId = juniorVault.requestRedeem(shares);
        vm.prank(curator);
        juniorVault.closeRedeemEpoch();
        vm.prank(curator);
        juniorVault.fulfillRedeem(epochId, 100_000e6);

        vm.prank(alice);
        uint256 returned = juniorVault.cancelRedeem(epochId);

        assertEq(juniorVault.balanceOf(alice), returned);
        assertLt(returned, shares);
    }
}
