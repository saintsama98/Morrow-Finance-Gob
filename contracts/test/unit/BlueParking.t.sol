// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: unit tests for blueParking: pooled shares over one Morpho Blue market, buffer, liquidity, access and exit.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {MarketParams} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {blueParking} from "../../src/parking/blueParking.sol";
import {MockMorphoBlue, MockBlueIrm} from "../mocks/MockMorphoBlue.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

contract BlueParkingFactoryStub {
    address public core;
    address public immutable USDC;
    uint256 public maxLltvWad = 0.86e18;
    mapping(address => bool) public collateralAllowed;
    mapping(address => mapping(address => bool)) public oracleAllowed;

    constructor(address usdc) {
        USDC = usdc;
    }

    function setCore(address core_) external {
        core = core_;
    }

    function allow(address token, address oracle) external {
        collateralAllowed[token] = true;
        oracleAllowed[token][oracle] = true;
    }
}

contract BlueParkingCoreStub {
    address public curator = address(0xC0);
    address public sentinel = address(0x5E);
    mapping(address => bool) public registered;

    function register(address a) external {
        registered[a] = true;
    }

    function info(address a) external view returns (uint256, uint256, uint256, bool) {
        return (0, 0, 0, registered[a]);
    }
}

contract BlueParkingUser {
    MockUSDC immutable usdc;
    blueParking immutable parking;

    constructor(MockUSDC usdc_, blueParking parking_) {
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

contract BlueParkingTest is Test {
    uint256 constant BUFFER_WAD = 0.05e18;

    MockUSDC usdc;
    MockMorphoBlue blue;
    MockBlueIrm irm;
    BlueParkingFactoryStub factory;
    BlueParkingCoreStub core;
    blueParking parking;
    MarketParams params;
    BlueParkingUser alice;
    BlueParkingUser bob;
    address collateral = address(0xC011);
    address oracle = address(0x0AC1E);

    function setUp() public {
        usdc = new MockUSDC();
        blue = new MockMorphoBlue(usdc);
        irm = new MockBlueIrm();
        factory = new BlueParkingFactoryStub(address(usdc));
        core = new BlueParkingCoreStub();
        factory.setCore(address(core));
        factory.allow(collateral, oracle);
        params = MarketParams({
            loanToken: address(usdc), collateralToken: collateral, oracle: oracle, irm: address(irm), lltv: 0.86e18
        });
        blue.createMarket(params);
        parking = new blueParking(address(usdc), address(blue), address(factory), params, BUFFER_WAD);
        alice = new BlueParkingUser(usdc, parking);
        bob = new BlueParkingUser(usdc, parking);
        core.register(address(alice));
        core.register(address(bob));
        usdc.mint(address(alice), 100_000_000e6);
        usdc.mint(address(bob), 100_000_000e6);
    }

    function _buffer() internal view returns (uint256) {
        return usdc.balanceOf(address(parking));
    }

    function _outsideBorrow(uint256 assets) internal {
        usdc.mint(address(this), assets * 2);
        usdc.approve(address(blue), assets * 2);
        blue.supply(params, assets * 2, 0, address(this), "");
        blue.borrow(params, assets);
    }

    function test_constructor_rejectsWrongLoanToken() public {
        MarketParams memory p = params;
        p.loanToken = address(new MockUSDC());
        vm.expectRevert(blueParking.AssetMismatch.selector);
        new blueParking(address(usdc), address(blue), address(factory), p, BUFFER_WAD);
    }

    function test_constructor_rejectsBufferAboveOne() public {
        vm.expectRevert(blueParking.InvalidBuffer.selector);
        new blueParking(address(usdc), address(blue), address(factory), params, 1e18 + 1);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(blueParking.ZeroAddress.selector);
        new blueParking(address(usdc), address(0), address(factory), params, BUFFER_WAD);
    }

    function test_constructor_rejectsMarketsTheFactoryWouldNotAllow() public {
        MarketParams memory p = params;
        p.oracle = address(0xBAD);
        vm.expectRevert(blueParking.MarketNotEligible.selector);
        new blueParking(address(usdc), address(blue), address(factory), p, BUFFER_WAD);
        p = params;
        p.lltv = 0.915e18;
        vm.expectRevert(blueParking.MarketNotEligible.selector);
        new blueParking(address(usdc), address(blue), address(factory), p, BUFFER_WAD);
    }

    function test_constructor_rejectsAMarketNotCreatedOnBlue() public {
        MarketParams memory p = params;
        p.lltv = 0.77e18;
        vm.expectRevert(blueParking.MarketNotCreated.selector);
        new blueParking(address(usdc), address(blue), address(factory), p, BUFFER_WAD);
    }

    function test_deposit_isExactAtUnitPrice_andSplitsIntoBufferAndBlue() public {
        alice.deposit(1_000_000e6);
        assertEq(parking.totalAssets(address(alice)), 1_000_000e6);
        assertEq(_buffer(), 50_000e6, "5% stays as raw USDC");
        assertEq(parking.blueAssets(), 950_000e6, "the rest is supplied to Blue");
        assertGt(parking.blueShares(), 0);
    }

    function test_withdraw_roundTripsExactly_withNoYield() public {
        alice.deposit(1_000_000e6);
        uint256 before = usdc.balanceOf(address(alice));
        alice.withdraw(1_000_000e6, address(alice));
        assertEq(usdc.balanceOf(address(alice)) - before, 1_000_000e6);
        assertEq(parking.totalAssets(address(alice)), 0);
    }

    function test_smallWithdraw_paysFromBufferWithoutTouchingBlue() public {
        alice.deposit(1_000_000e6);
        uint256 shares = parking.blueShares();
        alice.withdraw(20_000e6, address(alice));
        assertEq(parking.blueShares(), shares, "no Blue call for a fill the buffer covers");
    }

    function test_largeWithdraw_pullsTheShortfallFromBlue() public {
        alice.deposit(1_000_000e6);
        alice.withdraw(600_000e6, address(alice));
        assertApproxEqAbs(parking.totalAssets(address(alice)), 400_000e6, 1);
        assertApproxEqAbs(parking.poolAssets(), 400_000e6, 1);
    }

    function test_fullExit_paysEverythingOwned_leavingOnlyVirtualShareDust() public {
        alice.deposit(1_000_000e6);
        irm.setRate(uint256(0.05e18) / 365 days);
        _outsideBorrow(10_000_000e6);
        vm.warp(block.timestamp + 37 days);
        uint256 owed = parking.totalAssets(address(alice));
        assertGt(owed, 1_000_000e6, "earned Blue interest");
        uint256 before = usdc.balanceOf(address(alice));
        alice.withdraw(owed, address(alice));
        assertEq(usdc.balanceOf(address(alice)) - before, owed, "the last depositor is paid everything it owns");
        assertEq(parking.totalAssets(address(alice)), 0);
        assertLe(parking.poolAssets(), 2, "only the virtual shares' dust stays behind");
    }

    function test_withdraw_moreThanOwned_reverts() public {
        alice.deposit(1_000e6);
        vm.expectRevert(blueParking.InsufficientBalance.selector);
        alice.withdraw(1_000e6 + 101, address(alice));
    }

    function test_zeroAmounts_areNoOps() public {
        alice.deposit(0);
        alice.withdraw(0, address(alice));
        alice.transfer(address(bob), 0);
        assertEq(parking.totalShares(), 0);
    }

    function test_yield_reachesEveryAccountProRata() public {
        alice.deposit(1_000_000e6);
        bob.deposit(3_000_000e6);
        irm.setRate(uint256(0.08e18) / 365 days);
        _outsideBorrow(20_000_000e6);
        vm.warp(block.timestamp + 90 days);
        uint256 a = parking.totalAssets(address(alice));
        uint256 b = parking.totalAssets(address(bob));
        assertGt(a, 1_000_000e6);
        assertApproxEqRel(b - 3_000_000e6, 3 * (a - 1_000_000e6), 1e12);
    }

    function test_blueBadDebt_reachesEveryAccountProRata_immediately() public {
        alice.deposit(1_000_000e6);
        bob.deposit(1_000_000e6);
        _outsideBorrow(5_000_000e6);
        uint256 before = parking.totalAssets(address(alice));
        blue.realizeBadDebt(params, 1_000_000e6);
        uint256 afterLoss = parking.totalAssets(address(alice));
        assertLt(afterLoss, before, "Blue bad debt lowers adapter value at once");
        assertEq(afterLoss, parking.totalAssets(address(bob)), "and hits both accounts equally");
    }

    function test_lateDepositor_doesNotShareEarlierYield() public {
        alice.deposit(1_000_000e6);
        irm.setRate(uint256(0.08e18) / 365 days);
        _outsideBorrow(20_000_000e6);
        vm.warp(block.timestamp + 90 days);
        bob.deposit(1_000_000e6);
        assertApproxEqAbs(parking.totalAssets(address(bob)), 1_000_000e6, 1);
    }

    function test_donatedBlueShares_areIgnored() public {
        alice.deposit(1_000_000e6);
        uint256 before = parking.totalAssets(address(alice));
        usdc.mint(address(this), 500_000e6);
        usdc.approve(address(blue), 500_000e6);
        blue.supply(params, 500_000e6, 0, address(parking), "");
        assertEq(parking.totalAssets(address(alice)), before, "shares supplied on the adapter's behalf do not count");
    }

    function test_crunch_withdrawBeyondBufferReverts_butBufferStillPays() public {
        alice.deposit(1_000_000e6);
        blue.borrow(params, 950_000e6);
        assertEq(parking.blueLiquidity(), 0);
        assertEq(parking.maxWithdraw(address(alice)), 50_000e6, "only the raw buffer is liquid");
        alice.withdraw(50_000e6, address(alice));
        vm.expectRevert(abi.encodeWithSelector(blueParking.Illiquid.selector, 10_000e6, 0));
        alice.withdraw(10_000e6, address(alice));
    }

    function test_crunchEnds_withdrawalsResume() public {
        alice.deposit(1_000_000e6);
        blue.borrow(params, 950_000e6);
        blue.repay(params, 950_000e6);
        alice.withdraw(900_000e6, address(alice));
        assertApproxEqAbs(parking.totalAssets(address(alice)), 100_000e6, 1);
    }

    function test_transfer_movesValueWithoutLiquidity() public {
        alice.deposit(1_000_000e6);
        blue.borrow(params, 950_000e6);
        uint256 a = parking.totalAssets(address(alice));
        vm.prank(address(alice));
        parking.transferPosition(address(core), 400_000e6);
        assertApproxEqAbs(parking.totalAssets(address(core)), 400_000e6, 1);
        assertApproxEqAbs(parking.totalAssets(address(alice)), a - 400_000e6, 1);
    }

    function test_registeredSeries_canOnlyTransferToTheCore() public {
        alice.deposit(1_000_000e6);
        vm.expectRevert(blueParking.NotAuthorized.selector);
        alice.transfer(address(bob), 1e6);
    }

    function test_core_canTransferToAnyAddress() public {
        usdc.mint(address(core), 1_000_000e6);
        vm.startPrank(address(core));
        usdc.approve(address(parking), 1_000_000e6);
        parking.deposit(1_000_000e6);
        parking.transferPosition(address(0xFEED), 300_000e6);
        vm.stopPrank();
        assertApproxEqAbs(parking.totalAssets(address(0xFEED)), 300_000e6, 1);
    }

    function test_strangers_cannotDepositWithdrawOrTransfer() public {
        alice.deposit(1_000_000e6);
        BlueParkingUser stranger = new BlueParkingUser(usdc, parking);
        usdc.mint(address(stranger), 1e6);
        vm.expectRevert(blueParking.NotAuthorized.selector);
        stranger.deposit(1e6);
        uint256 dust = parking.DUST_ASSETS();
        vm.expectRevert(blueParking.NotAuthorized.selector);
        stranger.withdraw(dust, address(stranger));
        vm.expectRevert(blueParking.NotAuthorized.selector);
        stranger.transfer(address(core), 1);
    }

    function test_registeredAccountWithNoShares_cannotWithdrawDust() public {
        alice.deposit(1_000_000e6);
        uint256 dust = parking.DUST_ASSETS();
        vm.expectRevert(blueParking.InsufficientBalance.selector);
        bob.withdraw(dust, address(bob));
    }

    function test_exitToCash_onlySentinelOrCurator_isOneWay_andPullsWhatIsLiquid() public {
        alice.deposit(1_000_000e6);
        vm.expectRevert(blueParking.NotAuthorized.selector);
        parking.exitToCash();

        vm.prank(core.sentinel());
        parking.exitToCash();
        assertTrue(parking.exited());
        assertEq(parking.blueShares(), 0, "everything liquid comes back as raw USDC");
        assertEq(_buffer(), 1_000_000e6);

        bob.deposit(500_000e6);
        assertEq(parking.blueShares(), 0, "after exit nothing is supplied again");
        parking.rebalance();
        assertEq(parking.blueShares(), 0);
        assertEq(parking.totalAssets(address(bob)), 500_000e6);
    }

    function test_exitToCash_inACrunch_pullsPartially_andCanBeCalledAgain() public {
        alice.deposit(1_000_000e6);
        blue.borrow(params, 900_000e6);
        vm.prank(core.curator());
        parking.exitToCash();
        assertGt(parking.blueShares(), 0, "illiquid remainder stays in Blue");
        blue.repay(params, 900_000e6);
        vm.prank(core.curator());
        parking.exitToCash();
        assertEq(parking.blueShares(), 0);
        assertEq(_buffer(), 1_000_000e6);
    }

    function test_rebalance_isPermissionless_andRestoresTheTarget() public {
        alice.deposit(1_000_000e6);
        alice.withdraw(40_000e6, address(alice));
        parking.rebalance();
        assertApproxEqAbs(_buffer(), parking.poolAssets() * 5 / 100, 1);
    }

    function testFuzz_ledgerSolvency(uint96 a, uint96 b, uint16 rateBps, uint32 dt, uint96 bad) public {
        uint256 da = bound(a, 1e6, 50_000_000e6);
        uint256 db = bound(b, 1e6, 50_000_000e6);
        alice.deposit(da);
        bob.deposit(db);
        irm.setRate(uint256(bound(rateBps, 0, 2_000)) * 1e14 / 365 days);
        _outsideBorrow(10_000_000e6);
        vm.warp(block.timestamp + bound(dt, 0, 400 days));
        blue.realizeBadDebt(params, bound(bad, 0, 1_000_000e6));
        uint256 owed = parking.totalAssets(address(alice)) + parking.totalAssets(address(bob));
        assertLe(owed, parking.poolAssets(), "accounts never claim more than the pool holds");
    }

    function testFuzz_roundTrip_neverProfitsWithoutYield(uint96 a, uint96 b) public {
        uint256 da = bound(a, 1, 50_000_000e6);
        uint256 db = bound(b, 1e6, 50_000_000e6);
        bob.deposit(db);
        uint256 before = usdc.balanceOf(address(alice));
        alice.deposit(da);
        uint256 out = parking.totalAssets(address(alice));
        if (out > 0) alice.withdraw(out, address(alice));
        assertLe(usdc.balanceOf(address(alice)), before, "a round trip never creates value");
    }
}
