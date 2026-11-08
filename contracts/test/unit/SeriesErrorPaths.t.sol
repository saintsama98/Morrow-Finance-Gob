// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: every revert path of a series and of the factory's parameter checks, by exact error.
// @author adiii.eth

pragma solidity 0.8.34;

import {Market, Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {HashLib} from "@morpho-org/midnight/src/ratifiers/libraries/HashLib.sol";
import {RedTeamBase} from "../exploit/RedTeamBase.sol";
import {CreditSeries} from "../../src/series/CreditSeries.sol";
import {SeriesFactory} from "../../src/series/SeriesFactory.sol";
import {SeriesStorage} from "../../src/series/modules/SeriesStorage.sol";
import {CoreStorage} from "../../src/core/modules/CoreStorage.sol";
import {SeriesParams, SeriesState} from "../../src/interfaces/ISeries.sol";

contract SeriesErrorPathsTest is RedTeamBase {
    address internal borrower = makeAddr("borrower");
    address internal stranger = makeAddr("stranger");
    Market internal m;
    bytes32 internal id;

    function setUp() public override {
        super.setUp();
        m = _cbBtcMarket(maturity, LLTV_77);
        id = _touch(m);
        _fundBook(true, 4_000_000e6);
        _fundBook(false, 1_000_000e6);
    }

    // ---------------- factory parameter checks ----------------

    function _createAsCore(SeriesParams memory p) internal returns (address) {
        vm.prank(address(core));
        return factory.createSeries(p);
    }

    function test_factory_onlyCore() public {
        SeriesParams memory p = _params(id, 1_000_000e6);
        vm.prank(stranger);
        vm.expectRevert(SeriesFactory.NotCore.selector);
        factory.createSeries(p);
    }

    function test_factory_arrayLengthMismatch() public {
        SeriesParams memory p = _params(id, 1_000_000e6);
        p.rateFloorWad = new uint256[](2);
        vm.expectRevert(SeriesFactory.MarketArrayLengthMismatch.selector);
        _createAsCore(p);
    }

    function test_factory_covBand() public {
        SeriesParams memory p = _params(id, 1_000_000e6);
        p.covWad = 0.04e18;
        vm.expectRevert(SeriesFactory.InvalidCovBand.selector);
        _createAsCore(p);
        p.covWad = 0.51e18;
        vm.expectRevert(SeriesFactory.InvalidCovBand.selector);
        _createAsCore(p);
    }

    function test_factory_premiumAnchors() public {
        SeriesParams memory p = _params(id, 1_000_000e6);
        p.pi0Wad = 0.3e18;
        vm.expectRevert(SeriesFactory.InvalidPremiumAnchors.selector);
        _createAsCore(p);
        p = _params(id, 1_000_000e6);
        p.pi1Wad = 1e18;
        vm.expectRevert(SeriesFactory.InvalidPremiumAnchors.selector);
        _createAsCore(p);
    }

    function test_factory_thetaCeiling() public {
        SeriesParams memory p = _params(id, 1_000_000e6);
        p.thetaWad = 0.2e18 + 1;
        vm.expectRevert(SeriesFactory.ThetaAboveCeiling.selector);
        _createAsCore(p);
    }

    function test_factory_zeroRateFloor() public {
        SeriesParams memory p = _params(id, 1_000_000e6);
        p.rateFloorWad[0] = 0;
        vm.expectRevert(SeriesFactory.ZeroRateFloor.selector);
        _createAsCore(p);
    }

    function test_series_constructorTiming() public {
        SeriesParams memory p = _params(id, 1_000_000e6);
        p.tDeployEnd = uint64(vm.getBlockTimestamp());
        vm.expectRevert(SeriesStorage.InvalidTiming.selector);
        _createAsCore(p);
        p.tDeployEnd = uint64(maturity - 14 days);
        vm.expectRevert(SeriesStorage.InvalidTiming.selector);
        _createAsCore(p);
    }

    // ---------------- core openSeries ----------------

    function test_openSeries_maturityWindowExceeded() public {
        // 5M of books, so the default 50% window holds 2.5M: two 1M series fit, a third within 30 days does not.
        _openSeries(m, 800_000e6, 200_000e6);
        _openSeries(_cbBtcMarket(maturity + 2 days, LLTV_77), 800_000e6, 200_000e6);
        Market memory near = _cbBtcMarket(maturity + 1 days, LLTV_77);
        bytes32 nearId = _touch(near);
        vm.prank(allocator);
        vm.expectRevert(CoreStorage.MaturityWindowExceeded.selector);
        core.openSeries(_params(nearId, 1_000_000e6), 800_000e6, 200_000e6);
    }

    function test_openSeries_capsBelowAllocation() public {
        vm.prank(allocator);
        vm.expectRevert(SeriesStorage.CapacityBelowAllocation.selector);
        core.openSeries(_params(id, 999_999e6), 800_000e6, 200_000e6);
    }

    // ---------------- initialize, cancel, finalize ----------------

    function test_initialize_onlyCore_andNeedsCash() public {
        address s = _createAsCore(_params(id, 1_000_000e6));
        vm.prank(stranger);
        vm.expectRevert(SeriesStorage.NotCoreOrSentinel.selector);
        CreditSeries(s).initialize(1, 1);
        vm.prank(address(core));
        vm.expectRevert(SeriesStorage.InsufficientCash.selector);
        CreditSeries(s).initialize(800_000e6, 200_000e6);
    }

    function test_cancel_onlyAllocatorOrSentinel_andNotAfterAFill() public {
        CreditSeries s = _openSeries(m, 800_000e6, 200_000e6);
        vm.prank(stranger);
        vm.expectRevert(SeriesStorage.NotCoreOrSentinel.selector);
        s.cancel();

        Offer memory offer = _selfOffer(s, m, 100_000e6);
        bytes32 root = _register(s, offer);
        _take(m, offer, root, borrower, 100_000e6);

        vm.prank(sentinel);
        vm.expectRevert(SeriesStorage.AlreadyFilled.selector);
        s.cancel();
    }

    function test_finalize_strangerBeforeWindowEnd() public {
        CreditSeries s = _openSeries(m, 800_000e6, 200_000e6);
        vm.prank(stranger);
        vm.expectRevert(SeriesStorage.NotAllocator.selector);
        s.finalize();

        vm.warp(uint256(s.T_DEPLOY_END()) + 1);
        vm.prank(stranger);
        s.finalize();
        assertEq(uint8(s.state()), uint8(SeriesState.CANCELED), "nothing filled, so finalize cancels");
    }

    function test_lifecycleCalls_inWrongState() public {
        CreditSeries s = _openSeries(m, 800_000e6, 200_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(SeriesStorage.WrongState.selector, SeriesState.LOCKED, SeriesState.DEPLOYING)
        );
        s.startSettlement();
        vm.expectRevert(
            abi.encodeWithSelector(SeriesStorage.WrongState.selector, SeriesState.SETTLING, SeriesState.DEPLOYING)
        );
        s.collect(0);
        vm.expectRevert(
            abi.encodeWithSelector(SeriesStorage.WrongState.selector, SeriesState.SETTLING, SeriesState.DEPLOYING)
        );
        s.writeOff();
    }

    function test_startSettlement_beforeMaturity() public {
        CreditSeries s = _openFillFinalize(m, borrower, 800_000e6, 200_000e6, 1_000_000e6);
        uint256 t = vm.getBlockTimestamp();
        vm.expectRevert(abi.encodeWithSelector(SeriesStorage.TooEarly.selector, t));
        s.startSettlement();
    }

    // ---------------- registerOffers ----------------

    function test_registerOffers_onlyAllocator() public {
        CreditSeries s = _openSeries(m, 800_000e6, 200_000e6);
        Offer[] memory leaves = new Offer[](1);
        leaves[0] = _selfOffer(s, m, 1);
        vm.prank(stranger);
        vm.expectRevert(SeriesStorage.NotAllocator.selector);
        s.registerOffers(bytes32(0), leaves);
    }

    function test_registerOffers_rootMismatchAndShape() public {
        CreditSeries s = _openSeries(m, 800_000e6, 200_000e6);
        Offer[] memory one = new Offer[](1);
        one[0] = _selfOffer(s, m, 1);
        vm.prank(allocator);
        vm.expectRevert(SeriesStorage.InvalidTree.selector);
        s.registerOffers(bytes32(uint256(1)), one);

        Offer[] memory three = new Offer[](3);
        for (uint256 k = 0; k < 3; k++) {
            three[k] = one[0];
        }
        vm.prank(allocator);
        vm.expectRevert(SeriesStorage.InvalidTree.selector);
        s.registerOffers(bytes32(0), three);

        Offer[] memory none = new Offer[](0);
        vm.prank(allocator);
        vm.expectRevert(SeriesStorage.InvalidTree.selector);
        s.registerOffers(bytes32(0), none);
    }

    function _registerExpectingLeafError(CreditSeries s, Offer memory offer, bytes memory err) internal {
        Offer[] memory leaves = new Offer[](1);
        leaves[0] = offer;
        bytes32 root = HashLib.hashOffer(offer);
        vm.prank(allocator);
        vm.expectRevert(err);
        s.registerOffers(root, leaves);
    }

    function test_registerOffers_invalidLeaves() public {
        CreditSeries s = _openSeries(m, 800_000e6, 200_000e6);
        bytes memory bad = abi.encodeWithSelector(SeriesStorage.InvalidLeaf.selector, uint256(0));

        Offer memory o = _selfOffer(s, m, 1);
        o.buy = false;
        _registerExpectingLeafError(s, o, bad);

        o = _selfOffer(s, m, 1);
        o.expiry = s.T_DEPLOY_END() + 1;
        _registerExpectingLeafError(s, o, bad);

        o = _selfOffer(s, m, 1);
        o.callback = stranger;
        _registerExpectingLeafError(s, o, bad);

        o = _selfOffer(s, m, 1);
        o.ratifier = stranger;
        _registerExpectingLeafError(s, o, bad);

        o = _selfOffer(s, m, 1);
        o.reduceOnly = true;
        _registerExpectingLeafError(s, o, bad);

        o = _selfOffer(s, m, 1);
        o.callbackData = abi.encode(uint256(1));
        _registerExpectingLeafError(s, o, bad);
    }

    function test_registerOffers_tickAboveFloorPrice() public {
        CreditSeries s = _openSeries(m, 800_000e6, 200_000e6);
        Offer memory o = _selfOffer(s, m, 1);
        uint256 tickMax = s.tickMaxFor(0);
        o.tick = tickMax + 1;
        _registerExpectingLeafError(
            s, o, abi.encodeWithSelector(SeriesStorage.PriceFloorBreached.selector, uint256(0), tickMax + 1, tickMax)
        );
    }

    function test_registerOffers_afterWindow() public {
        CreditSeries s = _openSeries(m, 800_000e6, 200_000e6);
        Offer[] memory leaves = new Offer[](1);
        leaves[0] = _selfOffer(s, m, 1);
        uint256 late = uint256(s.T_DEPLOY_END()) + 1;
        vm.warp(late);
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(SeriesStorage.TooLate.selector, late));
        s.registerOffers(HashLib.hashOffer(leaves[0]), leaves);
    }

    // ---------------- onBuy callback guards ----------------

    function test_onBuy_guards() public {
        CreditSeries s = _openSeries(m, 800_000e6, 200_000e6);
        bytes memory data = abi.encode(uint256(0));

        vm.expectRevert(SeriesStorage.NotMidnight.selector);
        s.onBuy(id, m, 1, 1, 0, address(s), data);

        vm.startPrank(address(midnight));
        vm.expectRevert(SeriesStorage.NotSelfBuyer.selector);
        s.onBuy(id, m, 1, 1, 0, stranger, data);

        vm.expectRevert(SeriesStorage.ZeroUnits.selector);
        s.onBuy(id, m, 1, 0, 0, address(s), data);

        bytes32 other = keccak256("other");
        vm.expectRevert(abi.encodeWithSelector(SeriesStorage.MarketMismatch.selector, id, other));
        s.onBuy(other, m, 1, 1, 0, address(s), data);

        uint256 priceMax = s.priceMaxFor(0);
        vm.expectRevert(
            abi.encodeWithSelector(SeriesStorage.PriceFloorBreached.selector, uint256(0), uint256(1e18), priceMax)
        );
        s.onBuy(id, m, 1_000e6, 1_000e6, 0, address(s), data);

        vm.expectRevert(abi.encodeWithSelector(SeriesStorage.CapExceeded.selector, uint256(0)));
        s.onBuy(id, m, 1_000_000e6 + 1, 2_000_000e6, 0, address(s), data);

        bytes32 ok = s.onBuy(id, m, 0, 0, 0, address(s), data);
        assertEq(ok, keccak256("morpho.midnight.callbackSuccess"), "an empty fill is a no-op success");
        vm.stopPrank();
    }

    function test_onBuy_afterWindow_isWrongState() public {
        CreditSeries s = _openSeries(m, 800_000e6, 200_000e6);
        vm.warp(uint256(s.T_DEPLOY_END()) + 1);
        vm.prank(address(midnight));
        vm.expectRevert(
            abi.encodeWithSelector(SeriesStorage.WrongState.selector, SeriesState.DEPLOYING, SeriesState.DEPLOYING)
        );
        s.onBuy(id, m, 1, 1, 0, address(s), abi.encode(uint256(0)));
    }

    function test_buyerAssetsBound_isZeroOutsideTheWindow() public {
        CreditSeries s = _openSeries(m, 800_000e6, 200_000e6);
        assertEq(s.buyerAssetsBound(id, m, address(s), abi.encode(uint256(0))), 1_000_000e6);
        assertEq(s.buyerAssetsBound(id, m, address(s), abi.encode(uint256(7))), 0, "unknown market index");
        vm.warp(uint256(s.T_DEPLOY_END()) + 1);
        assertEq(s.buyerAssetsBound(id, m, address(s), abi.encode(uint256(0))), 0);
    }

    // ---------------- allocator offer controls ----------------

    function test_revokeOffers_stopsFills() public {
        CreditSeries s = _openSeries(m, 800_000e6, 200_000e6);
        Offer memory offer = _selfOffer(s, m, 100_000e6);
        bytes32 root = _register(s, offer);

        vm.prank(stranger);
        vm.expectRevert(SeriesStorage.NotAllocator.selector);
        s.revokeOffers(root);

        vm.expectEmit(false, false, false, true, address(s));
        emit SeriesStorage.OffersRevoked(root);
        vm.prank(allocator);
        s.revokeOffers(root);

        _supplyCollateralFor(m, borrower, 100_000e6);
        vm.expectRevert();
        _takeOnly(offer, root, borrower, 100_000e6);
        assertEq(s.totalFilled(), 0, "a revoked tree cannot fill");
    }

    function test_cancelGroup_stopsFills() public {
        CreditSeries s = _openSeries(m, 800_000e6, 200_000e6);
        Offer memory offer = _selfOffer(s, m, 100_000e6);
        bytes32 root = _register(s, offer);

        vm.prank(stranger);
        vm.expectRevert(SeriesStorage.NotAllocator.selector);
        s.cancelGroup(offer.group);

        vm.prank(allocator);
        s.cancelGroup(offer.group);
        _supplyCollateralFor(m, borrower, 100_000e6);
        vm.expectRevert();
        _takeOnly(offer, root, borrower, 100_000e6);
        assertEq(s.totalFilled(), 0, "a consumed group cannot fill");
    }
}

