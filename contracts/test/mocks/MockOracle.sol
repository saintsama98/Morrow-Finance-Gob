// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @dev Matches Midnight's IOracle interface (src/interfaces/IOracle.sol): `price()` returns a value scaled by
/// ORACLE_PRICE_SCALE = 1e36 (src/libraries/ConstantsLib.sol). Settable so tests can trigger real liquidations
/// and bad debt through the real Midnight contract (section 25.1).
contract MockOracle {
    uint256 public price;

    constructor(uint256 initialPrice) {
        price = initialPrice;
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }
}
