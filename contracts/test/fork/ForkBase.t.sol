// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: shared Base fork harness: real markets by parameter, multi-market series, borrowers, and the
// structural checks every fork scenario runs after each step.
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

interface iPriceOracle {
    function price() external view returns (uint256);
}

interface iChainlinkFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

abstract contract ForkBase is Test {
    using wadMath for uint256;

    uint256 internal constant WAD = 1e18;

    address internal constant MIDNIGHT = 0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A;
    address internal constant SETTER_RATIFIER = 0x800B5F12A61B8198a5a6EfD794Cac6699B294d63;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant CBBTC_ORACLE = 0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9;
    address internal constant WETH_ORACLE = 0xFEa2D58cEfCb9fcb597723c6bAE66fFE4193aFE4;
    address internal constant BTC_USD_FEED = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;
    address internal constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant FUNDER = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    uint256 internal constant CURSOR = 0.3e18;
    uint256 internal constant OCT_30 = 1_793_372_400;
    uint256 internal constant NOV_27 = 1_795_791_600;
    uint256 internal constant DEC_25 = 1_798_210_800;

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
    iParking internal parking;

    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal juniorLender = makeAddr("juniorLender");

    creditSeries[] internal tracked;
    uint256 internal forkStartTs;

    function _pinnedBlock() internal pure virtual returns (uint256) {
        return 51_894_109;
    }

    function _maxLltv() internal pure virtual returns (uint256) {
        return 0.915e18;
    }

    function setUp() public virtual {
        string memory url = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, _pinnedBlock());
        forkStartTs = block.timestamp;

        factory = new seriesFactory(iMidnightMinimal(MIDNIGHT), SETTER_RATIFIER, USDC, address(this), _maxLltv(), 4);
        parking = new idleParking(USDC);
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
        factory.proposeCollateralAllowed(WETH, true);
        factory.proposeOracleAllowed(WETH, WETH_ORACLE, true);
        vm.warp(block.timestamp + 48 hours);
        factory.executeCollateralAllowed(CBBTC, true);
        factory.executeOracleAllowed(CBBTC, CBBTC_ORACLE, true);
        factory.executeCollateralAllowed(WETH, true);
        factory.executeOracleAllowed(WETH, WETH_ORACLE, true);
        _afterAllowlist();
    }

    function _afterAllowlist() internal virtual {}

    function _market(CollateralParams[] memory params, uint256 maturity, uint256 rcf)
        internal
        pure
        returns (Market memory)
    {
        return Market({
            chainId: 8453,
            midnight: MIDNIGHT,
            loanToken: USDC,
            collateralParams: params,
            maturity: maturity,
            rcfThreshold: rcf,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function _cbMarket(uint256 lltv, uint256 maturity, uint256 rcf) internal pure returns (Market memory) {
        CollateralParams[] memory p = new CollateralParams[](1);
        p[0] = CollateralParams({token: CBBTC, lltv: lltv, liquidationCursor: CURSOR, oracle: CBBTC_ORACLE});
        return _market(p, maturity, rcf);
    }

    function _weMarket(uint256 lltv, uint256 maturity, uint256 rcf) internal pure returns (Market memory) {
        CollateralParams[] memory p = new CollateralParams[](1);
        p[0] = CollateralParams({token: WETH, lltv: lltv, liquidationCursor: CURSOR, oracle: WETH_ORACLE});
        return _market(p, maturity, rcf);
    }

    function _wecbMarket(uint256 maturity) internal pure returns (Market memory) {
        CollateralParams[] memory p = new CollateralParams[](2);
        p[0] = CollateralParams({token: WETH, lltv: 0.86e18, liquidationCursor: CURSOR, oracle: WETH_ORACLE});
        p[1] = CollateralParams({token: CBBTC, lltv: 0.86e18, liquidationCursor: CURSOR, oracle: CBBTC_ORACLE});
        return _market(p, maturity, 3_000_000_000);
    }

    function _fund(address token, address to, uint256 amount) internal {
        vm.prank(FUNDER);
        require(iErc20Like(token).transfer(to, amount), "fund failed");
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

    function _openSeries(Market[] memory markets, uint256[] memory caps, uint256 S, uint256 J)
        internal
        returns (creditSeries series, bytes32[] memory ids)
    {
        ids = new bytes32[](markets.length);
        uint256[] memory floors = new uint256[](markets.length);
        for (uint256 i = 0; i < markets.length; i++) {
            ids[i] = midnight.touchMarket(markets[i]);
            floors[i] = 0.005e18;
        }
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
            parking: parking,
            offchainAttestationHash: bytes32(0)
        });
        vm.prank(ALLOCATOR);
        series = creditSeries(core.openSeries(p, S, J));
        tracked.push(series);
    }

    function _openSingle(Market memory market, uint256 S, uint256 J) internal returns (creditSeries, bytes32) {
        Market[] memory ms = new Market[](1);
        ms[0] = market;
        uint256[] memory caps = new uint256[](1);
        caps[0] = S + J;
        (creditSeries s, bytes32[] memory ids) = _openSeries(ms, caps, S, J);
        return (s, ids[0]);
    }

    function _collateralFor(Market memory market, uint256 index, uint256 units, uint256 healthPctOfLltv)
        internal
        view
        returns (uint256)
    {
        CollateralParams memory c = market.collateralParams[index];
        uint256 price = iPriceOracle(c.oracle).price();
        uint256 atLimit = units.mulDivUp(WAD, c.lltv).mulDivUp(ORACLE_PRICE_SCALE, price);
        return atLimit.mulDivUp(100, healthPctOfLltv);
    }

    function _postCollateral(address borrower, Market memory market, uint256 index, uint256 amount) internal {
        address token = market.collateralParams[index].token;
        _fund(token, borrower, amount);
        vm.startPrank(borrower);
        iErc20Like(token).approve(MIDNIGHT, amount);
        midnight.supplyCollateral(market, index, amount, borrower);
        vm.stopPrank();
    }

    function _take(creditSeries series, uint256 i, Market memory market, uint256 units, address borrower) internal {
        Offer memory offer = _buildOffer(series, i, market, units, borrower);
        bytes32 root = _registerSingle(series, offer);
        _takeRatified(offer, root, units, borrower);
    }

    function _registerSingle(creditSeries series, Offer memory offer) internal returns (bytes32 root) {
        Offer[] memory leaves = new Offer[](1);
        leaves[0] = offer;
        root = HashLib.hashOffer(offer);
        vm.prank(ALLOCATOR);
        series.registerOffers(root, leaves);
    }

    function _takeRatified(Offer memory offer, bytes32 root, uint256 units, address borrower) internal {
        vm.prank(borrower);
        midnight.take(offer, abi.encode(root, uint256(0), new bytes32[](0)), units, borrower, borrower, address(0), "");
    }

    function _buildOffer(creditSeries series, uint256 i, Market memory market, uint256 units, address borrower)
        internal
        view
        returns (Offer memory offer)
    {
        uint256 tick = series.tickMaxFor(i);
        uint256 price = TickLib.tickToPrice(tick);
        offer.market = market;
        offer.buy = true;
        offer.maker = address(series);
        offer.expiry = series.T_DEPLOY_END();
        offer.tick = tick;
        offer.group = keccak256(abi.encode("fork", address(series), i, units, borrower));
        offer.callback = address(series);
        offer.callbackData = abi.encode(i);
        offer.ratifier = SETTER_RATIFIER;
        offer.maxAssets = uint128(units.mulDivUp(price, WAD) + 1000e6);
        offer.continuousFeeCap = type(uint256).max;
    }

    function _borrow(
        creditSeries series,
        uint256 i,
        Market memory market,
        uint256 units,
        address borrower,
        uint256 healthPctOfLltv
    ) internal {
        _postCollateral(borrower, market, 0, _collateralFor(market, 0, units, healthPctOfLltv));
        _take(series, i, market, units, borrower);
    }

    function _finalizeByKeeper(creditSeries series) internal {
        if (block.timestamp <= series.T_DEPLOY_END()) vm.warp(uint256(series.T_DEPLOY_END()) + 1);
        vm.prank(keeper);
        series.finalize();
    }

    function _toSettling(creditSeries series) internal {
        if (block.timestamp < series.T()) vm.warp(series.T());
        vm.prank(keeper);
        series.startSettlement();
    }

    function _repayAll(Market memory market, bytes32 id, address borrower) internal {
        uint256 debt = midnight.debt(id, borrower);
        if (debt == 0) return;
        _fund(USDC, borrower, debt);
        vm.startPrank(borrower);
        iErc20Like(USDC).approve(MIDNIGHT, debt);
        midnight.repay(market, debt, borrower, address(0), "");
        vm.stopPrank();
    }

    function _liquidateOverdue(Market memory market, bytes32 id, address borrower, uint256 collateralIndex) internal {
        uint256 debt = midnight.debt(id, borrower);
        _fund(USDC, keeper, debt);
        vm.startPrank(keeper);
        iErc20Like(USDC).approve(MIDNIGHT, debt);
        midnight.liquidate(market, collateralIndex, 0, debt, borrower, true, keeper, address(0), "");
        vm.stopPrank();
    }

    function _collectAll(creditSeries series) internal {
        uint256 n = series.marketIds().length;
        for (uint256 i = 0; i < n; i++) {
            vm.prank(keeper);
            series.collect(i);
        }
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
        if (claimable == 0) return 0;
        vm.prank(alice);
        paid = seniorVault.redeem(claimable, alice, alice);
    }

    function _juniorExit(uint256 shares) internal returns (uint256 paid) {
        vm.prank(juniorLender);
        uint256 id = juniorVault.requestRedeem(shares, juniorLender, juniorLender);
        vm.warp(block.timestamp + juniorVault.MAX_EPOCH_DURATION());
        vm.prank(keeper);
        juniorVault.closeRedeemEpoch();
        vm.warp(block.timestamp + juniorVault.FILL_GRACE());
        vm.prank(keeper);
        juniorVault.fulfillRedeem(id, type(uint128).max);
        uint256 claimable = juniorVault.claimableRedeemRequest(id, juniorLender);
        if (claimable == 0) return 0;
        vm.prank(juniorLender);
        paid = juniorVault.redeem(claimable, juniorLender, juniorLender);
    }

    function _proceeds(creditSeries s) internal view returns (uint256) {
        return iErc20Like(USDC).balanceOf(address(s)) + parking.totalAssets(address(s)) + s.paidS() + s.paidJ()
            + s.feeClaimed();
    }

    function _checkStructure() internal view {
        (, uint256 seniorReserved,) = core.senior();
        (, uint256 juniorReserved, uint256 juniorPending) = core.junior();
        assertEq(
            iErc20Like(USDC).balanceOf(address(core)),
            seniorReserved + juniorReserved + juniorPending,
            "books: core usdc must equal reserved plus pending"
        );
        uint256 parked = parking.totalAssets(address(core));
        uint256 booked = core.idle(true) + core.idle(false);
        assertLe(booked, parked, "books: claims never exceed the parking account");
        assertLe(parked - booked, 2, "books: parking fully accounted up to rounding");
        assertEq(seniorVault.totalAssets(), core.seniorAssets(), "books: senior vault equals senior book");
        assertEq(juniorVault.totalAssets(), core.juniorAssets(), "books: junior vault equals junior book");

        for (uint256 k = 0; k < tracked.length; k++) {
            creditSeries s = tracked[k];
            assertEq(iErc20Like(USDC).balanceOf(address(s)), 0, "series never holds loose usdc between calls");
            if (uint8(s.state()) != uint8(SeriesState.SETTLED)) continue;
            uint256 p = _proceeds(s);
            assertEq(s.paidS() + s.paidJ() + s.feeAccounted(), p, "conservation: senior + junior + fee == proceeds");
            if (!s.passThrough()) {
                uint256 claim = s.seniorClaim();
                assertEq(s.paidS(), p < claim ? p : claim, "seniority: senior paid min(claim, proceeds)");
            }
            for (uint256 j = 0; j < core.liveSeriesCount(); j++) {
                assertTrue(core.liveSeries(j) != address(s), "liveness: settled series left the live set");
            }
        }
    }
}
