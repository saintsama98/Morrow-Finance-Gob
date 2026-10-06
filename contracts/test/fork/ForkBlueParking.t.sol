// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: one full series lifecycle on a Base fork with idle cash lent in the real Blue cbBTC/USDC 0.86 market.
// @author adiii.eth

pragma solidity 0.8.34;

import {console} from "forge-std/console.sol";
import {IMorpho, MarketParams, Market as BlueMarket, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@morpho-org/morpho-blue/src/libraries/SharesMathLib.sol";
import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {seriesFactory} from "../../src/series/seriesFactory.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {seriesCore} from "../../src/core/seriesCore.sol";
import {usdcSeniorVault} from "../../src/vaults/senior/usdcSeniorVault.sol";
import {usdcJuniorVault} from "../../src/vaults/junior/usdcJuniorVault.sol";
import {blueParking} from "../../src/parking/blueParking.sol";
import {iMidnightMinimal} from "../../src/interfaces/iMidnightMinimal.sol";
import {iErc20Like} from "../../src/interfaces/iErc20Like.sol";

interface iBlueOracle {
    function price() external view returns (uint256);
}

contract ForkBlueParkingTest is ForkBase {
    using SharesMathLib for uint256;

    address internal constant BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    bytes32 internal constant CBBTC_USDC_86 = 0x9103c3b4e834476c9a62ea009ba2c884ee42e94e6e314a26f04d312434191836;

    blueParking internal blueAdapter;
    MarketParams internal params;
    address internal borrower = makeAddr("borrower");
    address internal squeezer = makeAddr("squeezer");
    address internal victim = makeAddr("victim");
    address internal blueLiquidator = makeAddr("blueLiquidator");

    function setUp() public override {
        string memory url = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, _pinnedBlock());
        forkStartTs = block.timestamp;

        factory = new seriesFactory(iMidnightMinimal(MIDNIGHT), SETTER_RATIFIER, USDC, address(this), _maxLltv(), 4);
        factory.proposeCollateralAllowed(CBBTC, true);
        factory.proposeOracleAllowed(CBBTC, CBBTC_ORACLE, true);
        vm.warp(block.timestamp + 48 hours);
        factory.executeCollateralAllowed(CBBTC, true);
        factory.executeOracleAllowed(CBBTC, CBBTC_ORACLE, true);

        params = IMorpho(BLUE).idToMarketParams(Id.wrap(CBBTC_USDC_86));
        blueAdapter = new blueParking(USDC, BLUE, address(factory), params, 0.05e18);
        parking = blueAdapter;

        core = new seriesCore(USDC, factory, parking, GOVERNANCE, ALLOCATOR, CURATOR, SENTINEL);
        factory.setCore(address(core));
        seniorVault = new usdcSeniorVault(core, USDC);
        juniorVault = new usdcJuniorVault(core, USDC);
        vm.startPrank(GOVERNANCE);
        core.setVaults(address(seniorVault), address(juniorVault));
        core.setFeeRecipient(FEE_RECIPIENT);
        vm.stopPrank();
    }

    function _fund(address token, address to, uint256 amount) internal override {
        deal(token, to, iErc20Like(token).balanceOf(to) + amount);
    }

    function _assertValuationMatchesBlue(string memory when) internal {
        uint256 viewValue = blueAdapter.blueAssets();
        IMorpho(BLUE).accrueInterest(params);
        BlueMarket memory m = IMorpho(BLUE).market(Id.wrap(CBBTC_USDC_86));
        uint256 realValue = blueAdapter.blueShares().toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
        assertEq(viewValue, realValue, when);
    }

    function _exitInRounds(bool isSenior, uint256 shares) internal returns (uint256 paid) {
        address who = isSenior ? alice : juniorLender;
        uint256 id;
        vm.prank(who);
        id = isSenior ? seniorVault.requestRedeem(shares, who, who) : juniorVault.requestRedeem(shares, who, who);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(keeper);
        if (isSenior) seniorVault.closeEpoch();
        else juniorVault.closeRedeemEpoch();
        vm.warp(vm.getBlockTimestamp() + 3 days);
        for (uint256 round = 0; round < 4; round++) {
            vm.prank(keeper);
            if (isSenior) seniorVault.fulfill(id, type(uint128).max);
            else juniorVault.fulfillRedeem(id, type(uint128).max);
            uint256 claimable =
                isSenior ? seniorVault.claimableRedeemRequest(id, who) : juniorVault.claimableRedeemRequest(id, who);
            if (claimable > 0) {
                vm.prank(who);
                paid += isSenior ? seniorVault.redeem(claimable, who, who) : juniorVault.redeem(claimable, who, who);
            }
            uint256 pending =
                isSenior ? seniorVault.pendingRedeemRequest(id, who) : juniorVault.pendingRedeemRequest(id, who);
            if (pending == 0) break;
            vm.warp(vm.getBlockTimestamp() + 1 days);
        }
    }

    function test_marketMatchesTheSeriesMarkets() public view {
        assertEq(params.loanToken, USDC);
        assertEq(params.collateralToken, CBBTC);
        assertEq(params.oracle, CBBTC_ORACLE, "same oracle contract as the Midnight cbBTC series markets");
        assertEq(params.lltv, 0.86e18, "same threshold");
    }

    function test_fullLifecycle_fillsFundedFromBlue_settlesAndExitsFromBlue() public {
        _fundBooks(1_500_000e6, 500_000e6);
        uint256 idleTotal = core.idle(true) + core.idle(false);
        assertApproxEqAbs(blueAdapter.blueAssets(), idleTotal * 95 / 100, 2, "95% of idle is lent in Blue");
        _assertValuationMatchesBlue("valuation equals Blue after deposit");

        Market memory market = _cbMarket(0.86e18, DEC_25, 3_000_000_001);
        (creditSeries series, bytes32 id) = _openSingle(market, 400_000e6, 100_000e6);

        uint256 sharesBefore = blueAdapter.blueShares();
        uint256 units = 300_000e6;
        _postCollateral(borrower, market, 0, _collateralFor(market, 0, units, 80));
        uint256 g = gasleft();
        _take(series, 0, market, units, borrower);
        uint256 gasUsed = g - gasleft();
        console.log("register + take gas, fill funded from Blue:", gasUsed);
        assertLt(blueAdapter.blueShares(), sharesBefore, "the fill pulled cash out of Blue just in time");
        assertEq(series.unitsBought(0), units, "the series bought exactly the units");
        _assertValuationMatchesBlue("valuation equals Blue after the fill");

        _finalizeByKeeper(series);
        vm.warp(vm.getBlockTimestamp() + 20 days);
        _assertValuationMatchesBlue("valuation equals Blue after 20 days of accrual");
        assertGt(blueAdapter.poolAssets(), 0);

        _toSettling(series);
        vm.warp(vm.getBlockTimestamp() + 1);
        _repayAll(market, id, borrower);
        _collectAll(series);
        vm.prank(keeper);
        series.settle();
        assertGe(series.paidS(), series.seniorClaim(), "senior paid in full");
        _checkStructure();

        uint256 paidSenior = _exitInRounds(true, seniorVault.balanceOf(alice));
        uint256 paidJunior = _exitInRounds(false, juniorVault.balanceOf(juniorLender));
        console.log("senior paid / junior paid over up to four fill rounds:", paidSenior, paidJunior);
        assertGt(paidSenior, 1_500_000e6, "senior exits with yield, paid out of Blue");
        assertGt(paidJunior, 490_000e6, "junior exits with its share, paid out of Blue");
        _assertValuationMatchesBlue("valuation equals Blue after exits");
    }

    function test_exitToCash_onRealBlue_returnsEverythingLiquid() public {
        _fundBooks(1_500_000e6, 500_000e6);
        uint256 pool = blueAdapter.poolAssets();
        vm.prank(SENTINEL);
        blueAdapter.exitToCash();
        assertEq(blueAdapter.blueShares(), 0);
        assertApproxEqAbs(iErc20Like(USDC).balanceOf(address(blueAdapter)), pool, 1);
        _checkStructure();
    }

    function takeExt(creditSeries series, Market memory market, uint256 units, address who) external {
        _take(series, 0, market, units, who);
    }

    function _blueFree() internal returns (uint256) {
        IMorpho(BLUE).accrueInterest(params);
        BlueMarket memory m = IMorpho(BLUE).market(Id.wrap(CBBTC_USDC_86));
        return m.totalSupplyAssets - m.totalBorrowAssets;
    }

    function _openBlueBorrow(address who, uint256 assets, uint256 headroomPct) internal {
        uint256 price = iBlueOracle(params.oracle).price();
        uint256 collateral = assets * 1e36 / price * 1e18 / params.lltv * headroomPct / 100 + 1;
        deal(CBBTC, who, collateral);
        vm.startPrank(who);
        iErc20Like(CBBTC).approve(BLUE, collateral);
        IMorpho(BLUE).supplyCollateral(params, collateral, who, "");
        IMorpho(BLUE).borrow(params, assets, 0, who, who);
        vm.stopPrank();
    }

    function _squeeze() internal {
        _openBlueBorrow(squeezer, _blueFree(), 130);
        assertEq(_blueFree(), 0, "every free dollar in the Blue market is borrowed");
    }

    function _release() internal {
        IMorpho(BLUE).accrueInterest(params);
        uint256 shares = IMorpho(BLUE).position(Id.wrap(CBBTC_USDC_86), squeezer).borrowShares;
        BlueMarket memory m = IMorpho(BLUE).market(Id.wrap(CBBTC_USDC_86));
        uint256 owed = shares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
        deal(USDC, squeezer, owed + 1);
        vm.startPrank(squeezer);
        iErc20Like(USDC).approve(BLUE, owed + 1);
        IMorpho(BLUE).repay(params, 0, shares, squeezer, "");
        vm.stopPrank();
        assertGt(_blueFree(), 1_000_000e6, "liquidity is back after the repayment");
    }

    function test_fullyUtilizedBlue_fillsAndExitsWaitWithoutBreaking() public {
        _fundBooks(1_500_000e6, 500_000e6);
        Market memory market = _cbMarket(0.86e18, DEC_25, 3_000_000_001);
        (creditSeries series,) = _openSingle(market, 400_000e6, 100_000e6);
        _postCollateral(borrower, market, 0, _collateralFor(market, 0, 400_000e6, 80));

        _squeeze();
        uint256 raw = iErc20Like(USDC).balanceOf(address(blueAdapter));
        assertEq(core.parkingLiquidity() <= raw, true, "only the raw slice is withdrawable");
        assertGt(raw, 50_000e6, "the raw slice survives the squeeze");

        uint256 sharesBefore = blueAdapter.blueShares();
        try this.takeExt(series, market, 300_000e6, borrower) {
            revert("a fill larger than the raw slice must not go through");
        } catch (bytes memory err) {
            assertEq(bytes4(err), blueParking.Illiquid.selector, "the fill was refused for lack of Blue liquidity");
        }
        assertEq(series.totalFilled(), 0, "the failed fill left nothing behind");
        assertEq(blueAdapter.blueShares(), sharesBefore, "the Blue position is untouched");
        _checkStructure();

        _take(series, 0, market, 40_000e6, borrower);
        assertGt(series.totalFilled(), 0, "a fill inside the raw slice still goes through");
        assertEq(blueAdapter.blueShares(), sharesBefore, "it was served without touching Blue");
        console.log("squeeze: filled from the raw slice:", series.totalFilled() / 1e6);

        _release();
        _take(series, 0, market, 300_000e6, borrower);
        assertLt(blueAdapter.blueShares(), sharesBefore, "after the repayment the large fill is funded from Blue");
        _checkStructure();

        _squeeze();
        uint256 shares = seniorVault.balanceOf(alice) / 2;
        vm.prank(alice);
        uint256 rid = seniorVault.requestRedeem(shares, alice, alice);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(keeper);
        seniorVault.closeEpoch();
        vm.warp(vm.getBlockTimestamp() + 3 days);
        uint256 liquidNow = core.parkingLiquidity();
        vm.prank(keeper);
        seniorVault.fulfill(rid, type(uint128).max);
        uint256 claimable1 = seniorVault.claimableRedeemRequest(rid, alice);
        uint256 pending1 = seniorVault.pendingRedeemRequest(rid, alice);
        console.log(
            "squeeze: withdrawable / exit shares claimable / still queued:", liquidNow / 1e6, claimable1, pending1
        );
        assertGt(pending1, 0, "the exit is only partly paid while Blue is fully borrowed");
        uint256 paid1;
        if (claimable1 > 0) {
            vm.prank(alice);
            paid1 = seniorVault.redeem(claimable1, alice, alice);
        }
        assertLe(paid1, liquidNow + 1, "nothing beyond what was withdrawable was paid");
        _checkStructure();

        _release();
        vm.prank(keeper);
        seniorVault.fulfill(rid, type(uint128).max);
        assertEq(seniorVault.pendingRedeemRequest(rid, alice), 0, "the rest of the exit is paid once liquidity returns");
        uint256 claimable2 = seniorVault.claimableRedeemRequest(rid, alice);
        vm.prank(alice);
        uint256 paid2 = seniorVault.redeem(claimable2, alice, alice);
        console.log("squeeze: exit paid before / after the repayment:", paid1 / 1e6, paid2 / 1e6);
        assertGt(claimable1, 0, "the raw slice paid part of the exit during the squeeze");
        assertApproxEqRel(
            paid1 * 1e18 / claimable1, paid2 * 1e18 / claimable2, 0.001e18, "both parts of the exit paid the same price"
        );
        _checkStructure();
    }

    function test_exitToCash_duringASqueeze_takesWhatIsLiquidAndStaysSolvent() public {
        _fundBooks(1_500_000e6, 500_000e6);
        _squeeze();
        uint256 pool = blueAdapter.poolAssets();
        uint256 sharesBefore = blueAdapter.blueShares();
        vm.prank(SENTINEL);
        blueAdapter.exitToCash();
        assertEq(blueAdapter.blueShares(), sharesBefore, "nothing could leave Blue while it is fully borrowed");
        assertApproxEqAbs(blueAdapter.poolAssets(), pool, 1, "the pool keeps its value");
        _release();
        vm.prank(SENTINEL);
        blueAdapter.exitToCash();
        assertEq(blueAdapter.blueShares(), 0, "a second call completes the exit once liquidity returns");
        _checkStructure();
    }

    function test_realBlueBadDebt_lossLandsOnJuniorIdleFirst() public {
        _fundBooks(1_500_000e6, 500_000e6);
        core.syncAll();
        uint256 seniorBefore = core.idle(true);
        uint256 juniorBefore = core.idle(false);
        BlueMarket memory m0 = IMorpho(BLUE).market(Id.wrap(CBBTC_USDC_86));

        uint256 size = _blueFree() * 8 / 10;
        if (size > 100_000_000e6) size = 100_000_000e6;
        _openBlueBorrow(victim, size, 105);
        uint256 collateral = IMorpho(BLUE).position(Id.wrap(CBBTC_USDC_86), victim).collateral;

        uint256 price = iBlueOracle(params.oracle).price();
        vm.mockCall(params.oracle, abi.encodeWithSelector(iBlueOracle.price.selector), abi.encode(price * 4 / 10));
        deal(USDC, blueLiquidator, size);
        vm.startPrank(blueLiquidator);
        iErc20Like(USDC).approve(BLUE, size);
        IMorpho(BLUE).liquidate(params, victim, collateral, 0, "");
        vm.stopPrank();
        vm.clearMockedCalls();

        BlueMarket memory m1 = IMorpho(BLUE).market(Id.wrap(CBBTC_USDC_86));
        assertLt(uint256(m1.totalSupplyAssets), uint256(m0.totalSupplyAssets), "the Blue market realized bad debt");
        uint256 seniorView = core.idle(true);
        core.syncAll();
        uint256 seniorAfter = core.idle(true);
        uint256 juniorAfter = core.idle(false);
        uint256 loss = seniorBefore + juniorBefore - seniorAfter - juniorAfter;
        console.log("Blue bad debt realized (USDC):", (m0.totalSupplyAssets - m1.totalSupplyAssets) / 1e6);
        console.log("Morrow parking loss / junior idle drop:", loss / 1e6, (juniorBefore - juniorAfter) / 1e6);
        assertGt(loss, 1_000e6, "Morrow's parked cash took a real share of the loss");
        assertGe(seniorView + 2, seniorBefore, "views already keep senior whole before any sync");
        assertGe(seniorAfter + 2, seniorBefore, "senior idle is unchanged while junior idle covers the loss");
        assertApproxEqAbs(juniorBefore - juniorAfter, loss, 2, "junior idle absorbed the whole loss");
        _checkStructure();
    }
}
