// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: stand-in for the factory and the core as a parking adapter sees them: core address and series registry.
// @author adiii.eth

pragma solidity 0.8.34;

contract MorrowRegistryStub {
    mapping(address => bool) public registered;

    function core() external view returns (address) {
        return address(this);
    }

    function register(address a) external {
        registered[a] = true;
    }

    function info(address a) external view returns (uint256, uint256, uint256, bool) {
        return (0, 0, 0, registered[a]);
    }
}
