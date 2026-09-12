// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Midnight} from "@morpho-org/midnight/src/Midnight.sol";
import {SetterRatifier} from "@morpho-org/midnight/src/ratifiers/SetterRatifier.sol";
import {Market, CollateralParams} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {IdLib} from "@morpho-org/midnight/src/libraries/IdLib.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {MockOracle} from "./MockOracle.sol";

/// @dev Deploys the real Midnight contract (not a mock, section 25.1) plus the shipped SetterRatifier, enables
/// the lltv tiers and liquidation cursors used in tests, and creates cbBTC/USDC and WBTC/USDC markets with
/// settable mock oracles. Loan token is always MockUSDC (6 decimals, section 5.5).
abstract contract MidnightHarness is Test {
    uint256 internal constant LLTV_77 = 0.77e18;
    uint256 internal constant LLTV_86 = 0.86e18;
    uint256 internal constant CURSOR_25 = 0.25e18;
    uint256 internal constant CURSOR_50 = 0.5e18;

    Midnight internal midnight;
    SetterRatifier internal setterRatifier;
    MockUSDC internal usdc;
    MockOracle internal cbBtcOracle;
    MockOracle internal wbtcOracle;
    address internal cbBTC;
    address internal wbtc;

    function _setUpMidnightHarness() internal {
        midnight = new Midnight();
        setterRatifier = new SetterRatifier(address(midnight));

        midnight.setFeeSetter(address(this));
        midnight.setTickSpacingSetter(address(this));

        midnight.enableLiquidationCursor(CURSOR_25);
        midnight.enableLiquidationCursor(CURSOR_50);
        midnight.enableLltv(LLTV_77);
        midnight.enableLltv(LLTV_86);

        usdc = new MockUSDC();

        cbBtcOracle = new MockOracle(1e36 * 60_000); // ~$60k btc, ORACLE_PRICE_SCALE = 1e36 per unit collateral
        wbtcOracle = new MockOracle(1e36 * 60_000);
        cbBTC = address(new MockUSDC()); // stand-in ERC20 for the collateral token itself (balance/transfer only)
        wbtc = address(new MockUSDC());
    }

    /// @dev Builds (but does not touch) a single-collateral Market struct for cbBTC/USDC at the given maturity.
    function _cbBtcMarket(uint256 maturity, uint256 lltvWad) internal view returns (Market memory market) {
        CollateralParams[] memory params = new CollateralParams[](1);
        params[0] = CollateralParams({token: cbBTC, lltv: lltvWad, liquidationCursor: CURSOR_25, oracle: address(cbBtcOracle)});
        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(usdc),
            collateralParams: params,
            maturity: maturity,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function _wbtcMarket(uint256 maturity, uint256 lltvWad) internal view returns (Market memory market) {
        CollateralParams[] memory params = new CollateralParams[](1);
        params[0] = CollateralParams({token: wbtc, lltv: lltvWad, liquidationCursor: CURSOR_25, oracle: address(wbtcOracle)});
        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(usdc),
            collateralParams: params,
            maturity: maturity,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    /// @dev Creates the market on chain (idempotent: touchMarket is a no-op if already created) and returns
    /// its id.
    function _touch(Market memory market) internal returns (bytes32 id) {
        id = midnight.touchMarket(market);
    }

    function _warpTo(uint256 timestamp) internal {
        vm.warp(timestamp);
    }
}
