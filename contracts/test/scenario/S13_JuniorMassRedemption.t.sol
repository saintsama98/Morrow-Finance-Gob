// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: S13: junior mass redemption stops at the coverage floor, shrinking senior capacity.
// @author adiii.eth

pragma solidity 0.8.34;

import {ScenarioBase} from "./ScenarioBase.t.sol";

contract S13_JuniorMassRedemptionTest is ScenarioBase {
    address juniorDepositor = makeAddr("juniorDepositor");
    address seniorDepositor = makeAddr("seniorDepositor");

    function test_S13_juniorMassRedemption_stopsAtCoverageFloor_seniorCapacityShrinks() public {
        _juniorDeposit(juniorDepositor, 200_000e6);
        _seniorDeposit(seniorDepositor, 700_000e6);

        uint256 seniorCapacityBefore = core.seniorCapacity();
        assertLt(core.seniorAssets(), seniorCapacityBefore, "sanity: senior must start with real headroom");

        uint256 juniorShares = juniorVault.balanceOf(juniorDepositor);
        vm.prank(juniorDepositor);
        uint256 requestId = juniorVault.requestRedeem(juniorShares, juniorDepositor, juniorDepositor);

        vm.prank(registry.CURATOR());
        juniorVault.closeRedeemEpoch();

        uint256 redeemableBeforeFill = core.juniorRedeemable();
        assertGt(redeemableBeforeFill, 0, "sanity: some junior redemption must be allowed before hitting the floor");
        assertLt(
            redeemableBeforeFill,
            core.juniorAssets(),
            "sanity: the floor must bind strictly below the full junior book for this to be a mass-redemption test"
        );

        vm.prank(registry.CURATOR());
        juniorVault.fulfillRedeem(requestId, type(uint128).max);

        (,, uint256 sharesFulfilled,,,) = juniorVault.redeemEpochs(requestId);
        assertLt(sharesFulfilled, juniorShares, "the fill must stop short of the full mass-redemption request");

        uint256 coverageWad = core.seniorAssets() == 0
            ? type(uint256).max
            : core.juniorAssets() * 1e18 / (core.seniorAssets() + core.juniorAssets());
        (,,, uint256 covVaultMinWad,,,,,,,,,,,,,,,) = core.policy();
        assertGe(coverageWad, covVaultMinWad, "vault coverage must never fall below covVaultMinWad after the fill");

        uint256 seniorCapacityAfter = core.seniorCapacity();
        assertLt(seniorCapacityAfter, seniorCapacityBefore, "senior capacity must shrink along with junior's book");
        assertLt(
            seniorCapacityAfter,
            core.seniorAssets(),
            "sized so the existing senior book now exceeds the new, smaller capacity"
        );

        usdc.mint(seniorDepositor, 1);
        vm.prank(seniorDepositor);
        usdc.approve(address(seniorVault), 1);
        vm.prank(seniorDepositor);
        vm.expectRevert();
        seniorVault.deposit(1, seniorDepositor);
    }
}
