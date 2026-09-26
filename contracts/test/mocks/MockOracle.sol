// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: settable price oracle mock matching Midnight's IOracle interface.
// @author adiii.eth

pragma solidity 0.8.34;

contract MockOracle {
    uint256 public price;

    constructor(uint256 initialPrice) {
        price = initialPrice;
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }
}
