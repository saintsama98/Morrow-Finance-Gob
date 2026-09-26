// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: unit and fuzz tests for the Morpho-backed parking adapter.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {morphoParking} from "../../src/parking/morphoParking.sol";
import {MockMorphoVault} from "../mocks/MockMorphoVault.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

contract ParkingUser {
    MockUSDC immutable usdc;
    morphoParking immutable parking;

    constructor(MockUSDC usdc_, morphoParking parking_) {
        usdc = usdc_;
        parking = parking_;
    }

    function deposit(uint256 assets) external {
        usdc.approve(address(parking), assets);
        parking.deposit(assets);
    }

    function withdraw(uint256 assets, address to) external {
        parking.withdraw(assets, to);
    }

    function transfer(address to, uint256 assets) external {
        parking.transferPosition(to, assets);
    }
}

contract MorphoParkingTest is Test {
    MockUSDC usdc;
    MockMorphoVault vault;
    morphoParking parking;
    ParkingUser alice;
    ParkingUser bob;

    uint256 constant BUFFER_WAD = 0.1e18;

    function setUp() public {
        usdc = new MockUSDC();
        vault = new MockMorphoVault(usdc);
        parking = new morphoParking(address(usdc), address(vault), BUFFER_WAD);
        alice = new ParkingUser(usdc, parking);
        bob = new ParkingUser(usdc, parking);
        usdc.mint(address(alice), 100_000_000e6);
        usdc.mint(address(bob), 100_000_000e6);
    }

    function _buffer() internal view returns (uint256) {
        return usdc.balanceOf(address(parking));
    }

    function _vaultAssets() internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(address(parking)));
    }

    function test_constructor_rejectsWrongAsset() public {
        MockUSDC other = new MockUSDC();
        vm.expectRevert(morphoParking.AssetMismatch.selector);
        new morphoParking(address(other), address(vault), BUFFER_WAD);
    }

    function test_constructor_rejectsBufferAboveOne() public {
        vm.expectRevert(morphoParking.InvalidBuffer.selector);
        new morphoParking(address(usdc), address(vault), 1e18 + 1);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(morphoParking.ZeroAddress.selector);
        new morphoParking(address(0), address(vault), BUFFER_WAD);
    }

    function test_deposit_isExactAtUnitPrice_andSplitsIntoBufferAndVault() public {
        alice.deposit(1_000_000e6);
        assertEq(parking.totalAssets(address(alice)), 1_000_000e6, "a fresh deposit is valued exactly");
        assertEq(_buffer(), 100_000e6, "10% stays as the USDC buffer");
        assertEq(_vaultAssets(), 900_000e6, "the rest earns in the vault");
        assertEq(parking.poolAssets(), 1_000_000e6);
    }

    function test_withdraw_roundTripsExactly_withNoYield() public {
        alice.deposit(1_000_000e6);
        uint256 before = usdc.balanceOf(address(this));
        alice.withdraw(1_000_000e6, address(this));
        assertEq(usdc.balanceOf(address(this)) - before, 1_000_000e6);
        assertEq(parking.totalAssets(address(alice)), 0);
        assertEq(parking.totalShares(), 0);
    }

    function test_smallWithdraw_paysFromBufferWithoutTouchingTheVault() public {
        alice.deposit(1_000_000e6);
        uint256 vaultBefore = vault.balanceOf(address(parking));
        alice.withdraw(40_000e6, address(this));
        assertEq(vault.balanceOf(address(parking)), vaultBefore, "the vault position is untouched");
        assertEq(_buffer(), 60_000e6);
    }

    function test_bufferRefills_onceItFallsBelowHalfItsTarget() public {
        alice.deposit(1_000_000e6);
        alice.withdraw(60_000e6, address(this));
        uint256 target = parking.poolAssets() * BUFFER_WAD / 1e18;
        assertApproxEqAbs(_buffer(), target, 1, "the buffer is topped back up to its target");
    }

    function test_largeWithdraw_pullsTheShortfallFromTheVault() public {
        alice.deposit(1_000_000e6);
        alice.withdraw(500_000e6, address(this));
        assertEq(parking.totalAssets(address(alice)), 500_000e6);
        assertEq(usdc.balanceOf(address(this)), 500_000e6);
    }

    function test_withdraw_moreThanOwned_reverts() public {
        alice.deposit(1_000e6);
        vm.expectRevert(morphoParking.InsufficientBalance.selector);
        alice.withdraw(2_000e6, address(this));
    }

    function test_zeroAmounts_areNoOps() public {
        alice.deposit(0);
        alice.withdraw(0, address(this));
        alice.transfer(address(bob), 0);
        assertEq(parking.totalShares(), 0);
    }

    function test_yield_reachesEveryAccountProRata() public {
        alice.deposit(750_000e6);
        bob.deposit(250_000e6);
        vault.accrueBps(400);

        assertApproxEqAbs(parking.totalAssets(address(alice)), 750_000e6 + 27_000e6, 2);
        assertApproxEqAbs(parking.totalAssets(address(bob)), 250_000e6 + 9_000e6, 2);
    }

    function test_loss_reachesEveryAccountProRata() public {
        alice.deposit(750_000e6);
        bob.deposit(250_000e6);
        vault.loseBps(200);

        assertApproxEqAbs(parking.totalAssets(address(alice)), 750_000e6 - 13_500e6, 2);
        assertApproxEqAbs(parking.totalAssets(address(bob)), 250_000e6 - 4_500e6, 2);
    }

    function test_lateDepositor_doesNotShareEarlierYield() public {
        alice.deposit(1_000_000e6);
        vault.accrueBps(1_000);
        bob.deposit(1_000_000e6);
        assertApproxEqAbs(parking.totalAssets(address(bob)), 1_000_000e6, 2, "bob buys in at the current price");
        assertApproxEqAbs(parking.totalAssets(address(alice)), 1_090_000e6, 2);
    }

    function test_transfer_movesValue_withoutAnyLiquidity() public {
        alice.deposit(1_000_000e6);
        vault.setLiquidityCap(0);
        alice.transfer(address(bob), 600_000e6);
        assertGe(parking.totalAssets(address(bob)), 600_000e6, "the receiver is credited at least the amount");
        assertApproxEqAbs(parking.totalAssets(address(alice)), 400_000e6, 1);
    }

    function test_withdraw_inACrunch_revertsIlliquid_butBufferStillPays() public {
        alice.deposit(1_000_000e6);
        vault.setLiquidityCap(0);
        assertEq(parking.maxWithdraw(address(alice)), 100_000e6, "only the buffer is liquid");

        alice.withdraw(100_000e6, address(this));

        vm.expectRevert(abi.encodeWithSelector(morphoParking.Illiquid.selector, 1e6, 0));
        alice.withdraw(1e6, address(this));
    }

    function test_crunchEnds_withdrawalsResume() public {
        alice.deposit(1_000_000e6);
        vault.setLiquidityCap(0);
        vm.expectRevert();
        alice.withdraw(500_000e6, address(this));

        vault.setLiquidityCap(type(uint256).max);
        alice.withdraw(500_000e6, address(this));
        assertEq(usdc.balanceOf(address(this)), 500_000e6);
    }

    function test_depositCap_keepsTheExcessInTheBuffer() public {
        vault.setDepositCap(100_000e6);
        alice.deposit(1_000_000e6);
        assertEq(_vaultAssets(), 100_000e6, "the vault took only what it accepts");
        assertEq(_buffer(), 900_000e6);
        assertEq(parking.totalAssets(address(alice)), 1_000_000e6);
    }

    function test_rebalance_isPermissionless_andRestoresTheTarget() public {
        alice.deposit(1_000_000e6);
        alice.withdraw(50_000e6, address(this));
        assertEq(_buffer(), 50_000e6);
        vm.prank(makeAddr("anyone"));
        parking.rebalance();
        assertApproxEqAbs(_buffer(), parking.poolAssets() / 10, 1);
    }

    function test_dustShortfall_burnsTheWholeBalance_insteadOfReverting() public {
        alice.deposit(1_000_000e6);
        vault.loseBps(1);
        uint256 owned = parking.totalAssets(address(alice));
        assertLt(owned, 1_000_000e6);
        uint256 short = 1_000_000e6 - owned;
        if (short <= parking.DUST_ASSETS()) {
            alice.withdraw(1_000_000e6, address(this));
            assertEq(parking.sharesOf(address(alice)), 0);
        } else {
            vm.expectRevert(morphoParking.InsufficientBalance.selector);
            alice.withdraw(1_000_000e6, address(this));
        }
    }

    function test_dustTolerance_isBounded() public {
        bob.deposit(1_000_000e6);
        alice.deposit(1_000e6);
        uint256 dust = parking.DUST_ASSETS();
        vm.expectRevert(morphoParking.InsufficientBalance.selector);
        alice.withdraw(1_000e6 + dust + 1, address(this));
        alice.withdraw(1_000e6 + dust, address(this));
        assertEq(parking.sharesOf(address(alice)), 0);
    }

    function test_donationBeforeFirstDeposit_cannotStealFromTheNextDepositor() public {
        address attacker = makeAddr("attacker");
        ParkingUser attackerUser = new ParkingUser(usdc, parking);
        usdc.mint(address(attackerUser), 1);
        attackerUser.deposit(1);
        usdc.mint(attacker, 1_000_000e6);
        vm.prank(attacker);
        usdc.transfer(address(parking), 1_000_000e6);

        alice.deposit(1_000_000e6);
        assertGe(parking.totalAssets(address(alice)), 1_000_000e6 - 1, "the victim keeps its deposit");
        assertLt(parking.totalAssets(address(attackerUser)), 1_000_000e6, "the attacker loses on the donation");
    }

    function testFuzz_ledgerSolvency(uint96 a, uint96 b, uint16 yieldBps, uint16 lossBps, uint96 moved) public {
        uint256 da = bound(a, 1e6, 50_000_000e6);
        uint256 db = bound(b, 1e6, 50_000_000e6);
        alice.deposit(da);
        bob.deposit(db);
        vault.accrueBps(bound(yieldBps, 0, 2_000));
        vault.loseBps(bound(lossBps, 0, 2_000));
        uint256 m = bound(moved, 0, parking.totalAssets(address(alice)));
        alice.transfer(address(bob), m);

        assertEq(parking.sharesOf(address(alice)) + parking.sharesOf(address(bob)), parking.totalShares());
        assertLe(
            parking.totalAssets(address(alice)) + parking.totalAssets(address(bob)),
            parking.poolAssets(),
            "accounts can never claim more than the pool holds"
        );
    }

    function testFuzz_roundTrip_neverProfitsWithoutYield(uint96 a, uint96 b) public {
        uint256 da = bound(a, 1e6, 50_000_000e6);
        uint256 db = bound(b, 1e6, 50_000_000e6);
        bob.deposit(db);
        uint256 before = usdc.balanceOf(address(this));
        alice.deposit(da);
        uint256 owned = parking.totalAssets(address(alice));
        assertLe(owned, da, "no value is created by depositing");
        alice.withdraw(owned, address(this));
        assertLe(usdc.balanceOf(address(this)) - before, da);
        assertGe(parking.totalAssets(address(bob)) + 2, db, "the other account is not diluted beyond rounding");
    }
}
