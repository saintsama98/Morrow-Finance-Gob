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

// Morrow Finance — unit tests for SeniorVault: deposits, redemption epochs, and pro-rata claims.
// @author adiii.eth

/// @notice Exercises SeniorVault against a real SeriesCore and IdleParking, with no series opened, so the
/// books behave as plain idle cash. Funds the junior book through the real JuniorVault first, since senior
/// capacity is always zero until junior capital backs it.
contract SeniorVaultTest is Test {
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
        core = new SeriesCore(address(usdc), factory, IParking(address(parking)), governance, allocator, curator, sentinel);
        vm.prank(governance);
        factory.setCore(address(core));

        seniorVault = new SeniorVault(core, address(usdc));
        juniorVault = new JuniorVault(core, address(usdc));
        vm.prank(governance);
        core.setVaults(address(seniorVault), address(juniorVault));

        usdc.mint(alice, 10_000_000e6);
        usdc.mint(bob, 10_000_000e6);
    }

    /// @dev Funds the junior book end to end through the real JuniorVault, so senior deposits have capacity.
    function _fundJunior(address who, uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(juniorVault), assets);
        uint256 epochId = juniorVault.requestDeposit(assets);
        vm.stopPrank();

        vm.prank(curator);
        juniorVault.closeDepositEpoch();
        vm.prank(curator);
        juniorVault.fulfillDeposit(epochId, assets);

        vm.prank(who);
        shares = juniorVault.claimDeposit(epochId);
    }

    // --- deposit -------------------------------------------------------------------------------------------

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
        _fundJunior(bob, 100_000e6); // seniorCapacity = 100_000e6 * 4 = 400_000e6

        vm.startPrank(alice);
        usdc.approve(address(seniorVault), 500_000e6);
        vm.expectRevert(SeniorVault.CapacityExceeded.selector);
        seniorVault.deposit(500_000e6, alice);
        vm.stopPrank();
    }

    function test_deposit_revertsWhenStressGateClosed() public {
        _fundJunior(bob, 1_000_000e6);
        vm.mockCall(address(core), abi.encodeWithSelector(SeriesCore.stressGateOpen.selector), abi.encode(false));

        vm.startPrank(alice);
        usdc.approve(address(seniorVault), 100e6);
        vm.expectRevert(SeniorVault.StressGateClosed.selector);
        seniorVault.deposit(100e6, alice);
        vm.stopPrank();
    }

    function test_deposit_revertsWhenPaused() public {
        _fundJunior(bob, 1_000_000e6);
        vm.prank(curator);
        core.pause();

        vm.startPrank(alice);
        usdc.approve(address(seniorVault), 100e6);
        vm.expectRevert(SeniorVault.DepositsPaused.selector);
        seniorVault.deposit(100e6, alice);
        vm.stopPrank();
    }

    // --- redeem ----------------------------------------------------------------------------------------------

    function test_requestRedeem_escrowsShares() public {
        _fundJunior(bob, 1_000_000e6);
        uint256 shares = _depositSenior(alice, 500_000e6);

        vm.prank(alice);
        uint256 epochId = seniorVault.requestRedeem(shares);

        assertEq(epochId, 1);
        assertEq(seniorVault.balanceOf(alice), 0, "shares must leave the redeemer's balance");
        assertEq(seniorVault.balanceOf(address(seniorVault)), shares, "shares must be escrowed in the vault");
        assertEq(seniorVault.requestedShares(epochId, alice), shares);
    }

    function test_closeEpoch_onlyOperator() public {
        vm.expectRevert(SeniorVault.NotOperator.selector);
        seniorVault.closeEpoch();
    }

    function test_fulfill_boundedByIdleAvailable() public {
        _fundJunior(bob, 1_000_000e6);
        uint256 shares = _depositSenior(alice, 400_000e6);

        vm.prank(alice);
        uint256 epochId = seniorVault.requestRedeem(shares);
        vm.prank(curator);
        seniorVault.closeEpoch();

        // minIdleSeniorWad floor (5%) keeps some of the 400_000e6 senior book un-fulfillable.
        uint256 available = core.idleAvailable(true);
        assertLt(available, 400_000e6, "idle floor must bound what's fulfillable");

        vm.prank(curator);
        seniorVault.fulfill(epochId, type(uint256).max);

        (uint256 totalRequested, uint256 sharesFulfilled, uint256 assetsFulfilled,,) = seniorVault.epochs(epochId);
        assertEq(totalRequested, shares);
        assertLt(sharesFulfilled, shares, "fulfillment must be partial, bounded by the idle floor");
        assertEq(assetsFulfilled, available);
    }

    /// @dev The idle floor recomputes against the shrinking senior book after each reservation (idleAvailable
    /// excludes already-reserved assets from the book it floors against), so a second round's cap is smaller
    /// than a naive "remaining request" figure would suggest. Assert against what the contract itself computes
    /// at each round, not a fixed number.
    function test_fulfill_multiRound_claimIsMonotonicAndBounded() public {
        _fundJunior(bob, 4_000_000e6);
        uint256 shares = _depositSenior(alice, 1_000_000e6);

        vm.prank(alice);
        uint256 epochId = seniorVault.requestRedeem(shares);
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
        uint256 epochId = seniorVault.requestRedeem(aliceShares);
        vm.prank(bob);
        seniorVault.requestRedeem(bobShares);
        vm.prank(curator);
        seniorVault.closeEpoch();

        vm.prank(curator);
        seniorVault.fulfill(epochId, type(uint256).max); // enough idle for both, minus the idle floor

        vm.prank(alice);
        uint256 aliceAssets = seniorVault.claim(epochId);
        vm.prank(bob);
        uint256 bobAssets = seniorVault.claim(epochId);

        // pro rata at par: alice requested 30%, bob 70%, of whatever got fulfilled.
        assertApproxEqAbs(aliceAssets * 7, bobAssets * 3, 10, "claims must split pro rata by request size");
    }

    function test_cancelRedeem_returnsUnfilledShares() public {
        _fundJunior(bob, 4_000_000e6);
        uint256 shares = _depositSenior(alice, 1_000_000e6);

        vm.prank(alice);
        uint256 epochId = seniorVault.requestRedeem(shares);
        vm.prank(curator);
        seniorVault.closeEpoch();

        vm.prank(curator);
        seniorVault.fulfill(epochId, 400_000e6);

        vm.prank(alice);
        uint256 returned = seniorVault.cancelRedeem(epochId);

        assertEq(seniorVault.balanceOf(alice), returned, "canceled shares must return to the caller");
        assertLt(returned, shares, "only the unfulfilled portion is returned");
    }

    function _depositSenior(address who, uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(seniorVault), assets);
        shares = seniorVault.deposit(assets, who);
        vm.stopPrank();
    }
}
