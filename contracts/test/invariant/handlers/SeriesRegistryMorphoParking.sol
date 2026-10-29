// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the shared test stack with idle cash parked in a (mock) Morpho vault instead of IdleParking.
// @author adiii.eth

pragma solidity 0.8.34;

import {SeriesRegistry} from "./SeriesRegistry.sol";
import {IParking} from "../../../src/parking/IParking.sol";
import {MorphoParking} from "../../../src/parking/MorphoParking.sol";
import {MockMorphoVault} from "../../mocks/MockMorphoVault.sol";

contract SeriesRegistryMorphoParking is SeriesRegistry {
    uint256 public constant BUFFER_WAD = 0.1e18;

    MockMorphoVault public morphoVault;

    function _deployParking() internal override returns (IParking) {
        morphoVault = new MockMorphoVault(usdc);
        return new MorphoParking(address(usdc), address(morphoVault), BUFFER_WAD);
    }

    function morphoParkingAdapter() external view returns (MorphoParking) {
        return MorphoParking(address(parking));
    }
}
