// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: unit tests for seriesCore: openSeries checks, payout hooks, backstop, valuation, and policy.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Market, Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {HashLib} from "@morpho-org/midnight/src/ratifiers/libraries/HashLib.sol";
import {UtilsLib} from "@morpho-org/midnight/src/libraries/UtilsLib.sol";
import {TickLib} from "@morpho-org/midnight/src/libraries/TickLib.sol";
import {ORACLE_PRICE_SCALE} from "@morpho-org/midnight/src/libraries/ConstantsLib.sol";

import {MidnightHarness} from "../mocks/MidnightHarness.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {StubVault} from "../mocks/StubVault.sol";
import {seriesFactory} from "../../src/series/seriesFactory.sol";
import {seriesCore} from "../../src/core/seriesCore.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesParams, SeriesState} from "../../src/interfaces/iSeries.sol";
import {iMidnightMinimal} from "../../src/interfaces/iMidnightMinimal.sol";
import {iParking} from "../../src/parking/iParking.sol";
import {idleParking} from "../../src/parking/idleParking.sol";
import {coreStorage} from "../../src/core/modules/coreStorage.sol";

contract SeriesCoreTest is Test, MidnightHarness {
    using UtilsLib for uint256;

    uint256 constant WAD = 1e18;
    seriesFactory factory;
    seriesCore core;
    StubVault seniorVaultStub;
    StubVault juniorVaultStub;
    idleParking parking;

    address governance = makeAddr("governance");
    address allocator = makeAddr("allocator");
    address curator = makeAddr("curator");
    address sentinel = makeAddr("sentinel");
    address feeRecipient = makeAddr("feeRecipient");
    address borrower = makeAddr("borrower");

    uint256 maturity;
    bytes32 marketId;
    Market market;

    function setUp() public {
        _setUpMidnightHarness();
        maturity = block.timestamp + 20 days;

        parking = new idleParking(address(usdc));

        factory = new seriesFactory(
            iMidnightMinimal(address(midnight)), address(setterRatifier), address(usdc), governance, 0.86e18, 4
        );

        core = new seriesCore(
            address(usdc), factory, iParking(address(parking)), governance, allocator, curator, sentinel
        );

        vm.prank(governance);
        factory.setCore(address(core));

        seniorVaultStub = new StubVault(core, address(usdc), true);
        juniorVaultStub = new StubVault(core, address(usdc), false);
        vm.prank(governance);
        core.setVaults(address(seniorVaultStub), address(juniorVaultStub));
        vm.prank(governance);
        core.setFeeRecipient(feeRecipient);

        vm.startPrank(governance);
        factory.proposeCollateralAllowed(cbBTC, true);
        factory.proposeOracleAllowed(cbBTC, address(cbBtcOracle), true);
        vm.stopPrank();
        vm.warp(block.timestamp + 48 hours);
        factory.executeCollateralAllowed(cbBTC, true);
        factory.executeOracleAllowed(cbBTC, address(cbBtcOracle), true);

        market = _cbBtcMarket(maturity, LLTV_77);
        marketId = _touch(market);

        usdc.mint(address(this), 10_000_000e6);
    }

    function _fundBook(bool isSenior, uint256 assets) internal {
        StubVault vault = isSenior ? seniorVaultStub : juniorVaultStub;
        usdc.mint(address(this), assets);
        usdc.transfer(address(vault), assets);
        vault.deposit(assets);
    }

    function _defaultParams(bytes32[] memory ids, uint256 kAllocCap) internal view returns (SeriesParams memory p) {
        uint256[] memory rateFloors = new uint256[](ids.length);
        uint256[] memory caps = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            rateFloors[i] = 0.005e18;
            caps[i] = kAllocCap;
        }

        p = SeriesParams({
            marketIds: ids,
            tDeployEnd: uint64(block.timestamp + 2 days),
            dWriteOff: uint64(1 days),
            covWad: 0.15e18,
            pi0Wad: 0.1e18,
            piTWad: 0.2e18,
            pi1Wad: 0.35e18,
            rateFloorWad: rateFloors,
            marketCapAssets: caps,
            kMinAssets: 50_000e6,
            thetaWad: 0.1e18,
            feeRecipient: feeRecipient,
            allocator: allocator,
            parking: iParking(address(parking)),
            offchainAttestationHash: bytes32(0)
        });
    }

    function _idsOf(bytes32 id) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = id;
    }

    function test_defaultPolicy() public view {
        (
            uint256 covWad,
            uint256 aMaxWad,
            uint256 covVaultWad,
            uint256 covVaultMinWad,,,,
            uint256 thetaWad,,
            uint256 maxSeries,
            uint256 maxRecovering,,,,,,
            bool backstopEnabled,,
        ) = core.policy();
        assertEq(covWad, 0.15e18);
        assertEq(aMaxWad, 0.3e18);
        assertEq(covVaultWad, 0.2e18);
        assertEq(covVaultMinWad, 0.15e18);
        assertEq(thetaWad, 0.1e18);
        assertEq(maxSeries, 12);
        assertEq(maxRecovering, 8);
        assertTrue(backstopEnabled, "backstop must default to ON per the locked decision");
    }

    function test_setVaults_onlyOnce() public {
        vm.prank(governance);
        vm.expectRevert(coreStorage.VaultsAlreadySet.selector);
        core.setVaults(address(1), address(2));
    }

    function test_openSeries_happyPath() public {
        _fundBook(true, 2_000_000e6);
        _fundBook(false, 500_000e6);

        vm.prank(allocator);
        address seriesAddr = core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 800_000e6, 200_000e6);

        assertEq(creditSeries(seriesAddr).seniorAllocated(), 800_000e6);
        assertEq(creditSeries(seriesAddr).juniorAllocated(), 200_000e6);
        assertEq(core.liveSeriesCount(), 1);
    }

    function test_openSeries_onlyAllocator() public {
        _fundBook(true, 2_000_000e6);
        _fundBook(false, 500_000e6);

        vm.expectRevert(coreStorage.NotAllocator.selector);
        core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 800_000e6, 200_000e6);
    }

    function test_openSeries_coverageBandTooLow() public {
        _fundBook(true, 990_000e6);
        _fundBook(false, 10_000e6);

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(coreStorage.CoverageBand.selector, 0.01e18));
        core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 990_000e6, 10_000e6);
    }

    function test_openSeries_coverageBandTooHigh() public {
        _fundBook(true, 600_000e6);
        _fundBook(false, 400_000e6);

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(coreStorage.CoverageBand.selector, 0.4e18));
        core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 600_000e6, 400_000e6);
    }

    function test_openSeries_insufficientSeniorIdle() public {
        _fundBook(true, 100_000e6);
        _fundBook(false, 200_000e6);

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(coreStorage.IdleInsufficient.selector, true, 800_000e6, 95_000e6));
        core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 800_000e6, 200_000e6);
    }

    function test_openSeries_perSeriesCapExceeded() public {
        _fundBook(true, 2_000_000e6);
        _fundBook(false, 500_000e6);

        vm.prank(allocator);
        vm.expectRevert(coreStorage.PerSeriesCapExceeded.selector);
        core.openSeries(_defaultParams(_idsOf(marketId), 2_500_000e6), 2_000_000e6, 500_000e6);
    }

    function test_openSeries_pausedReverts() public {
        _fundBook(true, 2_000_000e6);
        _fundBook(false, 500_000e6);

        vm.prank(curator);
        core.pause();

        vm.prank(allocator);
        vm.expectRevert(coreStorage.Paused.selector);
        core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 800_000e6, 200_000e6);
    }

    function test_openSeries_maxSeriesExceeded() public {
        vm.prank(sentinel);
        core.lowerMaxSeries(0);

        _fundBook(true, 2_000_000e6);
        _fundBook(false, 500_000e6);

        vm.prank(allocator);
        vm.expectRevert(coreStorage.MaxSeriesExceeded.selector);
        core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 800_000e6, 200_000e6);
    }

    function test_receiveReturn_onlyRegisteredSeries() public {
        vm.expectRevert(coreStorage.NotRegisteredSeries.selector);
        core.receiveReturn(1, 1);
    }

    function test_cancelSeries_removesFromLiveAndCreditsBooksBack() public {
        _fundBook(true, 2_000_000e6);
        _fundBook(false, 500_000e6);

        vm.prank(allocator);
        address seriesAddr = core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 800_000e6, 200_000e6);
        assertEq(core.liveSeriesCount(), 1);

        vm.prank(allocator);
        creditSeries(seriesAddr).cancel();

        assertEq(core.liveSeriesCount(), 0, "canceled series must be pruned from liveSeries");
        assertEq(core.idle(true), 2_000_000e6, "senior book must get its full allocation back");
        assertEq(core.idle(false), 500_000e6, "junior book must get its full allocation back");
    }

    function test_balanceConservation_afterDepositsAndCancel() public {
        _fundBook(true, 2_000_000e6);
        _fundBook(false, 500_000e6);

        vm.prank(allocator);
        address seriesAddr = core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 800_000e6, 200_000e6);
        vm.prank(allocator);
        creditSeries(seriesAddr).cancel();

        (, uint256 sRes,) = core.senior();
        (, uint256 jRes, uint256 jPend) = core.junior();

        assertEq(usdc.balanceOf(address(core)), sRes + jRes + jPend, "core usdc balance == reserved + pending");
        assertEq(core.idle(true), 2_000_000e6, "senior idle back to its full deposit after the cancel");
        assertEq(core.idle(false), 500_000e6, "junior idle back to its full deposit after the cancel");
        assertEq(
            parking.balanceOf(address(core)), core.idle(true) + core.idle(false), "books value the whole core account"
        );
    }

    function _fillAndFinalize(address seriesAddr, uint256 units) internal {
        _fillAndFinalizeMarket(seriesAddr, units, market);
    }

    function _fillAndFinalizeMarket(address seriesAddr, uint256 units, Market memory m) internal {
        creditSeries series = creditSeries(seriesAddr);
        uint256 tick = series.tickMaxFor(0);
        uint256 price = TickLib.tickToPrice(tick);

        Offer memory offer;
        offer.market = m;
        offer.buy = true;
        offer.maker = seriesAddr;
        offer.expiry = series.T_DEPLOY_END();
        offer.tick = tick;
        offer.group = keccak256(abi.encode("group", seriesAddr));
        offer.callback = seriesAddr;
        offer.callbackData = abi.encode(uint256(0));
        offer.ratifier = address(setterRatifier);
        offer.maxAssets = uint128(units.mulDivUp(price, WAD) + 1000e6);
        offer.continuousFeeCap = type(uint256).max;

        Offer[] memory leaves = new Offer[](1);
        leaves[0] = offer;
        bytes32 root = HashLib.hashOffer(offer);

        vm.prank(allocator);
        series.registerOffers(root, leaves);

        uint256 oraclePrice = MockOracle(m.collateralParams[0].oracle).price();
        uint256 collateral = units.mulDivUp(WAD, m.collateralParams[0].lltv).mulDivUp(ORACLE_PRICE_SCALE, oraclePrice);
        MockUSDC(m.collateralParams[0].token).mint(borrower, collateral);
        vm.startPrank(borrower);
        MockUSDC(m.collateralParams[0].token).approve(address(midnight), collateral);
        midnight.supplyCollateral(m, 0, collateral, borrower);
        vm.stopPrank();

        bytes memory ratifierData = abi.encode(root, uint256(0), new bytes32[](0));
        vm.prank(borrower);
        midnight.take(offer, ratifierData, units, borrower, borrower, address(0), "");

        vm.prank(allocator);
        series.finalize();
    }

    function test_backstop_topsUpSeniorFromJuniorIdle_whenSeniorImpaired() public {
        _fundBook(true, 2_000_000e6);
        _fundBook(false, 500_000e6);
        _fundBook(false, 500_000e6);

        vm.prank(allocator);
        address seriesAddr = core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 800_000e6, 200_000e6);
        _fillAndFinalize(seriesAddr, 1_000_000e6);

        creditSeries series = creditSeries(seriesAddr);
        uint256 seniorClaim = series.seniorClaim();

        vm.warp(maturity + 1);
        series.startSettlement();
        vm.warp(maturity + series.D_WRITE_OFF() + 1);
        series.writeOff();

        assertLt(core.backstopPaid(seriesAddr), seniorClaim + 1);
        assertGt(core.backstopPaid(seriesAddr), 0, "backstop must have topped up senior from junior's idle cash");

        assertGt(core.idle(true), 1_200_000e6, "senior book must have received the backstop transfer");
    }

    function test_backstop_disabled_doesNotMoveJuniorFunds() public {
        vm.prank(curator);
        core.disableBackstop();

        _fundBook(true, 2_000_000e6);
        _fundBook(false, 500_000e6);
        _fundBook(false, 500_000e6);

        vm.prank(allocator);
        address seriesAddr = core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 800_000e6, 200_000e6);
        _fillAndFinalize(seriesAddr, 1_000_000e6);

        creditSeries series = creditSeries(seriesAddr);
        vm.warp(maturity + 1);
        series.startSettlement();
        vm.warp(maturity + series.D_WRITE_OFF() + 1);
        series.writeOff();

        assertEq(core.backstopPaid(seriesAddr), 0, "backstop must not fire once disabled");
    }

    function test_lossIsolatedAcrossSeries_whenBackstopOff() public {
        vm.prank(curator);
        core.disableBackstop();

        _fundBook(true, 4_000_000e6);
        _fundBook(false, 1_000_000e6);

        vm.startPrank(governance);
        factory.proposeCollateralAllowed(wbtc, true);
        factory.proposeOracleAllowed(wbtc, address(wbtcOracle), true);
        vm.stopPrank();
        vm.warp(block.timestamp + 48 hours);
        factory.executeCollateralAllowed(wbtc, true);
        factory.executeOracleAllowed(wbtc, address(wbtcOracle), true);

        uint256 maturityA = block.timestamp + 40 days;
        uint256 maturityB = maturityA + 5 days;
        bytes32 marketIdA = _touch(_cbBtcMarket(maturityA, LLTV_77));
        bytes32 marketIdB = _touch(_wbtcMarket(maturityB, LLTV_77));

        vm.prank(allocator);
        address seriesA = core.openSeries(_defaultParams(_idsOf(marketIdA), 1_000_000e6), 800_000e6, 200_000e6);
        vm.prank(allocator);
        address seriesB = core.openSeries(_defaultParams(_idsOf(marketIdB), 1_000_000e6), 800_000e6, 200_000e6);

        _fillAndFinalizeMarket(seriesA, 1_000_000e6, _cbBtcMarket(maturityA, LLTV_77));

        uint256 bSeniorBefore = creditSeries(seriesB).seniorAllocated();
        uint256 bJuniorBefore = creditSeries(seriesB).juniorAllocated();

        creditSeries a = creditSeries(seriesA);
        vm.warp(maturityA + 1);
        a.startSettlement();
        vm.warp(maturityA + a.D_WRITE_OFF() + 1);
        a.writeOff();

        assertEq(creditSeries(seriesB).seniorAllocated(), bSeniorBefore, "series B's senior leg must be untouched");
        assertEq(creditSeries(seriesB).juniorAllocated(), bJuniorBefore, "series B's junior leg must be untouched");
        assertEq(
            uint8(creditSeries(seriesB).state()), uint8(SeriesState.DEPLOYING), "series B's state must be untouched"
        );
    }

    function test_liveSeriesNeverExceedsMaxSeries() public {
        vm.prank(sentinel);
        core.lowerMaxSeries(1);

        _fundBook(true, 2_000_000e6);
        _fundBook(false, 500_000e6);

        vm.prank(allocator);
        core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 800_000e6, 200_000e6);
        assertEq(core.liveSeriesCount(), 1);

        uint256 maturity2 = maturity + 3 days;
        Market memory market2 = _cbBtcMarket(maturity2, LLTV_77);
        bytes32 marketId2 = _touch(market2);

        vm.prank(allocator);
        vm.expectRevert(coreStorage.MaxSeriesExceeded.selector);
        core.openSeries(_defaultParams(_idsOf(marketId2), 1_000_000e6), 800_000e6, 200_000e6);
    }

    function test_seniorCapacity_scalesWithJuniorAssets() public {
        _fundBook(false, 200_000e6);
        assertEq(core.seniorCapacity(), 800_000e6);
    }

    function test_idleAvailable_subtractsFloor() public {
        _fundBook(true, 1_000_000e6);
        assertEq(core.idleAvailable(true), 950_000e6);
    }

    function test_stressGateOpen_trueWithNoLiveSeries() public view {
        assertTrue(core.stressGateOpen());
    }

    function test_policyChange_requiresTimelock() public {
        vm.prank(curator);
        core.proposePolicyChange(keccak256("thetaWad"), 0.15e18);

        vm.expectRevert(coreStorage.TimelockNotElapsed.selector);
        core.executePolicyChange(keccak256("thetaWad"));

        vm.warp(block.timestamp + 3 days);
        core.executePolicyChange(keccak256("thetaWad"));

        (,,,,,,, uint256 thetaWad,,,,,,,,,,,) = core.policy();
        assertEq(thetaWad, 0.15e18);
    }

    function test_sentinel_canOnlyLowerAMaxWad() public {
        vm.prank(sentinel);
        vm.expectRevert(coreStorage.TimelockIsRiskDecreasing.selector);
        core.lowerAMaxWad(0.4e18);
    }

    function test_sentinel_canPause() public {
        vm.prank(sentinel);
        core.pause();
        assertTrue(core.paused());
    }
}
