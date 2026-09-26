// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the shared test stack with idle cash parked in a (mock) Morpho vault instead of idleParking.
// @author adiii.eth

pragma solidity 0.8.34;

import {SeriesRegistry} from "./SeriesRegistry.sol";
import {iParking} from "../../../src/parking/iParking.sol";
import {morphoParking} from "../../../src/parking/morphoParking.sol";
import {MockMorphoVault} from "../../mocks/MockMorphoVault.sol";

contract SeriesRegistryMorphoParking is SeriesRegistry {
    uint256 public constant BUFFER_WAD = 0.1e18;

    MockMorphoVault public morphoVault;

    function _deployParking() internal override returns (iParking) {
        morphoVault = new MockMorphoVault(usdc);
        return new morphoParking(address(usdc), address(morphoVault), BUFFER_WAD);
    }

    function morphoParkingAdapter() external view returns (morphoParking) {
        return morphoParking(address(parking));
    }
}
