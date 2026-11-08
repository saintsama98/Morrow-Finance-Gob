// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: every lifecycle event of the core and a series is emitted, from the right contract, with its data.
// @author adiii.eth

pragma solidity 0.8.34;

import {Vm} from "forge-std/Test.sol";
import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {RedTeamBase} from "../exploit/RedTeamBase.sol";
import {CreditSeries} from "../../src/series/CreditSeries.sol";
import {SeriesStorage} from "../../src/series/modules/SeriesStorage.sol";
import {CoreStorage} from "../../src/core/modules/CoreStorage.sol";
import {SeriesFactory} from "../../src/series/SeriesFactory.sol";

contract LifecycleEventsTest is RedTeamBase {
    address internal borrower = makeAddr("borrower");
    Vm.Log[] internal seen;

    function _record() internal {
        Vm.Log[] memory got = vm.getRecordedLogs();
        for (uint256 i = 0; i < got.length; i++) {
            seen.push(got[i]);
        }
    }

    function _count(address emitter, bytes32 topic0) internal view returns (uint256 n) {
        for (uint256 i = 0; i < seen.length; i++) {
            if (seen[i].emitter == emitter && seen[i].topics.length > 0 && seen[i].topics[0] == topic0) n++;
        }
    }

    /// Open, fill, finalize, write off, recover in full and claim the fee: each step's events, from its emitter.
    function test_writeOffAndRecovery_emitEveryEvent() public {
        _fundBook(true, 2_000_000e6);
        _fundBook(false, 1_000_000e6);
        Market memory m = _cbBtcMarket(maturity, LLTV_77);

        vm.recordLogs();
        CreditSeries s = _openFillFinalize(m, borrower, 800_000e6, 200_000e6, 1_000_000e6);
        _writeOff(s);
        _repay(m, borrower, uint256(midnight.debt(_touch(m), borrower)));
        s.collect(0);
        s.claimFee();
        core.syncAll();
        _record();

        address c = address(core);
        address a = address(s);
        assertEq(_count(c, CoreStorage.SeriesFunded.selector), 1, "SeriesFunded");
        assertEq(_count(c, CoreStorage.ReturnReceived.selector), 1, "ReturnReceived at finalize");
        assertEq(_count(c, CoreStorage.PayoutReceived.selector), 2, "PayoutReceived at write-off and recovery");
        assertEq(_count(c, CoreStorage.Backstop.selector), 1, "Backstop at write-off");
        assertEq(_count(c, CoreStorage.BackstopRefunded.selector), 1, "BackstopRefunded at recovery");
        assertEq(_count(c, CoreStorage.Synced.selector), 1, "Synced");

        assertEq(_count(a, SeriesStorage.Initialized.selector), 1, "Initialized");
        assertEq(_count(a, SeriesStorage.OffersRegistered.selector), 1, "OffersRegistered");
        assertEq(_count(a, SeriesStorage.Filled.selector), 1, "Filled");
        assertEq(_count(a, SeriesStorage.Finalized.selector), 1, "Finalized");
        assertEq(_count(a, SeriesStorage.SettlementStarted.selector), 1, "SettlementStarted");
        assertEq(_count(a, SeriesStorage.WrittenOff.selector), 1, "WrittenOff");
        assertEq(_count(a, SeriesStorage.Collected.selector), 1, "Collected");
        assertEq(_count(a, SeriesStorage.Waterfall.selector), 2, "Waterfall at write-off and recovery");
        assertEq(_count(a, SeriesStorage.FeeClaimed.selector), 1, "FeeClaimed on junior profit");
    }

    function test_settle_emitsSettled() public {
        _fundBook(true, 2_000_000e6);
        _fundBook(false, 1_000_000e6);
        Market memory m = _cbBtcMarket(maturity, LLTV_77);
        CreditSeries s = _openFillFinalize(m, borrower, 800_000e6, 200_000e6, 1_000_000e6);
        _repay(m, borrower, uint256(midnight.debt(_touch(m), borrower)));
        vm.warp(maturity + 1);
        s.startSettlement();
        s.collect(0);

        vm.recordLogs();
        s.settle();
        _record();
        assertEq(_count(address(s), SeriesStorage.Settled.selector), 1, "Settled");
        assertEq(_count(address(core), CoreStorage.PayoutReceived.selector), 1, "PayoutReceived at settle");
        assertEq(_count(address(core), CoreStorage.Backstop.selector), 0, "no backstop when senior is whole");
    }

    function test_cancel_emitsCanceledWithTheSplit() public {
        _fundBook(true, 2_000_000e6);
        _fundBook(false, 1_000_000e6);
        CreditSeries s = _openSeries(_cbBtcMarket(maturity, LLTV_77), 800_000e6, 200_000e6);
        vm.expectEmit(false, false, false, true, address(s));
        emit SeriesStorage.Canceled(800_000e6, 200_000e6);
        vm.prank(sentinel);
        s.cancel();
    }

    function test_openSeries_emitsSeriesFundedWithAllocations() public {
        _fundBook(true, 2_000_000e6);
        _fundBook(false, 1_000_000e6);
        bytes32 id = _touch(_cbBtcMarket(maturity, LLTV_77));
        vm.expectEmit(false, false, false, true, address(core));
        emit CoreStorage.SeriesFunded(address(0), 800_000e6, 200_000e6);
        vm.prank(allocator);
        core.openSeries(_params(id, 1_000_000e6), 800_000e6, 200_000e6);
    }

    function test_governanceEvents() public {
        vm.expectEmit(false, false, false, true, address(core));
        emit CoreStorage.FeeRecipientSet(sentinel);
        vm.prank(governance);
        core.setFeeRecipient(sentinel);

        vm.expectEmit(false, false, false, true, address(core));
        emit CoreStorage.Paused_(true);
        vm.prank(sentinel);
        core.pause();

        vm.expectEmit(false, false, false, true, address(core));
        emit CoreStorage.Paused_(false);
        vm.prank(governance);
        core.unpause();

        uint256 at = vm.getBlockTimestamp() + 3 days;
        vm.expectEmit(true, false, false, true, address(core));
        emit CoreStorage.PolicySubmitted(keccak256("maxSeries"), 5, at);
        vm.prank(curator);
        core.proposePolicyChange(keccak256("maxSeries"), 5);

        vm.warp(at);
        vm.expectEmit(true, false, false, true, address(core));
        emit CoreStorage.PolicyExecuted(keccak256("maxSeries"), 5);
        core.executePolicyChange(keccak256("maxSeries"));
    }

    function test_factoryEvents() public {
        uint256 at = vm.getBlockTimestamp() + 48 hours;
        vm.expectEmit(false, false, false, true, address(factory));
        emit SeriesFactory.MaxLltvProposed(0.77e18, at);
        vm.prank(governance);
        factory.proposeMaxLltv(0.77e18);

        vm.warp(at);
        vm.expectEmit(false, false, false, true, address(factory));
        emit SeriesFactory.MaxLltvExecuted(0.77e18);
        factory.executeMaxLltv(0.77e18);

        vm.expectEmit(false, false, false, true, address(factory));
        emit SeriesFactory.MaxMarketsPerSeriesProposed(2, at + 48 hours);
        vm.prank(governance);
        bytes32 id = factory.proposeMaxMarketsPerSeries(2);

        vm.expectEmit(true, false, false, false, address(factory));
        emit SeriesFactory.ChangeCanceled(id);
        vm.prank(governance);
        factory.cancelChange(id);

        vm.expectEmit(true, false, false, false, address(factory));
        emit SeriesFactory.GovernanceUpdated(sentinel);
        vm.prank(governance);
        factory.transferGovernance(sentinel);
    }
}
