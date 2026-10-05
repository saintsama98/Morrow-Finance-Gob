// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: the shared test stack with idle cash lent directly in one (mock) Morpho Blue market through blueParking.
// @author adiii.eth

pragma solidity 0.8.34;

import {MarketParams} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-org/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SeriesRegistry} from "./SeriesRegistry.sol";
import {iParking} from "../../../src/parking/iParking.sol";
import {blueParking} from "../../../src/parking/blueParking.sol";
import {MockMorphoBlue, MockBlueIrm} from "../../mocks/MockMorphoBlue.sol";

contract BlueVenueKnobs {
    using MarketParamsLib for MarketParams;

    MockMorphoBlue public immutable BLUE;
    MarketParams internal params;

    constructor(MockMorphoBlue blue, MarketParams memory params_) {
        BLUE = blue;
        params = params_;
    }

    function accrueBps(uint256 bps) external {
        BLUE.addYield(params, uint256(BLUE.market(params.id()).totalSupplyAssets) * bps / 10_000);
    }

    function loseBps(uint256 bps) external {
        BLUE.loseAssets(params, uint256(BLUE.market(params.id()).totalSupplyAssets) * bps / 10_000);
    }

    function setLiquidityCap(uint256 cap) external {
        BLUE.setLiquidityCap(params, cap);
    }
}

contract SeriesRegistryBlueParking is SeriesRegistry {
    uint256 public constant BUFFER_WAD = 0.1e18;

    MockMorphoBlue public blue;
    MockBlueIrm public irm;
    BlueVenueKnobs public knobs;

    function _deployParking() internal override returns (iParking) {
        blue = new MockMorphoBlue(usdc);
        irm = new MockBlueIrm();
        MarketParams memory params = MarketParams({
            loanToken: address(usdc),
            collateralToken: collateralToken,
            oracle: address(oracle),
            irm: address(irm),
            lltv: LLTV
        });
        blue.createMarket(params);
        knobs = new BlueVenueKnobs(blue, params);
        return new blueParking(address(usdc), address(blue), address(realFactory), params, BUFFER_WAD);
    }

    function blueParkingAdapter() external view returns (blueParking) {
        return blueParking(address(parking));
    }
}
