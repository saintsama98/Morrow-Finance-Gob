// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: what the core does when its parking venue lies, short-pays or re-enters.
// The parking adapter is a trusted, immutable dependency; these tests record the failure modes.
// @author adiii.eth

pragma solidity 0.8.34;

import {console} from "forge-std/console.sol";
import {ScenarioBase} from "../scenario/ScenarioBase.t.sol";
import {SeriesRegistry} from "../invariant/handlers/SeriesRegistry.sol";
import {IParking} from "../../src/parking/IParking.sol";
import {AdversarialParking} from "../mocks/AdversarialParking.sol";
import {CoreStorage} from "../../src/core/modules/CoreStorage.sol";

contract SeriesRegistryAdversarialParking is SeriesRegistry {
    function _deployParking() internal override returns (IParking) {
        return new AdversarialParking(address(usdc));
    }
}

contract AdversarialParkingTest is ScenarioBase {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    AdversarialParking venue;

    function setUp() public override {
        registry = new SeriesRegistryAdversarialParking();
        core = registry.realCore();
        seniorVault = registry.seniorVault();
        juniorVault = registry.juniorVault();
        usdc = registry.usdc();
        venue = AdversarialParking(address(registry.parking()));
        _juniorDeposit(makeAddr("juniorSeed"), 1_000_000e6);
    }

    function _exit(address who, uint256 shares) internal returns (bool ok, uint256 paid) {
        vm.prank(who);
        uint256 id = seniorVault.requestRedeem(shares, who, who);
        vm.startPrank(registry.CURATOR());
        seniorVault.closeEpoch();
        (ok,) = address(seniorVault).call(abi.encodeWithSignature("fulfill(uint256,uint256)", id, type(uint128).max));
        vm.stopPrank();
        if (!ok) return (false, 0);
        uint256 claim = seniorVault.claimableRedeemRequest(id, who);
        vm.prank(who);
        (bool r, bytes memory ret) =
            address(seniorVault).call(abi.encodeWithSignature("redeem(uint256,address,address)", claim, who, who));
        if (!r) return (false, 0);
        paid = abi.decode(ret, (uint256));
        ok = true;
    }

    function test_lyingVenue_inflatesBooks_lastExiterShort() public {
        uint256 sA = _seniorDeposit(alice, 500_000e6);
        uint256 sB = _seniorDeposit(bob, 500_000e6);
        uint256 honestBook = core.seniorAssets();
        venue.setMode(AdversarialParking.Mode.Lying);
        uint256 lyingBook = core.seniorAssets();
        (bool okA, uint256 paidA) = _exit(alice, sA);
        (bool okB, uint256 paidB) = _exit(bob, sB);
        console.log("senior book honest / as reported by a venue over-stating 10%:", honestBook / 1e6, lyingBook / 1e6);
        console.log("first exiter ok / paid:", okA, paidA / 1e6);
        console.log("second exiter ok / paid:", okB, paidB / 1e6);
        assertGt(lyingBook, honestBook, "the core trusts the venue's reported assets");
    }

    function test_shortPayingVenue_exitFillReverts_booksUntouched() public {
        uint256 sA = _seniorDeposit(alice, 500_000e6);
        _seniorDeposit(bob, 500_000e6);
        venue.setMode(AdversarialParking.Mode.ShortPay);
        vm.prank(alice);
        uint256 id = seniorVault.requestRedeem(sA, alice, alice);
        uint256 bookBefore = core.seniorAssets();
        vm.startPrank(registry.CURATOR());
        seniorVault.closeEpoch();
        vm.expectRevert(abi.encodeWithSelector(CoreStorage.ParkingShortPaid.selector, 500_000e6, 450_000e6));
        seniorVault.fulfill(id, type(uint128).max);
        vm.stopPrank();
        (, uint256 reserved,) = core.senior();
        assertEq(reserved, 0, "a short-paid fill must not reserve anything");
        assertEq(usdc.balanceOf(address(core)), 0, "no stray cash on the core");
        assertEq(core.seniorAssets(), bookBefore, "books unchanged by a reverted fill");

        venue.setMode(AdversarialParking.Mode.Honest);
        vm.prank(registry.CURATOR());
        seniorVault.fulfill(id, type(uint128).max);
        uint256 claim = seniorVault.claimableRedeemRequest(id, alice);
        vm.prank(alice);
        uint256 paid = seniorVault.redeem(claim, alice, alice);
        assertEq(paid, 500_000e6, "once the venue pays in full the exit completes");
    }

    function test_reentrantVenue_callbacksLeaveBooksConsistent() public {
        uint256 sA = _seniorDeposit(alice, 500_000e6);
        _seniorDeposit(bob, 500_000e6);
        venue.setReentryTarget(address(core));
        venue.setMode(AdversarialParking.Mode.Reentrant);
        (bool ok, uint256 paid) = _exit(alice, sA);
        (, uint256 reserved,) = core.senior();
        console.log("venue re-entered the core during withdraw (times):", venue.reentries());
        console.log("exit ok / paid / reserved left:", ok, paid / 1e6, reserved);
        assertTrue(ok, "permissionless callbacks during withdraw do not break the exit");
        assertEq(usdc.balanceOf(address(core)), reserved, "core cash still equals reserved after re-entry");
    }
}
