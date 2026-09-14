// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

// Morrow Finance — settable price oracle mock matching Midnight's IOracle interface.
// @author adiii.eth

/// @notice Matches Midnight's IOracle interface: `price()` returns a value scaled by ORACLE_PRICE_SCALE.
/// Settable so tests can trigger real liquidations and bad debt through the real Midnight contract.
contract MockOracle {
    uint256 public price;

    constructor(uint256 initialPrice) {
        price = initialPrice;
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }
}
