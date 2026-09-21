// SPDX-License-Identifier: BUSL-1.1
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
import {SeriesFactory} from "../../src/series/SeriesFactory.sol";
import {SeriesCore} from "../../src/core/SeriesCore.sol";
import {Series} from "../../src/series/Series.sol";
import {SeriesParams, SeriesState} from "../../src/interfaces/ISeries.sol";
import {IMidnightMinimal} from "../../src/interfaces/IMidnightMinimal.sol";
import {IParking} from "../../src/parking/IParking.sol";
import {IdleParking} from "../../src/parking/IdleParking.sol";

// Morrow Finance — unit tests for SeriesCore: openSeries checks, payout hooks, backstop, valuation, and policy.
// @author adiii.eth

/// @notice openSeries checks, receiveReturn/receivePayout (backstop included, ON by default for this build),
/// valuation, capacity/coverage floor, stress gate, curator timelock.
///
/// Senior capacity and junior coverage-floor enforcement *at deposit/redemption time* actually live in the
/// vaults, which don't exist yet in this codebase -- the core only exposes the view functions
/// (seniorCapacity(), juniorRedeemable()) those checks read. Tested here as "the views compute correctly", not
/// as enforced reverts, since there's nothing yet that enforces them.
contract SeriesCoreTest is Test, MidnightHarness {
    using UtilsLib for uint256;

    uint256 constant WAD = 1e18;
    SeriesFactory factory;
    SeriesCore core;
    StubVault seniorVaultStub;
    StubVault juniorVaultStub;
    IdleParking parking;

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

        parking = new IdleParking(address(usdc));

        factory = new SeriesFactory(
            IMidnightMinimal(address(midnight)), address(setterRatifier), address(usdc), governance, 0.86e18, 4
        );

        core = new SeriesCore(
            address(usdc), factory, IParking(address(parking)), governance, allocator, curator, sentinel
        );

        vm.prank(governance);
        factory.setCore(address(core));

        seniorVaultStub = new StubVault(core, address(usdc), true);
        juniorVaultStub = new StubVault(core, address(usdc), false);
        vm.prank(governance);
        core.setVaults(address(seniorVaultStub), address(juniorVaultStub));

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
        // StubVault.deposit() calls usdc.transfer(core, assets) as itself, so it needs the balance directly.
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
            parking: IParking(address(parking)),
            offchainAttestationHash: bytes32(0)
        });
    }

    function _idsOf(bytes32 id) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = id;
    }

    // --- setup sanity --------------------------------------------------------------------------------------

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
        vm.expectRevert(SeriesCore.VaultsAlreadySet.selector);
        core.setVaults(address(1), address(2));
    }

    // --- openSeries ------------------------------------------------------------------------------------------

    function test_openSeries_happyPath() public {
        _fundBook(true, 2_000_000e6);
        _fundBook(false, 500_000e6);

        vm.prank(allocator);
        address seriesAddr = core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 800_000e6, 200_000e6);

        assertEq(Series(seriesAddr).seniorAllocated(), 800_000e6);
        assertEq(Series(seriesAddr).juniorAllocated(), 200_000e6);
        assertEq(core.liveSeriesCount(), 1);
    }

    function test_openSeries_onlyAllocator() public {
        _fundBook(true, 2_000_000e6);
        _fundBook(false, 500_000e6);

        vm.expectRevert(SeriesCore.NotAllocator.selector);
        core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 800_000e6, 200_000e6);
    }

    function test_openSeries_coverageBandTooLow() public {
        _fundBook(true, 990_000e6);
        _fundBook(false, 10_000e6); // a = 10k/1m = 1% < covWad (15%)

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(SeriesCore.CoverageBand.selector, 0.01e18));
        core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 990_000e6, 10_000e6);
    }

    function test_openSeries_coverageBandTooHigh() public {
        _fundBook(true, 600_000e6);
        _fundBook(false, 400_000e6); // a = 40% > aMaxWad (30%)

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(SeriesCore.CoverageBand.selector, 0.4e18));
        core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 600_000e6, 400_000e6);
    }

    function test_openSeries_insufficientSeniorIdle() public {
        _fundBook(true, 100_000e6);
        _fundBook(false, 200_000e6);

        vm.prank(allocator);
        // idleAvailable subtracts the 5% minIdleSeniorWad floor: 100_000e6 funded -> 95_000e6 available.
        vm.expectRevert(abi.encodeWithSelector(SeriesCore.IdleInsufficient.selector, true, 800_000e6, 95_000e6));
        core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 800_000e6, 200_000e6);
    }

    function test_openSeries_perSeriesCapExceeded() public {
        _fundBook(true, 2_000_000e6);
        _fundBook(false, 500_000e6);

        vm.prank(allocator);
        vm.expectRevert(SeriesCore.PerSeriesCapExceeded.selector);
        // default maxPerSeriesAssets is 1_000_000e6
        core.openSeries(_defaultParams(_idsOf(marketId), 2_500_000e6), 2_000_000e6, 500_000e6);
    }

    function test_openSeries_pausedReverts() public {
        _fundBook(true, 2_000_000e6);
        _fundBook(false, 500_000e6);

        vm.prank(curator);
        core.pause();

        vm.prank(allocator);
        vm.expectRevert(SeriesCore.Paused.selector);
        core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 800_000e6, 200_000e6);
    }

    function test_openSeries_maxSeriesExceeded() public {
        vm.prank(sentinel);
        core.lowerMaxSeries(0);

        _fundBook(true, 2_000_000e6);
        _fundBook(false, 500_000e6);

        vm.prank(allocator);
        vm.expectRevert(SeriesCore.MaxSeriesExceeded.selector);
        core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 800_000e6, 200_000e6);
    }

    // --- receiveReturn / receivePayout ------------------------------------------------------------------------

    function test_receiveReturn_onlyRegisteredSeries() public {
        vm.expectRevert(SeriesCore.NotRegisteredSeries.selector);
        core.receiveReturn(1, 1);
    }

    function test_cancelSeries_removesFromLiveAndCreditsBooksBack() public {
        _fundBook(true, 2_000_000e6);
        _fundBook(false, 500_000e6);

        vm.prank(allocator);
        address seriesAddr = core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 800_000e6, 200_000e6);
        assertEq(core.liveSeriesCount(), 1);

        vm.prank(allocator);
        Series(seriesAddr).cancel();

        assertEq(core.liveSeriesCount(), 0, "canceled series must be pruned from liveSeries");
        (uint256 sharesSenior,,) = core.senior();
        (uint256 sharesJunior,,) = core.junior();
        assertEq(sharesSenior, 2_000_000e6, "senior book must get its full allocation back");
        assertEq(sharesJunior, 500_000e6, "junior book must get its full allocation back");
    }

    /// @dev Core usdc balance == senior reserved + junior reserved + junior pending deposits (bounded dust),
    /// and core parking shares == senior book shares + junior book shares.
    function test_balanceConservation_afterDepositsAndCancel() public {
        _fundBook(true, 2_000_000e6);
        _fundBook(false, 500_000e6);

        vm.prank(allocator);
        address seriesAddr = core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 800_000e6, 200_000e6);
        vm.prank(allocator);
        Series(seriesAddr).cancel();

        (uint256 sSh, uint256 sRes,) = core.senior();
        (uint256 jSh, uint256 jRes, uint256 jPend) = core.junior();

        assertEq(usdc.balanceOf(address(core)), sRes + jRes + jPend, "core usdc balance == reserved + pending");
        assertEq(parking.balanceOf(address(core)), sSh + jSh, "core parking shares == senior + junior book shares");
    }

    // --- backstop (ON by default) -----------------------------------------------------------------------------

    function _fillAndFinalize(address seriesAddr, uint256 units) internal {
        _fillAndFinalizeMarket(seriesAddr, units, market);
    }

    function _fillAndFinalizeMarket(address seriesAddr, uint256 units, Market memory m) internal {
        Series series = Series(seriesAddr);
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
        // extra junior idle sitting in the book, available for backstop beyond what's allocated to the series
        _fundBook(false, 500_000e6);

        vm.prank(allocator);
        address seriesAddr = core.openSeries(_defaultParams(_idsOf(marketId), 1_000_000e6), 800_000e6, 200_000e6);
        _fillAndFinalize(seriesAddr, 1_000_000e6);

        Series series = Series(seriesAddr);
        uint256 seniorClaim = series.seniorClaim();

        vm.warp(maturity + 1);
        series.startSettlement();
        // nobody repays -> write off after the delay -> senior collects nothing, fully impaired
        vm.warp(maturity + series.D_WRITE_OFF() + 1);
        series.writeOff();

        assertLt(core.backstopPaid(seriesAddr), seniorClaim + 1); // sanity: some bound exists
        assertGt(core.backstopPaid(seriesAddr), 0, "backstop must have topped up senior from junior's idle cash");

        // senior book had 2_000_000e6 - 800_000e6 = 1_200_000e6 idle right after opening; backstop must have
        // topped it up further from junior's idle cash.
        (uint256 sSh,,) = core.senior();
        assertGt(sSh, 1_200_000e6, "senior book must have received the backstop transfer");
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

        Series series = Series(seriesAddr);
        vm.warp(maturity + 1);
        series.startSettlement();
        vm.warp(maturity + series.D_WRITE_OFF() + 1);
        series.writeOff();

        assertEq(core.backstopPaid(seriesAddr), 0, "backstop must not fire once disabled");
    }

    // --- with backstop off, a loss in one series never changes another series' legs ---------------------------

    function test_lossIsolatedAcrossSeries_whenBackstopOff() public {
        vm.prank(curator);
        core.disableBackstop();

        // opens two series with overlapping maturities, so plenty of headroom is needed against both the
        // per-series idle floors and the 30-day maturity window cap (default 50% of total AUM).
        _fundBook(true, 4_000_000e6);
        _fundBook(false, 1_000_000e6);

        vm.startPrank(governance);
        factory.proposeCollateralAllowed(wbtc, true);
        factory.proposeOracleAllowed(wbtc, address(wbtcOracle), true);
        vm.stopPrank();
        vm.warp(block.timestamp + 48 hours);
        factory.executeCollateralAllowed(wbtc, true);
        factory.executeOracleAllowed(wbtc, address(wbtcOracle), true);

        // fresh, generously-spaced maturities computed post-warp so MIN_TERM headroom is never tight.
        uint256 maturityA = block.timestamp + 40 days;
        uint256 maturityB = maturityA + 5 days;
        bytes32 marketIdA = _touch(_cbBtcMarket(maturityA, LLTV_77));
        bytes32 marketIdB = _touch(_wbtcMarket(maturityB, LLTV_77));

        vm.prank(allocator);
        address seriesA = core.openSeries(_defaultParams(_idsOf(marketIdA), 1_000_000e6), 800_000e6, 200_000e6);
        vm.prank(allocator);
        address seriesB = core.openSeries(_defaultParams(_idsOf(marketIdB), 1_000_000e6), 800_000e6, 200_000e6);

        _fillAndFinalizeMarket(seriesA, 1_000_000e6, _cbBtcMarket(maturityA, LLTV_77));
        // seriesB never gets filled/finalized; seriesA is impaired via write-off while B just sits DEPLOYING

        uint256 bSeniorBefore = Series(seriesB).seniorAllocated();
        uint256 bJuniorBefore = Series(seriesB).juniorAllocated();

        Series a = Series(seriesA);
        vm.warp(maturityA + 1);
        a.startSettlement();
        vm.warp(maturityA + a.D_WRITE_OFF() + 1);
        a.writeOff();

        assertEq(Series(seriesB).seniorAllocated(), bSeniorBefore, "series B's senior leg must be untouched");
        assertEq(Series(seriesB).juniorAllocated(), bJuniorBefore, "series B's junior leg must be untouched");
        assertEq(uint8(Series(seriesB).state()), uint8(SeriesState.DEPLOYING), "series B's state must be untouched");
    }

    // --- registry bounds ---------------------------------------------------------------------------------------

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
        vm.expectRevert(SeriesCore.MaxSeriesExceeded.selector);
        core.openSeries(_defaultParams(_idsOf(marketId2), 1_000_000e6), 800_000e6, 200_000e6);
    }

    // --- views -----------------------------------------------------------------------------------------------

    function test_seniorCapacity_scalesWithJuniorAssets() public {
        _fundBook(false, 200_000e6);
        // covVaultWad default 0.20 -> capacity = juniorAssets * 0.8/0.2 = juniorAssets * 4
        assertEq(core.seniorCapacity(), 800_000e6);
    }

    function test_idleAvailable_subtractsFloor() public {
        _fundBook(true, 1_000_000e6);
        // minIdleSeniorWad default 0.05 -> floor = 50_000e6, all of it idle (no series open)
        assertEq(core.idleAvailable(true), 950_000e6);
    }

    function test_stressGateOpen_trueWithNoLiveSeries() public view {
        assertTrue(core.stressGateOpen());
    }

    // --- curator policy timelock -----------------------------------------------------------------------------

    function test_policyChange_requiresTimelock() public {
        vm.prank(curator);
        core.proposePolicyChange(keccak256("thetaWad"), 0.15e18);

        vm.expectRevert(SeriesCore.TimelockNotElapsed.selector);
        core.executePolicyChange(keccak256("thetaWad"));

        vm.warp(block.timestamp + 3 days);
        core.executePolicyChange(keccak256("thetaWad"));

        (,,,,,,, uint256 thetaWad,,,,,,,,,,,) = core.policy();
        assertEq(thetaWad, 0.15e18);
    }

    function test_sentinel_canOnlyLowerAMaxWad() public {
        vm.prank(sentinel);
        vm.expectRevert(SeriesCore.TimelockIsRiskDecreasing.selector);
        core.lowerAMaxWad(0.4e18); // raising is not allowed via the sentinel fast path
    }

    function test_sentinel_canPause() public {
        vm.prank(sentinel);
        core.pause();
        assertTrue(core.paused());
    }
}
