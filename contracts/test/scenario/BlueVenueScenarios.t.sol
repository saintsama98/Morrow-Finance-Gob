// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the yield, crunch, venue-loss and parking-claims scenarios rerun with idle cash lent directly in Morpho Blue.
// @author adiii.eth

pragma solidity 0.8.34;

import {SeriesRegistry} from "../invariant/handlers/SeriesRegistry.sol";
import {SeriesRegistryBlueParking} from "../invariant/handlers/SeriesRegistryBlueParking.sol";
import {S14_IdleYieldTest} from "./S14_IdleYield.t.sol";
import {S15_LiquidityCrunchTest} from "./S15_LiquidityCrunch.t.sol";
import {S16_ParkingVenueLossTest} from "./S16_ParkingVenueLoss.t.sol";
import {CoreParkingClaimsTest} from "../unit/CoreParkingClaims.t.sol";
import {CoreIdleLossJuniorFirstTest} from "../unit/CoreIdleLossJuniorFirst.t.sol";

abstract contract BlueVenue {
    function _blueRegistry() internal returns (SeriesRegistry reg, address knobs, address adapter) {
        SeriesRegistryBlueParking r = new SeriesRegistryBlueParking();
        return (r, address(r.knobs()), address(r.blueParkingAdapter()));
    }
}

contract S14_IdleYieldBlueTest is S14_IdleYieldTest, BlueVenue {
    function _newVenueRegistry() internal override returns (SeriesRegistry, address, address) {
        return _blueRegistry();
    }
}

contract S15_LiquidityCrunchBlueTest is S15_LiquidityCrunchTest, BlueVenue {
    function _newVenueRegistry() internal override returns (SeriesRegistry, address, address) {
        return _blueRegistry();
    }
}

contract S16_ParkingVenueLossBlueTest is S16_ParkingVenueLossTest, BlueVenue {
    function _newVenueRegistry() internal override returns (SeriesRegistry, address, address) {
        return _blueRegistry();
    }
}

contract CoreParkingClaimsBlueTest is CoreParkingClaimsTest, BlueVenue {
    function _newVenueRegistry() internal override returns (SeriesRegistry, address, address) {
        return _blueRegistry();
    }
}

contract CoreIdleLossJuniorFirstBlueTest is CoreIdleLossJuniorFirstTest, BlueVenue {
    function _newVenueRegistry() internal override returns (SeriesRegistry, address, address) {
        return _blueRegistry();
    }
}
