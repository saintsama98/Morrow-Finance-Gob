// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: fork tests f0 to f7 against the live Base deployment of Midnight, USDC, cbBTC and its oracle.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IMidnight, Market, CollateralParams, Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {HashLib} from "@morpho-org/midnight/src/ratifiers/libraries/HashLib.sol";
import {TickLib} from "@morpho-org/midnight/src/libraries/TickLib.sol";
import {IdLib} from "@morpho-org/midnight/src/libraries/IdLib.sol";
import {ORACLE_PRICE_SCALE} from "@morpho-org/midnight/src/libraries/ConstantsLib.sol";

import {seriesFactory} from "../../src/series/seriesFactory.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {seriesCore} from "../../src/core/seriesCore.sol";
import {usdcSeniorVault} from "../../src/vaults/senior/usdcSeniorVault.sol";
import {usdcJuniorVault} from "../../src/vaults/junior/usdcJuniorVault.sol";
import {idleParking} from "../../src/parking/idleParking.sol";
import {iParking} from "../../src/parking/iParking.sol";
import {iMidnightMinimal} from "../../src/interfaces/iMidnightMinimal.sol";
import {iErc20Like} from "../../src/interfaces/iErc20Like.sol";
import {SeriesParams, SeriesState} from "../../src/interfaces/iSeries.sol";
import {wadMath} from "../../src/libraries/wadMath.sol";

interface iOracleLike {
    function price() external view returns (uint256);
}

interface iSetterRatifierLike {
    function MIDNIGHT() external view returns (address);
}

contract BaseForkTest is Test {
    using wadMath for uint256;

    uint256 internal constant PINNED_BLOCK = 51_894_109;
    uint256 internal constant WAD = 1e18;

    address internal constant MIDNIGHT = 0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A;
    address internal constant SETTER_RATIFIER = 0x800B5F12A61B8198a5a6EfD794Cac6699B294d63;
    address internal constant MEMPOOL = 0xdD6DCE32e21f7b020898a8258dA37355b4017993;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant CBBTC_ORACLE = 0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9;
    address internal constant FUNDER = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    bytes32 internal constant SETTER_RATIFIER_CODEHASH =
        0xace63c5b7c1b611d0b9c04df3993ce0cf24a172287c9e0755d18606b7465c235;
    bytes32 internal constant MEMPOOL_CODEHASH = 0x10c5904c8955f602f39bbb0789f9c63aaf9951fe816e45885f47deda07b800a0;
    bytes32 internal constant MIDNIGHT_CODEHASH = 0x94dfc372cddf727c3cb9649ffab79f400260e1f50c380324e4ad0cf5ab29d9a7;

    bytes32 internal constant LIVE_CBBTC_PLUS_USDC_MARKET =
        0xbd3e8c4ced238ebacc578c3460fdacf8ecc092449ce758ae1feff17a06cde6e7;
    bytes32 internal constant LIVE_EQUITY_PLUS_USDC_MARKET =
        0xc98539e9109a772a49b5bcaa8cb4cb06b4fc676fa6b0150292598dee08cd4665;
    bytes32 internal constant LIVE_WETH_MARKET = 0xc329dc6bf63e1cdf0f9e6d7a03dcbce3fa1828fb2814b4a1bc74655502fe25b3;

    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant CURSOR = 0.3e18;
    uint256 internal constant RCF_THRESHOLD = 3_000_000_000;

    address internal constant GOVERNANCE = address(0x60F);
    address internal constant ALLOCATOR = address(0xA110C000);
    address internal constant CURATOR = address(0xCADA702);
    address internal constant SENTINEL = address(0xC0FFEE);
    address internal constant FEE_RECIPIENT = address(0xFEE);

    IMidnight internal midnight = IMidnight(MIDNIGHT);
    seriesFactory internal factory;
    seriesCore internal core;
    usdcSeniorVault internal seniorVault;
    usdcJuniorVault internal juniorVault;

    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal juniorLender = makeAddr("juniorLender");
    address internal borrower = makeAddr("borrower");

    function setUp() public {
        string memory url = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, PINNED_BLOCK);

        factory = new seriesFactory(iMidnightMinimal(MIDNIGHT), SETTER_RATIFIER, USDC, address(this), LLTV, 4);
        iParking parking = new idleParking(USDC);
        core = new seriesCore(USDC, factory, parking, GOVERNANCE, ALLOCATOR, CURATOR, SENTINEL);
        factory.setCore(address(core));
        seniorVault = new usdcSeniorVault(core, USDC);
        juniorVault = new usdcJuniorVault(core, USDC);
        vm.startPrank(GOVERNANCE);
        core.setVaults(address(seniorVault), address(juniorVault));
        core.setFeeRecipient(FEE_RECIPIENT);
        vm.stopPrank();

        factory.proposeCollateralAllowed(CBBTC, true);
        factory.proposeOracleAllowed(CBBTC, CBBTC_ORACLE, true);
        vm.warp(block.timestamp + 48 hours);
        factory.executeCollateralAllowed(CBBTC, true);
        factory.executeOracleAllowed(CBBTC, CBBTC_ORACLE, true);
    }

    function _fund(address token, address to, uint256 amount) internal {
        vm.prank(FUNDER);
        require(iErc20Like(token).transfer(to, amount), "fund failed");
    }

    function _market(uint256 maturity) internal pure returns (Market memory market) {
        CollateralParams[] memory params = new CollateralParams[](1);
        params[0] = CollateralParams({token: CBBTC, lltv: LLTV, liquidationCursor: CURSOR, oracle: CBBTC_ORACLE});
        market = Market({
            chainId: 8453,
            midnight: MIDNIGHT,
            loanToken: USDC,
            collateralParams: params,
            maturity: maturity,
            rcfThreshold: RCF_THRESHOLD,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function _fundBooks(uint256 seniorAssets, uint256 juniorAssets) internal {
        _fund(USDC, juniorLender, juniorAssets);
        vm.startPrank(juniorLender);
        iErc20Like(USDC).approve(address(juniorVault), juniorAssets);
        uint256 epochId = juniorVault.requestDeposit(juniorAssets, juniorLender, juniorLender);
        vm.stopPrank();
        vm.startPrank(CURATOR);
        juniorVault.closeDepositEpoch();
        juniorVault.fulfillDeposit(epochId, juniorAssets);
        vm.stopPrank();
        vm.prank(juniorLender);
        juniorVault.claimDeposit(epochId);

        _fund(USDC, alice, seniorAssets);
        vm.startPrank(alice);
        iErc20Like(USDC).approve(address(seniorVault), seniorAssets);
        seniorVault.deposit(seniorAssets, alice);
        vm.stopPrank();
    }

    function _openSeries(uint256 S, uint256 J, uint256 maturity) internal returns (creditSeries series, bytes32 id) {
        Market memory market = _market(maturity);
        id = midnight.touchMarket(market);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory floors = new uint256[](1);
        floors[0] = 0.005e18;
        uint256[] memory caps = new uint256[](1);
        caps[0] = S + J;
        (uint256 covWad,,,, uint256 pi0, uint256 piT, uint256 pi1, uint256 theta,,,,,,,,,,,) = core.policy();

        SeriesParams memory p = SeriesParams({
            marketIds: ids,
            tDeployEnd: uint64(block.timestamp + 2 days),
            dWriteOff: uint64(7 days),
            covWad: covWad,
            pi0Wad: pi0,
            piTWad: piT,
            pi1Wad: pi1,
            rateFloorWad: floors,
            marketCapAssets: caps,
            kMinAssets: 50_000e6,
            thetaWad: theta,
            feeRecipient: FEE_RECIPIENT,
            allocator: ALLOCATOR,
            parking: core.PARKING(),
            offchainAttestationHash: bytes32(0)
        });
        vm.prank(ALLOCATOR);
        series = creditSeries(core.openSeries(p, S, J));
    }

    function _makerFill(creditSeries series, uint256 maturity, uint256 units) internal {
        uint256 tick = series.tickMaxFor(0);
        uint256 price = TickLib.tickToPrice(tick);

        Offer memory offer;
        offer.market = _market(maturity);
        offer.buy = true;
        offer.maker = address(series);
        offer.expiry = series.T_DEPLOY_END();
        offer.tick = tick;
        offer.group = keccak256(abi.encode("fork-group", address(series), units));
        offer.callback = address(series);
        offer.callbackData = abi.encode(uint256(0));
        offer.ratifier = SETTER_RATIFIER;
        offer.maxAssets = uint128(units.mulDivUp(price, WAD) + 1000e6);
        offer.continuousFeeCap = type(uint256).max;

        Offer[] memory leaves = new Offer[](1);
        leaves[0] = offer;
        bytes32 root = HashLib.hashOffer(offer);
        vm.prank(ALLOCATOR);
        series.registerOffers(root, leaves);

        uint256 oraclePrice = iOracleLike(CBBTC_ORACLE).price();
        uint256 collateral = units.mulDivUp(WAD, LLTV).mulDivUp(ORACLE_PRICE_SCALE, oraclePrice) * 12 / 10;
        _fund(CBBTC, borrower, collateral);
        vm.startPrank(borrower);
        iErc20Like(CBBTC).approve(MIDNIGHT, collateral);
        midnight.supplyCollateral(offer.market, 0, collateral, borrower);
        midnight.take(offer, abi.encode(root, uint256(0), new bytes32[](0)), units, borrower, borrower, address(0), "");
        vm.stopPrank();
    }

    function _toSettling(creditSeries series, uint256 maturity) internal {
        vm.warp(uint256(series.T_DEPLOY_END()) + 1);
        vm.prank(keeper);
        series.finalize();
        vm.warp(maturity);
        vm.prank(keeper);
        series.startSettlement();
    }

    function _repayAll(bytes32 id, uint256 maturity) internal {
        uint256 debt = midnight.debt(id, borrower);
        _fund(USDC, borrower, debt);
        vm.startPrank(borrower);
        iErc20Like(USDC).approve(MIDNIGHT, debt);
        midnight.repay(_market(maturity), debt, borrower, address(0), "");
        vm.stopPrank();
    }

    function _seniorExit(uint256 shares) internal returns (uint256 paid) {
        vm.prank(alice);
        uint256 id = seniorVault.requestRedeem(shares, alice, alice);
        vm.warp(block.timestamp + seniorVault.MAX_EPOCH_DURATION());
        vm.prank(keeper);
        seniorVault.closeEpoch();
        vm.warp(block.timestamp + seniorVault.FILL_GRACE());
        vm.prank(keeper);
        seniorVault.fulfill(id, type(uint128).max);
        uint256 claimable = seniorVault.claimableRedeemRequest(id, alice);
        vm.prank(alice);
        paid = seniorVault.redeem(claimable, alice, alice);
    }

    function test_f0_pinnedDeploymentsAreTheOnesVerified() public view {
        assertEq(SETTER_RATIFIER.codehash, SETTER_RATIFIER_CODEHASH, "f0: setter ratifier bytecode changed");
        assertEq(MEMPOOL.codehash, MEMPOOL_CODEHASH, "f0: mempool bytecode changed");
        assertEq(MIDNIGHT.codehash, MIDNIGHT_CODEHASH, "f0: midnight bytecode changed");
        assertEq(iSetterRatifierLike(SETTER_RATIFIER).MIDNIGHT(), MIDNIGHT, "f0: ratifier must point at midnight");
        assertTrue(midnight.isLltvEnabled(LLTV), "f0: lltv 0.86 must be enabled");
        assertTrue(midnight.isLiquidationCursorEnabled(CURSOR), "f0: cursor 0.3 must be enabled");
        assertEq(midnight.defaultContinuousFee(USDC), 0, "f0: default usdc continuous fee as recorded");
    }

    function test_f1_openSeriesOnRealMidnight_andLiveMarketsAreIneligible() public {
        _fundBooks(1_000_000e6, 400_000e6);
        uint256 maturity = block.timestamp + 45 days;
        (creditSeries series, bytes32 id) = _openSeries(400_000e6, 100_000e6, maturity);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        Market[] memory read = factory.checkEligibility(ids);
        assertEq(read[0].maturity, maturity, "f1: eligibility reads the real market");
        assertEq(read[0].collateralParams[0].token, CBBTC, "f1: collateral read back from midnight");
        assertEq(series.marketIds()[0], id, "f1: series bound to the real market id");
        assertEq(uint8(series.state()), uint8(SeriesState.DEPLOYING));
        assertTrue(midnight.isAuthorized(address(series), SETTER_RATIFIER), "f1: series authorized the ratifier");

        bytes32[3] memory live = [LIVE_CBBTC_PLUS_USDC_MARKET, LIVE_EQUITY_PLUS_USDC_MARKET, LIVE_WETH_MARKET];
        for (uint256 k = 0; k < live.length; k++) {
            ids[0] = live[k];
            vm.expectPartialRevert(seriesFactory.IneligibleMarket.selector);
            factory.checkEligibility(ids);
        }
    }

    function test_f2_makerPath_realBorrowerTakesTheSeriesBid() public {
        _fundBooks(1_000_000e6, 400_000e6);
        uint256 maturity = block.timestamp + 45 days;
        (creditSeries series, bytes32 id) = _openSeries(400_000e6, 100_000e6, maturity);
        _makerFill(series, maturity, 300_000e6);

        assertEq(series.unitsBought(0), 300_000e6, "f2: fill recorded inside onBuy from midnight's units");
        assertEq(midnight.credit(id, address(series)), 300_000e6, "f2: series credit on the real midnight");
        assertEq(midnight.debt(id, address(series)), 0, "f2: series never borrows");
        assertEq(midnight.debt(id, borrower), 300_000e6, "f2: borrower owes the units");
        assertGt(series.totalFilled(), 0, "f2: usdc was spent through the callback");
    }

    function test_f3_takerPath_skippedWithoutARealAsk() public {
        emit log_string("f3: skipped, no borrower ask exists on an eligible market at the pinned block");
        vm.skip(true);
    }

    function test_f4_repaidMaturity_settlesAndPaysASeniorExit() public {
        _fundBooks(1_000_000e6, 400_000e6);
        uint256 maturity = block.timestamp + 45 days;
        (creditSeries series, bytes32 id) = _openSeries(400_000e6, 100_000e6, maturity);
        _makerFill(series, maturity, 300_000e6);
        _toSettling(series, maturity);

        _repayAll(id, maturity);
        vm.warp(maturity + 1);
        vm.prank(keeper);
        series.collect(0);
        vm.prank(keeper);
        series.settle();

        assertEq(uint8(series.state()), uint8(SeriesState.SETTLED), "f4: settled after full repayment");
        assertEq(series.paidS(), series.seniorClaim(), "f4: senior paid its full claim");
        assertEq(core.liveSeriesCount(), 0, "f4: settled series left the live set");

        uint256 paid = _seniorExit(seniorVault.balanceOf(alice) / 2);
        assertGt(paid, 500_000e6, "f4: a senior exit pays principal plus accrued yield");
    }

    function test_f5_unrepaidMaturity_overdueLiquidationThenSettle() public {
        _fundBooks(1_000_000e6, 400_000e6);
        uint256 maturity = block.timestamp + 45 days;
        (creditSeries series, bytes32 id) = _openSeries(400_000e6, 100_000e6, maturity);
        _makerFill(series, maturity, 300_000e6);
        _toSettling(series, maturity);

        vm.warp(maturity + 1 hours);
        uint256 debt = midnight.debt(id, borrower);
        _fund(USDC, keeper, debt);
        vm.startPrank(keeper);
        iErc20Like(USDC).approve(MIDNIGHT, debt);
        midnight.liquidate(_market(maturity), 0, 0, debt, borrower, true, keeper, address(0), "");
        series.collect(0);
        series.settle();
        vm.stopPrank();

        assertEq(midnight.debt(id, borrower), 0, "f5: overdue auction cleared the debt");
        assertEq(uint8(series.state()), uint8(SeriesState.SETTLED), "f5: settled after liquidation");
        assertGt(iErc20Like(CBBTC).balanceOf(keeper), 0, "f5: the keeper received seized collateral");
        assertEq(series.paidS(), series.seniorClaim(), "f5: a fully covered liquidation keeps senior whole");
    }

    function test_f6_badDebtOnRealMidnight_hitsJuniorFirst() public {
        _fundBooks(1_000_000e6, 400_000e6);
        uint256 maturity = block.timestamp + 45 days;
        (creditSeries series, bytes32 id) = _openSeries(400_000e6, 100_000e6, maturity);
        _makerFill(series, maturity, 300_000e6);
        _toSettling(series, maturity);

        uint256 crashed = iOracleLike(CBBTC_ORACLE).price() / 4;
        vm.mockCall(CBBTC_ORACLE, abi.encodeWithSelector(iOracleLike.price.selector), abi.encode(crashed));
        vm.warp(maturity + 1 hours);
        uint256 debt = midnight.debt(id, borrower);
        uint256 posted = midnight.collateral(id, borrower, 0);
        _fund(USDC, keeper, debt);
        vm.startPrank(keeper);
        iErc20Like(USDC).approve(MIDNIGHT, debt);
        midnight.liquidate(_market(maturity), 0, posted, 0, borrower, true, keeper, address(0), "");
        vm.stopPrank();
        (uint128 creditAfterLoss,,) = midnight.updatePositionView(_market(maturity), id, address(series));
        assertLt(creditAfterLoss, 300_000e6, "f6: bad debt was socialised onto the series");

        vm.prank(keeper);
        series.collect(0);
        vm.warp(maturity + series.D_WRITE_OFF());
        vm.startPrank(keeper);
        if (uint8(series.state()) == uint8(SeriesState.SETTLING)) series.writeOff();
        vm.stopPrank();

        assertEq(uint8(series.state()), uint8(SeriesState.SETTLED), "f6: loss series settles");
        assertLt(series.paidJ(), series.juniorDeployed(), "f6: junior absorbs the loss first");
        uint256 claim = series.seniorClaim();
        uint256 proceeds = series.paidS() + series.paidJ() + series.feeAccounted();
        assertEq(series.paidS(), proceeds < claim ? proceeds : claim, "f6: senior is paid first from what came back");
    }

    function test_f7_twoMaturityLadder_settleFirstRollIntoSecond() public {
        _fundBooks(1_000_000e6, 400_000e6);
        uint256 maturityA = block.timestamp + 30 days;
        (creditSeries seriesA, bytes32 idA) = _openSeries(300_000e6, 75_000e6, maturityA);
        _makerFill(seriesA, maturityA, 250_000e6);
        uint256 seniorPpsBefore = seniorVault.pricePerShareWad();
        uint256 juniorPpsBefore = juniorVault.pricePerShareWad();

        _toSettling(seriesA, maturityA);
        _repayAll(idA, maturityA);
        vm.warp(maturityA + 1);
        vm.startPrank(keeper);
        seriesA.collect(0);
        seriesA.settle();
        vm.stopPrank();

        uint256 seniorPpsMid = seniorVault.pricePerShareWad();
        assertGt(seniorPpsMid, seniorPpsBefore, "f7: senior price rises when the first rung pays");
        assertGe(juniorVault.pricePerShareWad(), juniorPpsBefore, "f7: junior keeps at least its value on no loss");

        uint256 maturityB = block.timestamp + 45 days;
        (creditSeries seriesB,) = _openSeries(300_000e6, 75_000e6, maturityB);
        assertEq(core.liveSeriesCount(), 1, "f7: the settled rung left, the new rung is live");
        assertEq(uint8(seriesB.state()), uint8(SeriesState.DEPLOYING), "f7: second rung funded from returned cash");
        assertApproxEqAbs(
            seniorVault.pricePerShareWad(), seniorPpsMid, 1, "f7: opening the next rung does not move the price"
        );
    }
}
