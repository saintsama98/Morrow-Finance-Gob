// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: seriesCore's proportional parking claims, exercised with yield-bearing parking.
// @author adiii.eth

pragma solidity 0.8.34;

import {Vm} from "forge-std/Test.sol";
import {MorphoScenarioBase} from "../scenario/MorphoScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";

contract CoreParkingClaimsTest is MorphoScenarioBase {
    address borrower = makeAddr("borrower");
    address seniorDepositor = makeAddr("seniorDepositor");
    address juniorDepositor = makeAddr("juniorDepositor");

    function _fundAndAccrue() internal {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 2_000_000e6);
        vault.accrueBps(500);
    }

    function test_openSeries_chargesEachBookExactlyItsAmount_underYield() public {
        _fundAndAccrue();
        uint256 seniorBefore = core.idle(true);
        uint256 juniorBefore = core.idle(false);

        _openSeries(700_000e6, 150_000e6, block.timestamp + 90 days);

        assertApproxEqAbs(seniorBefore - core.idle(true), 700_000e6, 2, "senior charged exactly S");
        assertApproxEqAbs(juniorBefore - core.idle(false), 150_000e6, 2, "junior charged exactly J");
        _assertBooksReconcile();
    }

    function test_cancel_returnsEachBookItsShare_underYield() public {
        _fundAndAccrue();
        uint256 seniorBefore = core.idle(true);
        uint256 juniorBefore = core.idle(false);

        (address seriesAddr,) = _openSeries(700_000e6, 150_000e6, block.timestamp + 90 days);
        _cancel(seriesAddr);

        assertApproxEqAbs(core.idle(true), seniorBefore, 3, "senior made whole");
        assertApproxEqAbs(core.idle(false), juniorBefore, 3, "junior made whole");
        _assertBooksReconcile();
    }

    function test_deposits_areCreditedAtTheCurrentClaimPrice() public {
        _fundAndAccrue();
        uint256 seniorBefore = core.idle(true);
        uint256 juniorBefore = core.idle(false);

        _seniorDeposit(makeAddr("late"), 500_000e6);

        assertApproxEqAbs(core.idle(true) - seniorBefore, 500_000e6, 2, "a late deposit is worth what it paid");
        assertApproxEqAbs(core.idle(false), juniorBefore, 2, "and dilutes nobody");
    }

    function test_backstop_movesExactlyItsAmountFromJuniorToSenior_underYield() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 1_000_000e6);

        uint256 maturity = block.timestamp + 90 days;
        (address seriesAddr,) = _openSeries(700_000e6, 150_000e6, maturity);
        _registerAndFill(seriesAddr, maturity, 800_000e6, borrower);
        _finalize(seriesAddr);
        creditSeries series = creditSeries(seriesAddr);

        vault.accrueBps(300);
        uint256 seniorBefore = core.idle(true);
        uint256 juniorBefore = core.idle(false);

        vm.warp(maturity + 1);
        series.startSettlement();
        vm.warp(maturity + series.D_WRITE_OFF());
        vm.recordLogs();
        series.writeOff();

        uint256 backstop = _backstopFromLogs();
        assertGt(backstop, 0, "sanity: the backstop fired");
        assertEq(backstop, core.backstopPaid(seriesAddr));
        assertApproxEqAbs(core.idle(true) - seniorBefore, backstop, 2, "senior gains exactly the backstop");
        assertApproxEqAbs(juniorBefore - core.idle(false), backstop, 2, "junior gives exactly the backstop");
        _assertBooksReconcile();
    }

    function test_exits_areBoundedByParkingLiquidity() public {
        _fundAndAccrue();
        vault.setLiquidityCap(0);

        assertEq(core.parkingLiquidity(), mparking.maxWithdraw(address(core)));
        assertEq(core.parkingLiquidity(), mparking.liquidity(), "only the buffer can pay out");
        assertLe(core.juniorRedeemable(), core.parkingLiquidity(), "junior exits never exceed what is liquid");
    }

    function _backstopFromLogs() internal returns (uint256 amount) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Backstop(address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) amount += abi.decode(logs[i].data, (uint256));
        }
    }
}
