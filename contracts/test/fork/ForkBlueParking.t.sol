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

contract ForkBlueParkingTest is ForkBase {
    using SharesMathLib for uint256;

    address internal constant BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    bytes32 internal constant CBBTC_USDC_86 = 0x9103c3b4e834476c9a62ea009ba2c884ee42e94e6e314a26f04d312434191836;

    blueParking internal blueAdapter;
    MarketParams internal params;
    address internal borrower = makeAddr("borrower");

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
}
