// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: realized parking losses on the core's idle cash fall on the junior book first, gains stay pro rata.
// @author adiii.eth

pragma solidity 0.8.34;

import {Vm} from "forge-std/Test.sol";
import {MorphoScenarioBase} from "../scenario/MorphoScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";

contract CoreIdleLossJuniorFirstTest is MorphoScenarioBase {
    bytes32 constant ABSORBED = keccak256("IdleLossAbsorbed(uint256,uint256)");

    address seniorDepositor = makeAddr("seniorDepositor");
    address juniorDepositor = makeAddr("juniorDepositor");
    address borrower = makeAddr("borrower");

    function _parked() internal view returns (uint256) {
        return mparking.totalAssets(address(core));
    }

    function _absorbedEvents(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(core) && logs[i].topics[0] == ABSORBED) n++;
        }
    }

    function test_idleLoss_fallsOnJuniorFirst_andShowsInViewsAtOnce() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 2_000_000e6);
        uint256 seniorBefore = core.idle(true);
        uint256 juniorBefore = core.idle(false);
        uint256 parkedBefore = _parked();

        vault.loseBps(100);
        uint256 loss = parkedBefore - _parked();
        assertGt(loss, 0);

        assertApproxEqAbs(core.idle(true), seniorBefore, 2, "senior idle untouched while junior idle can absorb");
        assertApproxEqAbs(juniorBefore - core.idle(false), loss, 2, "junior idle takes the whole loss");
        assertApproxEqAbs(
            core.seniorAssets(), seniorBefore, 2, "senior vault value is protected before any state change"
        );
        _assertBooksReconcile();
    }

    function test_idleLoss_largerThanJuniorIdle_wipesJuniorIdle_thenSeniorBearsTheRest() public {
        _juniorDeposit(juniorDepositor, 250_000e6);
        _seniorDeposit(seniorDepositor, 1_000_000e6);
        uint256 juniorIdle = core.idle(false);
        uint256 seniorBefore = core.idle(true);
        uint256 parkedBefore = _parked();

        vault.loseBps(4_000);
        uint256 loss = parkedBefore - _parked();
        assertGt(loss, juniorIdle, "the loss exceeds what junior idle can absorb");

        assertLe(core.idle(false), 1, "junior idle is used up first");
        assertApproxEqAbs(seniorBefore - core.idle(true), loss - juniorIdle, 3, "senior bears only the remainder");
        _assertBooksReconcile();
    }

    function test_idleYield_staysProRata() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 2_000_000e6);
        uint256 s = core.idle(true);
        uint256 j = core.idle(false);
        vault.accrueBps(300);
        assertApproxEqRel((core.idle(true) - s) * 1e18 / s, (core.idle(false) - j) * 1e18 / j, 1e12, "same yield rate");
    }

    function test_depositAfterLoss_settlesIt_andTheNewDepositIsWorthWhatItPaid() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 2_000_000e6);
        uint256 seniorBefore = core.idle(true);
        vault.loseBps(100);
        uint256 juniorAfterLoss = core.idle(false);

        vm.recordLogs();
        _seniorDeposit(makeAddr("late"), 500_000e6);
        assertEq(_absorbedEvents(vm.getRecordedLogs()), 1, "the pending loss is settled into the books");

        assertApproxEqAbs(core.idle(true), seniorBefore + 500_000e6, 3, "old senior protected, new senior at par");
        assertApproxEqAbs(core.idle(false), juniorAfterLoss, 3, "junior unchanged by the settlement itself");
        _assertBooksReconcile();
    }

    function test_lossAfterSettlement_protectsTheLaterSeniorDepositToo() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 2_000_000e6);
        vault.loseBps(50);
        _seniorDeposit(makeAddr("late"), 500_000e6);
        uint256 seniorBefore = core.idle(true);
        vault.loseBps(50);
        assertApproxEqAbs(core.idle(true), seniorBefore, 3, "every later loss is junior-first again");
    }

    function test_seriesPayout_isNeverReadAsALoss() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 1_000_000e6);
        uint256 maturity = block.timestamp + 90 days;
        (address seriesAddr,) = _openSeries(700_000e6, 150_000e6, maturity);
        _registerAndFill(seriesAddr, maturity, 800_000e6, borrower);

        vm.recordLogs();
        _finalize(seriesAddr);
        creditSeries series = creditSeries(seriesAddr);
        vm.warp(maturity + 1);
        series.startSettlement();
        vm.warp(maturity + series.D_WRITE_OFF());
        series.writeOff();
        assertEq(_absorbedEvents(vm.getRecordedLogs()), 0, "returns and payouts move cash in, never a loss");
        _assertBooksReconcile();
    }

    function test_unsettledGain_isSharedProRataByALaterLoss_untilASyncRatchetsTheMark() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 2_000_000e6);
        uint256 seniorBase = core.idle(true);

        vault.accrueBps(200);
        uint256 seniorWithGain = core.idle(true);
        assertGt(seniorWithGain, seniorBase);
        vault.loseBps(100);
        assertLt(core.idle(true), seniorWithGain, "an unsettled gain is not yet protected");
        assertGe(core.idle(true) + 2, seniorBase, "but senior never falls below its last settled value");

        core.syncAll();
        uint256 seniorRatcheted = core.idle(true);
        vault.loseBps(100);
        assertApproxEqAbs(core.idle(true), seniorRatcheted, 2, "after a sync the gain is protected junior-first");
    }
}
