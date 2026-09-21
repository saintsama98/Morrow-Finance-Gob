// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Market, CollateralParams} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {IdLib} from "@morpho-org/midnight/src/libraries/IdLib.sol";
import {MidnightHarness} from "../mocks/MidnightHarness.sol";
import {SeriesFactory} from "../../src/series/SeriesFactory.sol";
import {IMidnightMinimal} from "../../src/interfaces/IMidnightMinimal.sol";

// Morrow Finance — unit tests for SeriesFactory's eligibility checks and timelocked allowlists.
// @author adiii.eth

/// @notice Every eligibility rule (E1-E6) failing alone, against the real Midnight contract, not a mock --
/// eligibility reads the canonical Market struct from Midnight by id, so these tests exercise that read path
/// directly.
contract SeriesFactoryTest is Test, MidnightHarness {
    SeriesFactory factory;
    address governance = makeAddr("governance");
    uint256 maturity = block.timestamp + 90 days;

    function setUp() public {
        _setUpMidnightHarness();
        factory = new SeriesFactory(
            IMidnightMinimal(address(midnight)), address(setterRatifier), address(usdc), governance, 0.86e18, 4
        );

        vm.startPrank(governance);
        _allow(cbBTC, address(cbBtcOracle));
        _allow(wbtc, address(wbtcOracle));
        vm.stopPrank();
    }

    function _allow(address token, address oracle) internal {
        factory.proposeCollateralAllowed(token, true);
        factory.proposeOracleAllowed(token, oracle, true);
        vm.warp(block.timestamp + 48 hours);
        factory.executeCollateralAllowed(token, true);
        factory.executeOracleAllowed(token, oracle, true);
        vm.warp(block.timestamp - 48 hours); // restore, so maturity math in tests stays intuitive
    }

    function test_constructor_rejectsNonSixDecimalLoanToken() public {
        // MidnightHarness's collateral stand-ins (cbBTC/wbtc) are MockUSDC instances too (6 decimals), so use
        // a token with no decimals() to trigger the revert path.
        address badToken = address(new NoDecimals());
        vm.expectRevert(SeriesFactory.DecimalsNotSix.selector);
        new SeriesFactory(
            IMidnightMinimal(address(midnight)), address(setterRatifier), badToken, governance, 0.86e18, 4
        );
    }

    function test_eligibility_happyPath() public {
        Market memory m = _cbBtcMarket(maturity, LLTV_77);
        bytes32 id = _touch(m);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        Market[] memory result = factory.checkEligibility(ids);
        assertEq(result.length, 1);
        assertEq(result[0].loanToken, address(usdc));
    }

    function test_eligibility_happyPath_multiMarketBasket() public {
        bytes32 id1 = _touch(_cbBtcMarket(maturity, LLTV_77));
        bytes32 id2 = _touch(_wbtcMarket(maturity, LLTV_77));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        factory.checkEligibility(ids); // must not revert
    }

    /// @dev E1: loanToken == usdc. Reading the canonical struct from Midnight means the only way to violate
    /// E1 is a market that was genuinely created with a different loan token.
    function test_E1_wrongLoanToken() public {
        Market memory m = _cbBtcMarket(maturity, LLTV_77);
        m.loanToken = address(0xBEEF); // a market with some other loan token entirely
        bytes32 id = _touch(m);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSelector(SeriesFactory.IneligibleMarket.selector, id, uint8(1)));
        factory.checkEligibility(ids);
    }

    /// @dev E2: same maturity across the whole basket.
    function test_E2_mismatchedMaturity() public {
        bytes32 id1 = _touch(_cbBtcMarket(maturity, LLTV_77));
        bytes32 id2 = _touch(_wbtcMarket(maturity + 1 days, LLTV_77));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        vm.expectRevert(abi.encodeWithSelector(SeriesFactory.IneligibleMarket.selector, id2, uint8(2)));
        factory.checkEligibility(ids);
    }

    /// @dev E3: enterGate and liquidatorGate must both be zero.
    function test_E3_gatedMarket_entergate() public {
        Market memory m = _cbBtcMarket(maturity, LLTV_77);
        m.enterGate = address(0xDEAD);
        bytes32 id = _touch(m);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSelector(SeriesFactory.IneligibleMarket.selector, id, uint8(3)));
        factory.checkEligibility(ids);
    }

    function test_E3_gatedMarket_liquidatorGate() public {
        Market memory m = _cbBtcMarket(maturity, LLTV_77);
        m.liquidatorGate = address(0xDEAD);
        bytes32 id = _touch(m);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSelector(SeriesFactory.IneligibleMarket.selector, id, uint8(3)));
        factory.checkEligibility(ids);
    }

    /// @dev E4: collateral must be on the allowlist.
    function test_E4_disallowedCollateral() public {
        address randomCollateral = address(new NoDecimals());
        MidnightHarnessMarketBuilder builder = new MidnightHarnessMarketBuilder();
        Market memory m = builder.buildMarket(
            address(midnight), address(usdc), randomCollateral, LLTV_77, CURSOR_25, address(cbBtcOracle), maturity
        );
        bytes32 id = _touch(m);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSelector(SeriesFactory.IneligibleMarket.selector, id, uint8(4)));
        factory.checkEligibility(ids);
    }

    /// @dev E4: oracle must be on the allowlist for that collateral.
    function test_E4_disallowedOracle() public {
        MidnightHarnessMarketBuilder builder = new MidnightHarnessMarketBuilder();
        Market memory m = builder.buildMarket(
            address(midnight), address(usdc), cbBTC, LLTV_77, CURSOR_25, address(wbtcOracle), maturity
        );
        bytes32 id = _touch(m);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSelector(SeriesFactory.IneligibleMarket.selector, id, uint8(4)));
        factory.checkEligibility(ids);
    }

    /// @dev E4: lltv must not exceed the factory's maxLltvWad ceiling (0.86e18 in this test's constructor arg).
    function test_E4_lltvAboveCeiling() public {
        Market memory m = _cbBtcMarket(maturity, LLTV_86 + 1);
        // touchMarket itself may reject an lltv tier that was never enabled; enable a slightly higher tier so
        // the failure we observe is genuinely the factory's ceiling, not Midnight's own tier gate.
        midnight.enableLltv(LLTV_86 + 1);
        bytes32 id = _touch(m);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSelector(SeriesFactory.IneligibleMarket.selector, id, uint8(4)));
        factory.checkEligibility(ids);
    }

    /// @dev E5: no duplicate market ids in one basket.
    function test_E5_duplicateMarket() public {
        bytes32 id = _touch(_cbBtcMarket(maturity, LLTV_77));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id;
        ids[1] = id;
        vm.expectRevert(abi.encodeWithSelector(SeriesFactory.DuplicateMarket.selector, id));
        factory.checkEligibility(ids);
    }

    /// @dev E6: basket size bounds.
    function test_E6_emptyBasketReverts() public {
        bytes32[] memory ids = new bytes32[](0);
        vm.expectRevert(SeriesFactory.BasketEmpty.selector);
        factory.checkEligibility(ids);
    }

    function test_E6_tooManyMarketsReverts() public {
        // factory constructed with maxMarketsPerSeries = 4
        bytes32[] memory ids = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            ids[i] = _touch(_cbBtcMarket(maturity + i, LLTV_77));
        }
        vm.expectRevert(SeriesFactory.BasketTooLarge.selector);
        factory.checkEligibility(ids);
    }

    /// @dev A market id that was never touched on Midnight fails safe: Midnight's own toMarket reverts with
    /// MarketNotCreated() (checked directly against the pinned source, contracts/lib/midnight/src/Midnight.sol)
    /// rather than returning zeroed data, so eligibility can never silently pass for a market that doesn't
    /// exist.
    function test_untouchedMarket_reverts() public {
        Market memory m = _cbBtcMarket(maturity, LLTV_77);
        bytes32 id = IdLib.toId(m); // never actually touched on chain

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.expectRevert(); // Midnight's own MarketNotCreated(), not one of our IneligibleMarket rules
        factory.checkEligibility(ids);
    }

    // --- timelock -----------------------------------------------------------------------------------------

    function test_timelock_cannotExecuteBeforeElapsed() public {
        vm.prank(governance);
        factory.proposeCollateralAllowed(address(0x1234), true);

        vm.expectRevert(SeriesFactory.TimelockNotElapsed.selector);
        factory.executeCollateralAllowed(address(0x1234), true);
    }

    function test_timelock_onlyGovernanceCanPropose() public {
        vm.expectRevert(SeriesFactory.NotGovernance.selector);
        factory.proposeCollateralAllowed(address(0x1234), true);
    }

    function test_timelock_riskIncreaseMaxLltv_hardCeilingEnforced() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(SeriesFactory.IneligibleMarket.selector, bytes32(0), uint8(4)));
        factory.proposeMaxLltv(0.92e18); // above the 0.915e18 hard ceiling
    }
}

contract NoDecimals {}

/// @dev Helper deployed as a separate contract so building a one-off Market with a non-default collateral
/// token/oracle doesn't add to the calling test function's stack pressure.
contract MidnightHarnessMarketBuilder {
    function buildMarket(
        address midnightAddr,
        address loanToken,
        address collateralToken,
        uint256 lltv,
        uint256 cursor,
        address oracle,
        uint256 maturity
    ) external view returns (Market memory market) {
        CollateralParams[] memory params = new CollateralParams[](1);
        params[0] = CollateralParams({token: collateralToken, lltv: lltv, liquidationCursor: cursor, oracle: oracle});
        market = Market({
            chainId: block.chainid,
            midnight: midnightAddr,
            loanToken: loanToken,
            collateralParams: params,
            maturity: maturity,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }
}
