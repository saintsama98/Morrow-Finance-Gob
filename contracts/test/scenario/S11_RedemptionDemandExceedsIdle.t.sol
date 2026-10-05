// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: S11: redemption demand larger than idle, partial fills over several rounds.
// @author adiii.eth

pragma solidity 0.8.34;

import {ScenarioBase} from "./ScenarioBase.t.sol";
import {epochMath} from "../../src/libraries/epochMath.sol";

contract S11_RedemptionDemandExceedsIdleTest is ScenarioBase {
    address juniorDepositor = makeAddr("juniorDepositor");
    address seniorA = makeAddr("seniorA");
    address seniorB = makeAddr("seniorB");
    address seniorC = makeAddr("seniorC");

    function test_S11_redemptionDemandExceedsIdle_partialThenFullFill_proRataThroughout() public {
        _juniorDeposit(juniorDepositor, 900_000e6);
        uint256 sharesA = _seniorDeposit(seniorA, 100_000e6);
        uint256 sharesB = _seniorDeposit(seniorB, 100_000e6);
        assertEq(sharesA, sharesB, "sanity: equal deposits at the same price must mint equal shares");

        _openSeries(60_000e6, 20_000e6, block.timestamp + 90 days);
        uint256 idleBeforeRequest = core.idle(true);
        assertLt(
            idleBeforeRequest,
            seniorVault.convertToAssets(sharesA + sharesB),
            "sanity: idle must be less than the combined redemption demand"
        );

        vm.prank(seniorA);
        uint256 requestId = seniorVault.requestRedeem(sharesA, seniorA, seniorA);
        vm.prank(seniorB);
        uint256 requestIdB = seniorVault.requestRedeem(sharesB, seniorB, seniorB);
        assertEq(requestId, requestIdB, "both requests must land in the same open epoch");

        vm.prank(registry.CURATOR());
        seniorVault.closeEpoch();

        vm.prank(registry.CURATOR());
        seniorVault.fulfill(requestId, type(uint128).max);

        (,, uint256 sharesFulfilled1,,,) = seniorVault.epochs(requestId);
        uint256 totalRequested = sharesA + sharesB;
        assertGt(sharesFulfilled1, 0, "round 1 must fill something");
        assertLt(sharesFulfilled1, totalRequested, "round 1 must be a genuine partial fill, not a full one");

        uint256 entitledA1 = epochMath.claimableShares(sharesA, sharesFulfilled1, totalRequested, 0);
        uint256 entitledB1 = epochMath.claimableShares(sharesB, sharesFulfilled1, totalRequested, 0);
        assertEq(
            seniorVault.claimableRedeemRequest(requestId, seniorA),
            entitledA1,
            "A's round-1 claimable must match the pro-rata formula exactly"
        );
        assertEq(
            seniorVault.claimableRedeemRequest(requestId, seniorB),
            entitledB1,
            "B's round-1 claimable must match the pro-rata formula exactly"
        );
        assertEq(entitledA1, entitledB1, "equal requesters must get an exactly equal partial fill");

        _seniorDeposit(seniorC, 500_000e6);

        vm.prank(registry.CURATOR());
        seniorVault.fulfill(requestId, type(uint128).max);

        (,, uint256 sharesFulfilled2,,,) = seniorVault.epochs(requestId);
        assertEq(sharesFulfilled2, totalRequested, "round 2 must complete the fill entirely");

        uint256 entitledA2 = epochMath.claimableShares(sharesA, sharesFulfilled2, totalRequested, 0);
        uint256 entitledB2 = epochMath.claimableShares(sharesB, sharesFulfilled2, totalRequested, 0);
        assertEq(entitledA2, sharesA, "A must be entitled to its full request once the epoch fully fills");
        assertEq(entitledB2, sharesB, "B must be entitled to its full request once the epoch fully fills");
        assertEq(
            seniorVault.claimableRedeemRequest(requestId, seniorA),
            entitledA2,
            "A's cumulative claimable must still match exactly"
        );
        assertEq(
            seniorVault.claimableRedeemRequest(requestId, seniorB),
            entitledB2,
            "B's cumulative claimable must still match exactly"
        );

        vm.prank(seniorA);
        uint256 assetsA = seniorVault.redeem(entitledA2, seniorA, seniorA);
        vm.prank(seniorB);
        uint256 assetsB = seniorVault.redeem(entitledB2, seniorB, seniorB);
        assertEq(assetsA, assetsB, "equal full redemptions at the same epoch price must pay out equal assets");
    }
}
