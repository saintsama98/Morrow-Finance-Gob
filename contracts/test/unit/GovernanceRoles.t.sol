// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: role wiring, the instant risk-reducing levers, the policy veto and the factory timelocks.
// @author adiii.eth

pragma solidity 0.8.34;

import {RedTeamBase} from "../exploit/RedTeamBase.sol";
import {CoreStorage} from "../../src/core/modules/CoreStorage.sol";
import {SeriesFactory} from "../../src/series/SeriesFactory.sol";

contract GovernanceRolesTest is RedTeamBase {
    address internal stranger = makeAddr("stranger");
    address internal next = makeAddr("next");

    // ---- role setters ----

    function test_roleSetters_onlyGovernance() public {
        vm.startPrank(stranger);
        vm.expectRevert(CoreStorage.NotGovernance.selector);
        core.transferGovernance(stranger);
        vm.expectRevert(CoreStorage.NotGovernance.selector);
        core.setAllocator(stranger);
        vm.expectRevert(CoreStorage.NotGovernance.selector);
        core.setCurator(stranger);
        vm.expectRevert(CoreStorage.NotGovernance.selector);
        core.setSentinel(stranger);
        vm.expectRevert(CoreStorage.NotGovernance.selector);
        core.setFeeRecipient(stranger);
        vm.expectRevert(CoreStorage.NotGovernance.selector);
        core.unpause();
        vm.stopPrank();
    }

    function test_transferGovernance_movesEveryGovernancePower() public {
        vm.prank(governance);
        core.transferGovernance(next);
        assertEq(core.governance(), next);

        vm.prank(governance);
        vm.expectRevert(CoreStorage.NotGovernance.selector);
        core.setAllocator(governance);

        vm.prank(next);
        core.setAllocator(stranger);
        assertEq(core.allocator(), stranger);
    }

    function test_setAllocator_oldAllocatorLosesOpenSeries() public {
        vm.prank(governance);
        core.setAllocator(next);
        assertEq(core.allocator(), next);

        bytes32 id = _touch(_cbBtcMarket(maturity, LLTV_77));
        vm.prank(allocator);
        vm.expectRevert(CoreStorage.NotAllocator.selector);
        core.openSeries(_params(id, 1_000_000e6), 800_000e6, 200_000e6);
    }

    function test_setCurator_oldCuratorLosesPolicyAndPause() public {
        vm.prank(governance);
        core.setCurator(next);
        assertEq(core.curator(), next);

        vm.startPrank(curator);
        vm.expectRevert(CoreStorage.NotCuratorOrSentinel.selector);
        core.proposePolicyChange(keccak256("maxSeries"), 5);
        vm.expectRevert(CoreStorage.NotCuratorOrSentinel.selector);
        core.pause();
        vm.stopPrank();

        vm.prank(next);
        core.proposePolicyChange(keccak256("maxSeries"), 5);
    }

    function test_setSentinel_oldSentinelLosesLevers() public {
        vm.prank(governance);
        core.setSentinel(next);
        assertEq(core.sentinel(), next);

        vm.prank(sentinel);
        vm.expectRevert(CoreStorage.NotCuratorOrSentinel.selector);
        core.pause();

        vm.prank(next);
        core.pause();
        assertTrue(core.paused());
    }

    function test_setFeeRecipient_rejectsZero() public {
        vm.prank(governance);
        vm.expectRevert(CoreStorage.ZeroAddress.selector);
        core.setFeeRecipient(address(0));
    }

    // ---- instant levers: one direction only, curator or sentinel only ----

    function test_lowerMaxPerSeriesAssets_onlyDown() public {
        vm.prank(stranger);
        vm.expectRevert(CoreStorage.NotCuratorOrSentinel.selector);
        core.lowerMaxPerSeriesAssets(1);

        vm.prank(sentinel);
        vm.expectRevert(CoreStorage.TimelockIsRiskDecreasing.selector);
        core.lowerMaxPerSeriesAssets(1_000_001e6);

        vm.prank(sentinel);
        core.lowerMaxPerSeriesAssets(10e6);
        (,,,,,,,,,,, uint256 v,,,,,,,) = core.policy();
        assertEq(v, 10e6);
    }

    function test_raiseMinIdleJuniorWad_onlyUpAndAtMostOne() public {
        vm.startPrank(curator);
        vm.expectRevert(CoreStorage.TimelockIsRiskDecreasing.selector);
        core.raiseMinIdleJuniorWad(0.01e18);
        vm.expectRevert(CoreStorage.TimelockIsRiskDecreasing.selector);
        core.raiseMinIdleJuniorWad(1e18 + 1);
        core.raiseMinIdleJuniorWad(0.2e18);
        vm.stopPrank();
        (,,,,,,,,,,,,,, uint256 v,,,,) = core.policy();
        assertEq(v, 0.2e18);
    }

    function test_raiseStressJuniorFloorWad_onlyUpAndAtMostOne() public {
        vm.startPrank(sentinel);
        vm.expectRevert(CoreStorage.TimelockIsRiskDecreasing.selector);
        core.raiseStressJuniorFloorWad(0.4e18);
        vm.expectRevert(CoreStorage.TimelockIsRiskDecreasing.selector);
        core.raiseStressJuniorFloorWad(1e18 + 1);
        core.raiseStressJuniorFloorWad(0.8e18);
        vm.stopPrank();
        (,,,,,,,,,,,,,,, uint256 v,,,) = core.policy();
        assertEq(v, 0.8e18);
    }

    function test_lever_dropsAQueuedChangeOnTheSameKey() public {
        vm.prank(curator);
        core.proposePolicyChange(keccak256("stressJuniorFloorWad"), 0.1e18);

        vm.expectEmit(true, false, false, false, address(core));
        emit CoreStorage.PolicyCanceled(keccak256("stressJuniorFloorWad"));
        vm.prank(sentinel);
        core.raiseStressJuniorFloorWad(0.6e18);

        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.expectRevert(CoreStorage.TimelockNotElapsed.selector);
        core.executePolicyChange(keccak256("stressJuniorFloorWad"));
    }

    // ---- policy veto ----

    function test_cancelPolicyChange_byEachVetoer() public {
        address[3] memory vetoers = [curator, sentinel, governance];
        for (uint256 k = 0; k < 3; k++) {
            vm.prank(curator);
            core.proposePolicyChange(keccak256("maxSeries"), 20 + k);
            vm.prank(vetoers[k]);
            core.cancelPolicyChange(keccak256("maxSeries"));
            (bool active,,,) = core.pendingPolicyChanges(keccak256("maxSeries"));
            assertFalse(active);
        }
    }

    function test_cancelPolicyChange_strangerReverts() public {
        vm.prank(curator);
        core.proposePolicyChange(keccak256("maxSeries"), 20);
        vm.prank(stranger);
        vm.expectRevert(CoreStorage.NotPolicyVetoer.selector);
        core.cancelPolicyChange(keccak256("maxSeries"));
    }

    function test_staleChange_revertsWithItsKey() public {
        vm.prank(curator);
        core.proposePolicyChange(keccak256("maxSeries"), 20);
        vm.prank(governance);
        core.setCurator(next);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.expectRevert(abi.encodeWithSelector(CoreStorage.StalePolicyChange.selector, keccak256("maxSeries")));
        core.executePolicyChange(keccak256("maxSeries"));
    }

    function test_proposal_outOfRange_namesKeyAndValue() public {
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CoreStorage.PolicyOutOfRange.selector, keccak256("thetaWad"), 0.3e18));
        core.proposePolicyChange(keccak256("thetaWad"), 0.3e18);
    }

    function test_execution_rejectsCovAboveAMax() public {
        vm.startPrank(curator);
        core.proposePolicyChange(keccak256("covWad"), 0.4e18);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.expectRevert(abi.encodeWithSelector(CoreStorage.PolicyOutOfRange.selector, keccak256("aMaxWad"), 0.3e18));
        core.executePolicyChange(keccak256("covWad"));
    }

    // ---- factory timelocks ----

    function test_factory_maxMarketsPerSeries_timelockAndCap() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(SeriesFactory.IneligibleMarket.selector, bytes32(0), uint8(6)));
        factory.proposeMaxMarketsPerSeries(9);

        vm.prank(governance);
        factory.proposeMaxMarketsPerSeries(2);
        vm.expectRevert(SeriesFactory.TimelockNotElapsed.selector);
        factory.executeMaxMarketsPerSeries(2);

        vm.warp(vm.getBlockTimestamp() + 48 hours);
        factory.executeMaxMarketsPerSeries(2);
        assertEq(factory.maxMarketsPerSeries(), 2);
    }

    function test_factory_maxLltv_timelock() public {
        vm.prank(governance);
        factory.proposeMaxLltv(0.77e18);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        factory.executeMaxLltv(0.77e18);
        assertEq(factory.maxLltvWad(), 0.77e18);

        vm.expectRevert(SeriesFactory.TimelockNotElapsed.selector);
        factory.executeMaxLltv(0.77e18);
    }

    function test_factory_transferGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(SeriesFactory.NotGovernance.selector);
        factory.transferGovernance(stranger);

        vm.prank(governance);
        factory.transferGovernance(next);
        assertEq(factory.governance(), next);

        vm.prank(governance);
        vm.expectRevert(SeriesFactory.NotGovernance.selector);
        factory.proposeMaxLltv(0.77e18);
    }

    /// A change queued by a governance that is then replaced must not execute, and governance can cancel its own.
    function test_factory_staleAndCanceledChangesDoNotExecute() public {
        address badOracle = makeAddr("badOracle");
        vm.prank(governance);
        factory.proposeOracleAllowed(cbBTC, badOracle, true);
        vm.prank(governance);
        factory.transferGovernance(next);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        try factory.executeOracleAllowed(cbBTC, badOracle, true) {} catch {}
        assertFalse(factory.oracleAllowed(cbBTC, badOracle), "the replaced governance's change went through");

        vm.prank(next);
        bytes32 id = factory.proposeMaxLltv(0.77e18);
        vm.prank(next);
        factory.cancelChange(id);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(SeriesFactory.TimelockNotElapsed.selector);
        factory.executeMaxLltv(0.77e18);
    }
}
