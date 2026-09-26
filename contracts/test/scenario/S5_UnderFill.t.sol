// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: S5: under fill, 30 percent above kMin.
// @author adiii.eth

pragma solidity 0.8.34;

import {ScenarioBase} from "./ScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {wadMath} from "../../src/libraries/wadMath.sol";

contract S5_UnderFillTest is ScenarioBase {
    using wadMath for uint256;

    address borrower = makeAddr("borrower");
    address seniorDepositor = makeAddr("seniorDepositor");
    address juniorDepositor = makeAddr("juniorDepositor");

    function test_S5_underFill_sameRatio_undeployedReturnsToBooks() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 1_000_000e6);

        uint256 S = 400_000e6;
        uint256 J = 100_000e6;
        uint256 kAlloc = S + J;
        uint256 aWadExpected = J.mulDivDown(1e18, kAlloc);

        (uint256 seniorIdleBefore, uint256 juniorIdleBefore) = (core.idle(true), core.idle(false));

        (address seriesAddr,) = _openSeries(S, J, block.timestamp + 30 days);
        creditSeries series = creditSeries(seriesAddr);

        uint256 fillUnits = kAlloc.mulDivDown(30, 100);
        _registerAndFill(seriesAddr, block.timestamp + 30 days, fillUnits, borrower);
        _finalize(seriesAddr);

        assertFalse(series.passThrough(), "a 30 percent fill of a 500k allocation is well above kMinAssets");

        uint256 kD = series.totalFilled();
        uint256 seniorDeployed = series.seniorDeployed();
        uint256 juniorDeployed = series.juniorDeployed();
        assertApproxEqAbs(
            seniorDeployed + juniorDeployed,
            kD,
            1,
            "deployed senior + junior must reconstruct the filled amount, within 1 wei rounding"
        );

        uint256 aWadRealized = juniorDeployed.mulDivDown(1e18, kD);
        assertApproxEqAbs(aWadRealized, aWadExpected, 1e12, "the deployed split must preserve the open-time a");

        uint256 returnS = S - seniorDeployed;
        uint256 returnJ = J - juniorDeployed;
        assertEq(
            core.idle(true),
            seniorIdleBefore - seniorDeployed,
            "senior idle must reflect only what was actually deployed"
        );
        assertEq(
            core.idle(false),
            juniorIdleBefore - juniorDeployed,
            "junior idle must reflect only what was actually deployed"
        );
        assertGt(returnS, 0, "most of the senior allocation should have returned undeployed");
        assertGt(returnJ, 0, "most of the junior allocation should have returned undeployed");
    }
}
