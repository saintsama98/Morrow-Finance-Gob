// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: minimal stand-in core, letting creditSeries be tested end to end before the real core exists.
// @author adiii.eth

pragma solidity 0.8.34;

import {SeriesParams} from "../../src/interfaces/iSeries.sol";
import {seriesFactory} from "../../src/series/seriesFactory.sol";

interface IERC20Mintable {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract StubCore {
    address public sentinel;
    address public usdc;

    uint256 public lastReturnToSenior;
    uint256 public lastReturnToJunior;
    uint256 public lastPayoutToSenior;
    uint256 public lastPayoutToJunior;

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

    function createAndFund(seriesFactory factory, SeriesParams calldata p, uint256 seniorAmount, uint256 juniorAmount)
        external
        returns (address series)
    {
        series = factory.createSeries(p);
        uint256 amount = seniorAmount + juniorAmount;
        require(IERC20Mintable(usdc).approve(address(p.parking), amount), "approve failed");
        p.parking.deposit(amount);
        p.parking.transferPosition(series, amount);
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
