// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: a cancel in a batch never strands or dilutes the requests that stay in it.
// @author adiii.eth

pragma solidity 0.8.34;

import {ScenarioBase} from "../scenario/ScenarioBase.t.sol";

contract EpochCancelAccountingTest is ScenarioBase {
    address juniorSeed = makeAddr("juniorSeed");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function _fundJuniorShares(address who, uint256 assets) internal returns (uint256) {
        return _juniorDeposit(who, assets);
    }

    function test_seniorExit_cancelWhileOpen_othersFillInFull_nothingStranded() public {
        _juniorDeposit(juniorSeed, 1_000_000e6);
        uint256 sharesA = _seniorDeposit(alice, 100_000e6);
        uint256 sharesB = _seniorDeposit(bob, 100_000e6);

        vm.prank(alice);
        uint256 id = seniorVault.requestRedeem(sharesA, alice, alice);
        vm.prank(bob);
        seniorVault.requestRedeem(sharesB, bob, bob);

        vm.prank(alice);
        seniorVault.cancelRedeemRequest(id, alice);

        address curator = registry.CURATOR();
        vm.prank(curator);
        seniorVault.closeEpoch();
        vm.prank(curator);
        seniorVault.fulfill(id, type(uint128).max);

        assertEq(seniorVault.pendingRedeemRequest(id, bob), 0, "bob's request must be completely filled");
        assertEq(seniorVault.claimableRedeemRequest(id, bob), sharesB, "bob can claim everything he asked for");

        vm.prank(bob);
        uint256 paid = seniorVault.redeem(sharesB, bob, bob);
        assertApproxEqAbs(paid, 100_000e6, 2, "bob is paid in full");
        assertEq(seniorVault.activeRedeemRequestId(bob), 0, "bob's request slot frees up");
        (, uint256 reserved,) = core.senior();
        assertLe(reserved, 2, "no cash is left stranded in the reserve");
    }

    function test_juniorEntry_cancelWhileOpen_othersFillInFull_nothingStranded() public {
        _juniorDeposit(juniorSeed, 1_000_000e6);
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(juniorVault), 100_000e6);
        uint256 id = juniorVault.requestDeposit(100_000e6, alice, alice);
        vm.stopPrank();
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), 100_000e6);
        juniorVault.requestDeposit(100_000e6, bob, bob);
        vm.stopPrank();

        vm.prank(alice);
        juniorVault.cancelDepositRequest(id, alice);

        address curator = registry.CURATOR();
        vm.prank(curator);
        juniorVault.closeDepositEpoch();
        vm.prank(curator);
        juniorVault.fulfillDeposit(id, type(uint128).max);

        assertEq(juniorVault.pendingDepositRequest(id, bob), 0, "bob's entry must be completely filled");
        assertEq(juniorVault.claimableDepositRequest(id, bob), 100_000e6, "bob can claim everything he paid in");

        vm.prank(bob);
        juniorVault.claimDeposit(id);
        assertEq(juniorVault.activeDepositRequestId(bob), 0, "bob's request slot frees up");
        assertEq(juniorVault.balanceOf(address(juniorVault)), 0, "no minted shares are left stranded in the vault");
    }

    function test_juniorExit_cancelWhileOpen_othersFillInFull_nothingStranded() public {
        _juniorDeposit(juniorSeed, 2_000_000e6);
        uint256 sharesA = _fundJuniorShares(alice, 100_000e6);
        uint256 sharesB = _fundJuniorShares(bob, 100_000e6);

        vm.prank(alice);
        uint256 id = juniorVault.requestRedeem(sharesA, alice, alice);
        vm.prank(bob);
        juniorVault.requestRedeem(sharesB, bob, bob);

        vm.prank(alice);
        juniorVault.cancelRedeemRequest(id, alice);

        address curator = registry.CURATOR();
        vm.prank(curator);
        juniorVault.closeRedeemEpoch();
        vm.prank(curator);
        juniorVault.fulfillRedeem(id, type(uint128).max);

        assertEq(juniorVault.pendingRedeemRequest(id, bob), 0, "bob's exit must be completely filled");
        assertEq(juniorVault.claimableRedeemRequest(id, bob), sharesB, "bob can claim everything he asked for");

        vm.prank(bob);
        uint256 paid = juniorVault.redeem(sharesB, bob, bob);
        assertApproxEqAbs(paid, 100_000e6, 2, "bob is paid in full");
        assertEq(juniorVault.activeRedeemRequestId(bob), 0, "bob's request slot frees up");
        (, uint256 reserved,) = core.junior();
        assertLe(reserved, 2, "no cash is left stranded in the reserve");
    }
}
