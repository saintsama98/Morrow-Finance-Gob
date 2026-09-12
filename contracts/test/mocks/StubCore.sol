// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {SeriesParams} from "../../src/interfaces/ISeries.sol";
import {SeriesFactory} from "../../src/series/SeriesFactory.sol";

interface IERC20Mintable {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Minimal stand-in for SeriesCore (section 20, built in M5), implementing exactly what Series needs to
/// call (ISeriesCoreMinimal) plus a fundAndOpen helper that mimics section 8.2's openSeries: transfer cash to
/// the series, then call initialize. Lets Series be built and tested end to end before the real core exists
/// (section 29, M2: "Series creation and funding against a stub core").
contract StubCore {
    address public sentinel;
    address public usdc;

    uint256 public lastReturnToSenior;
    uint256 public lastReturnToJunior;
    uint256 public lastPayoutToSenior;
    uint256 public lastPayoutToJunior;

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
    }

    function receiveReturn(uint256 toSenior, uint256 toJunior) external {
        lastReturnToSenior = toSenior;
        lastReturnToJunior = toJunior;
    }

    function receivePayout(uint256 toSenior, uint256 toJunior) external {
        lastPayoutToSenior = toSenior;
        lastPayoutToJunior = toJunior;
    }
}
