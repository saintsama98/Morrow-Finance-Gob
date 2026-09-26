// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: unit tests for seriesFactory's eligibility checks and timelocked allowlists.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Market, CollateralParams} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {IdLib} from "@morpho-org/midnight/src/libraries/IdLib.sol";
import {MidnightHarness} from "../mocks/MidnightHarness.sol";
import {seriesFactory} from "../../src/series/seriesFactory.sol";
import {iMidnightMinimal} from "../../src/interfaces/iMidnightMinimal.sol";

contract SeriesFactoryTest is Test, MidnightHarness {
    seriesFactory factory;
    address governance = makeAddr("governance");
    uint256 maturity = block.timestamp + 90 days;

    function setUp() public {
        _setUpMidnightHarness();
        factory = new seriesFactory(
            iMidnightMinimal(address(midnight)), address(setterRatifier), address(usdc), governance, 0.86e18, 4
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
        vm.warp(block.timestamp - 48 hours);
    }

    function test_constructor_rejectsNonSixDecimalLoanToken() public {
        address badToken = address(new NoDecimals());
        vm.expectRevert(seriesFactory.DecimalsNotSix.selector);
        new seriesFactory(
            iMidnightMinimal(address(midnight)), address(setterRatifier), badToken, governance, 0.86e18, 4
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
        factory.checkEligibility(ids);
    }

    function test_E1_wrongLoanToken() public {
        Market memory m = _cbBtcMarket(maturity, LLTV_77);
        m.loanToken = address(0xBEEF);
        bytes32 id = _touch(m);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSelector(seriesFactory.IneligibleMarket.selector, id, uint8(1)));
        factory.checkEligibility(ids);
    }

    function test_E2_mismatchedMaturity() public {
        bytes32 id1 = _touch(_cbBtcMarket(maturity, LLTV_77));
        bytes32 id2 = _touch(_wbtcMarket(maturity + 1 days, LLTV_77));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        vm.expectRevert(abi.encodeWithSelector(seriesFactory.IneligibleMarket.selector, id2, uint8(2)));
        factory.checkEligibility(ids);
    }

    function test_E3_gatedMarket_entergate() public {
        Market memory m = _cbBtcMarket(maturity, LLTV_77);
        m.enterGate = address(0xDEAD);
        bytes32 id = _touch(m);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSelector(seriesFactory.IneligibleMarket.selector, id, uint8(3)));
        factory.checkEligibility(ids);
    }

    function test_E3_gatedMarket_liquidatorGate() public {
        Market memory m = _cbBtcMarket(maturity, LLTV_77);
        m.liquidatorGate = address(0xDEAD);
        bytes32 id = _touch(m);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSelector(seriesFactory.IneligibleMarket.selector, id, uint8(3)));
        factory.checkEligibility(ids);
    }

    function test_E4_disallowedCollateral() public {
        address randomCollateral = address(new NoDecimals());
        MidnightHarnessMarketBuilder builder = new MidnightHarnessMarketBuilder();
        Market memory m = builder.buildMarket(
            address(midnight), address(usdc), randomCollateral, LLTV_77, CURSOR_25, address(cbBtcOracle), maturity
        );
        bytes32 id = _touch(m);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSelector(seriesFactory.IneligibleMarket.selector, id, uint8(4)));
        factory.checkEligibility(ids);
    }

    function test_E4_disallowedOracle() public {
        MidnightHarnessMarketBuilder builder = new MidnightHarnessMarketBuilder();
        Market memory m = builder.buildMarket(
            address(midnight), address(usdc), cbBTC, LLTV_77, CURSOR_25, address(wbtcOracle), maturity
        );
        bytes32 id = _touch(m);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSelector(seriesFactory.IneligibleMarket.selector, id, uint8(4)));
        factory.checkEligibility(ids);
    }

    function test_E4_lltvAboveCeiling() public {
        Market memory m = _cbBtcMarket(maturity, LLTV_86 + 1);
        midnight.enableLltv(LLTV_86 + 1);
        bytes32 id = _touch(m);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSelector(seriesFactory.IneligibleMarket.selector, id, uint8(4)));
        factory.checkEligibility(ids);
    }

    function test_E5_duplicateMarket() public {
        bytes32 id = _touch(_cbBtcMarket(maturity, LLTV_77));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id;
        ids[1] = id;
        vm.expectRevert(abi.encodeWithSelector(seriesFactory.DuplicateMarket.selector, id));
        factory.checkEligibility(ids);
    }

    function test_E6_emptyBasketReverts() public {
        bytes32[] memory ids = new bytes32[](0);
        vm.expectRevert(seriesFactory.BasketEmpty.selector);
        factory.checkEligibility(ids);
    }

    function test_E6_tooManyMarketsReverts() public {
        bytes32[] memory ids = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            ids[i] = _touch(_cbBtcMarket(maturity + i, LLTV_77));
        }
        vm.expectRevert(seriesFactory.BasketTooLarge.selector);
        factory.checkEligibility(ids);
    }

    function test_untouchedMarket_reverts() public {
        Market memory m = _cbBtcMarket(maturity, LLTV_77);
        bytes32 id = IdLib.toId(m);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.expectRevert();
        factory.checkEligibility(ids);
    }

    function test_timelock_cannotExecuteBeforeElapsed() public {
        vm.prank(governance);
        factory.proposeCollateralAllowed(address(0x1234), true);

        vm.expectRevert(seriesFactory.TimelockNotElapsed.selector);
        factory.executeCollateralAllowed(address(0x1234), true);
    }

    function test_timelock_onlyGovernanceCanPropose() public {
        vm.expectRevert(seriesFactory.NotGovernance.selector);
        factory.proposeCollateralAllowed(address(0x1234), true);
    }

    function test_timelock_riskIncreaseMaxLltv_hardCeilingEnforced() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(seriesFactory.IneligibleMarket.selector, bytes32(0), uint8(4)));
        factory.proposeMaxLltv(0.92e18);
    }
}

contract NoDecimals {}

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
