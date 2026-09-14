// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {SeriesParams} from "../../src/interfaces/ISeries.sol";
import {SeriesFactory} from "../../src/series/SeriesFactory.sol";

interface IERC20Mintable {
    function transfer(address to, uint256 amount) external returns (bool);
}

// Morrow Finance — minimal stand-in core, letting Series be tested end to end before the real core exists.
// @author adiii.eth

/// @notice Minimal stand-in for SeriesCore, implementing exactly what Series needs to call
/// (ISeriesCoreMinimal) plus a createAndFund helper that mimics the real core's openSeries: create the
/// series, transfer cash to it, then call initialize.
contract StubCore {
    address public sentinel;
    address public usdc;

    uint256 public lastReturnToSenior;
    uint256 public lastReturnToJunior;
    uint256 public lastPayoutToSenior;
    uint256 public lastPayoutToJunior;

    /// @dev Cumulative totals, additive on top of the "last call" fields above so existing tests that check
    /// lastReturnTo*/lastPayoutTo* are unaffected. Used as ghost variables by the invariant suite.
    uint256 public cumReturnToSenior;
    uint256 public cumReturnToJunior;
    uint256 public cumPayoutToSenior;
    uint256 public cumPayoutToJunior;
    mapping(address => bool) public isKnownSeries;
    address[] public knownSeries;

    constructor(address usdc_, address sentinel_) {
        usdc = usdc_;
        sentinel = sentinel_;
    }

    function createAndFund(SeriesFactory factory, SeriesParams calldata p, uint256 seniorAmount, uint256 juniorAmount)
        external
        returns (address series)
    {
        series = factory.createSeries(p);
        require(IERC20Mintable(usdc).transfer(series, seniorAmount + juniorAmount), "transfer failed");
        (bool ok,) = series.call(abi.encodeWithSignature("initialize(uint256,uint256)", seniorAmount, juniorAmount));
        require(ok, "initialize failed");

        isKnownSeries[series] = true;
        knownSeries.push(series);
    }

    function knownSeriesCount() external view returns (uint256) {
        return knownSeries.length;
    }

    function receiveReturn(uint256 toSenior, uint256 toJunior) external {
        lastReturnToSenior = toSenior;
        lastReturnToJunior = toJunior;
        cumReturnToSenior += toSenior;
        cumReturnToJunior += toJunior;
    }

    function receivePayout(uint256 toSenior, uint256 toJunior) external {
        lastPayoutToSenior = toSenior;
        lastPayoutToJunior = toJunior;
        cumPayoutToSenior += toSenior;
        cumPayoutToJunior += toJunior;
    }
}
