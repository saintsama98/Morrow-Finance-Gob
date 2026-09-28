// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: batches keep moving without operators, fill oldest first, release stuck requests and outrank new
// series for idle cash.
// @author adiii.eth

pragma solidity 0.8.34;

import {ScenarioBase} from "../scenario/ScenarioBase.t.sol";
import {usdcVaultBase} from "../../src/vaults/shared/usdcVaultBase.sol";
import {coreStorage} from "../../src/core/modules/coreStorage.sol";
import {SeriesParams} from "../../src/interfaces/iSeries.sol";
import {iParking} from "../../src/parking/iParking.sol";
import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";

contract EpochLivenessTest is ScenarioBase {
    address juniorSeed = makeAddr("juniorSeed");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");
    address stayer = makeAddr("stayer");
    address curator;

    function setUp() public override {
        super.setUp();
        curator = registry.CURATOR();
    }

    function _seniorExitBatch(uint256 aliceAssets, uint256 bobAssets)
        internal
        returns (uint256 id, uint256 sharesA, uint256 sharesB)
    {
        _juniorDeposit(juniorSeed, 2_000_000e6);
        _seniorDeposit(stayer, 1_000_000e6);
        sharesA = _seniorDeposit(alice, aliceAssets);
        sharesB = _seniorDeposit(bob, bobAssets);
        vm.prank(alice);
        id = seniorVault.requestRedeem(sharesA, alice, alice);
        vm.prank(bob);
        seniorVault.requestRedeem(sharesB, bob, bob);
    }

    function test_close_byStranger_onlyAfterMaxDuration() public {
        _seniorExitBatch(100_000e6, 100_000e6);
        uint256 maxDuration = seniorVault.MAX_EPOCH_DURATION();

        vm.prank(stranger);
        vm.expectRevert(usdcVaultBase.NotOperator.selector);
        seniorVault.closeEpoch();

        vm.warp(block.timestamp + maxDuration);
        vm.prank(stranger);
        seniorVault.closeEpoch();
        assertEq(seniorVault.openEpochId(), 2);
    }

    function test_fill_byStranger_onlyAfterGrace() public {
        (uint256 id,,) = _seniorExitBatch(100_000e6, 100_000e6);
        uint256 grace = seniorVault.FILL_GRACE();
        vm.prank(curator);
        seniorVault.closeEpoch();

        vm.prank(stranger);
        vm.expectRevert(usdcVaultBase.NotOperator.selector);
        seniorVault.fulfill(id, type(uint128).max);

        vm.warp(block.timestamp + grace);
        vm.prank(stranger);
        seniorVault.fulfill(id, type(uint128).max);
        assertEq(seniorVault.pendingRedeemRequest(id, alice), 0, "a stranger can complete the batch after the grace");
        assertEq(seniorVault.pendingRedeemRequest(id, bob), 0);
    }

    function test_batchesProgressWithoutAnyOperator() public {
        (uint256 id, uint256 sharesA,) = _seniorExitBatch(100_000e6, 100_000e6);
        uint256 maxDuration = seniorVault.MAX_EPOCH_DURATION();
        uint256 grace = seniorVault.FILL_GRACE();

        vm.warp(block.timestamp + maxDuration);
        vm.prank(alice);
        seniorVault.closeEpoch();
        vm.warp(block.timestamp + grace);
        vm.prank(alice);
        seniorVault.fulfill(id, type(uint128).max);
        vm.prank(alice);
        uint256 paid = seniorVault.redeem(sharesA, alice, alice);
        assertApproxEqAbs(paid, 100_000e6, 2, "an exiter gets out with no operator involved at all");
    }

    function test_fill_isOldestFirst() public {
        (uint256 first,,) = _seniorExitBatch(100_000e6, 100_000e6);
        vm.prank(curator);
        seniorVault.closeEpoch();

        address carol = makeAddr("carol");
        uint256 sharesC = _seniorDeposit(carol, 50_000e6);
        vm.prank(carol);
        uint256 second = seniorVault.requestRedeem(sharesC, carol, carol);
        vm.prank(curator);
        seniorVault.closeEpoch();

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(usdcVaultBase.NotOldestBatch.selector, first));
        seniorVault.fulfill(second, type(uint128).max);

        vm.prank(curator);
        seniorVault.fulfill(first, type(uint128).max);
        assertEq(seniorVault.nextEpochToFill(), second, "the pointer moves to the next unfinished batch");

        vm.prank(curator);
        seniorVault.fulfill(second, type(uint128).max);
        assertEq(seniorVault.pendingRedeemRequest(second, carol), 0);

        vm.prank(curator);
        seniorVault.fulfill(first, type(uint128).max);
    }

    function test_cancelAfterClose_onlyAfterTimeout_keepsFilledPart_othersUnaffected() public {
        (uint256 id, uint256 sharesA, uint256 sharesB) = _seniorExitBatch(100_000e6, 100_000e6);
        uint256 timeout = seniorVault.CANCEL_AFTER_CLOSE();
        vm.prank(curator);
        seniorVault.closeEpoch();
        vm.prank(curator);
        seniorVault.fulfill(id, 80_000e6);

        uint256 aliceFilled = seniorVault.claimableRedeemRequest(id, alice);
        uint256 aliceOwed = seniorVault.owedRedeemAssets(id, alice);
        assertGt(aliceFilled, 0);
        assertLt(aliceFilled, sharesA, "sanity: a partial fill");

        vm.prank(alice);
        vm.expectRevert(usdcVaultBase.EpochAlreadyClosed.selector);
        seniorVault.cancelRedeemRequest(id, alice);

        vm.warp(block.timestamp + timeout);
        vm.prank(alice);
        seniorVault.cancelRedeemRequest(id, alice);

        assertEq(seniorVault.claimableRedeemRequest(id, alice), aliceFilled, "alice keeps her filled part");
        assertEq(seniorVault.owedRedeemAssets(id, alice), aliceOwed, "at the price it was filled at");
        assertEq(seniorVault.claimableCancelRedeemRequest(id, alice), sharesA - aliceFilled, "the rest comes back");

        vm.prank(curator);
        seniorVault.fulfill(id, type(uint128).max);
        assertEq(seniorVault.pendingRedeemRequest(id, bob), 0, "bob still fills completely");
        assertEq(seniorVault.claimableRedeemRequest(id, bob), sharesB, "and is never diluted by alice leaving");

        vm.startPrank(alice);
        uint256 paidA = seniorVault.redeem(aliceFilled, alice, alice);
        seniorVault.claimCancelRedeemRequest(id, alice, alice);
        vm.stopPrank();
        vm.prank(bob);
        uint256 paidB = seniorVault.redeem(sharesB, bob, bob);

        assertEq(paidA, aliceOwed);
        assertEq(seniorVault.balanceOf(alice), sharesA - aliceFilled, "alice holds her unfilled shares again");
        assertApproxEqAbs(paidB, 100_000e6, 2);
        (, uint256 reserved,) = core.senior();
        assertLe(reserved, 2, "nothing stranded");
        assertEq(seniorVault.activeRedeemRequestId(alice), 0);
        assertEq(seniorVault.activeRedeemRequestId(bob), 0);
    }

    function test_queuedExits_reserveIdleAgainstNewSeries() public {
        _juniorDeposit(juniorSeed, 1_000_000e6);
        uint256 shares = _seniorDeposit(alice, 1_000_000e6);
        vm.prank(alice);
        uint256 id = seniorVault.requestRedeem(shares * 9 / 10, alice, alice);
        vm.prank(curator);
        seniorVault.closeEpoch();

        uint256 queued = seniorVault.queuedExitAssets();
        assertApproxEqAbs(queued, 900_000e6, 2, "the closed batch's demand is reported");
        assertEq(core.queuedExits(true), queued);
        assertEq(core.idleDeployable(true), core.idleAvailable(true) - queued, "promised cash is not deployable");

        uint256 maturity = block.timestamp + 90 days;
        Market memory market = registry.marketFor(maturity);
        registry.midnight().touchMarket(market);
        SeriesParams memory p = _params(market, 850_000e6);
        vm.prank(registry.ALLOCATOR());
        vm.expectPartialRevert(coreStorage.IdleInsufficient.selector);
        core.openSeries(p, 700_000e6, 150_000e6);

        vm.prank(curator);
        seniorVault.fulfill(id, type(uint128).max);
        assertEq(seniorVault.queuedExitAssets(), 0, "demand clears once the batch is filled");
    }

    function test_juniorEntry_timeoutCancel_refundsQueuedUsdc() public {
        usdc.mint(alice, 250_000e6);
        vm.startPrank(alice);
        usdc.approve(address(juniorVault), 250_000e6);
        uint256 id = juniorVault.requestDeposit(250_000e6, alice, alice);
        vm.stopPrank();
        vm.prank(curator);
        juniorVault.closeDepositEpoch();
        uint256 timeout = juniorVault.CANCEL_AFTER_CLOSE();

        vm.warp(block.timestamp + timeout);
        vm.prank(alice);
        juniorVault.cancelDepositRequest(id, alice);
        vm.prank(alice);
        juniorVault.claimCancelDepositRequest(id, alice, alice);

        assertEq(usdc.balanceOf(alice), 250_000e6, "the never-invested deposit comes back in full");
        (,, uint256 pending) = core.junior();
        assertEq(pending, 0);
        assertEq(juniorVault.activeDepositRequestId(alice), 0);
    }

    function test_juniorEntry_fillIsOldestFirst_andPermissionlessAfterGrace() public {
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(juniorVault), 100_000e6);
        uint256 first = juniorVault.requestDeposit(100_000e6, alice, alice);
        vm.stopPrank();
        vm.prank(curator);
        juniorVault.closeDepositEpoch();
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), 100_000e6);
        uint256 second = juniorVault.requestDeposit(100_000e6, bob, bob);
        vm.stopPrank();
        vm.prank(curator);
        juniorVault.closeDepositEpoch();

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(usdcVaultBase.NotOldestBatch.selector, first));
        juniorVault.fulfillDeposit(second, type(uint128).max);

        vm.warp(block.timestamp + juniorVault.FILL_GRACE());
        vm.prank(stranger);
        juniorVault.fulfillDeposit(first, type(uint128).max);
        vm.prank(stranger);
        juniorVault.fulfillDeposit(second, type(uint128).max);
        assertEq(juniorVault.pendingDepositRequest(first, alice), 0);
        assertEq(juniorVault.pendingDepositRequest(second, bob), 0);
    }

    function test_juniorExit_timeoutCancelAfterPartialFill_andQueuedDemand() public {
        _juniorDeposit(juniorSeed, 2_000_000e6);
        uint256 sharesA = _juniorDeposit(alice, 100_000e6);
        uint256 sharesB = _juniorDeposit(bob, 100_000e6);
        vm.prank(alice);
        uint256 id = juniorVault.requestRedeem(sharesA, alice, alice);
        vm.prank(bob);
        juniorVault.requestRedeem(sharesB, bob, bob);
        vm.prank(curator);
        juniorVault.closeRedeemEpoch();
        assertApproxEqAbs(juniorVault.queuedExitAssets(), 200_000e6, 2);
        assertEq(core.queuedExits(false), juniorVault.queuedExitAssets());

        vm.prank(curator);
        juniorVault.fulfillRedeem(id, 50_000e6);
        uint256 aliceFilled = juniorVault.claimableRedeemRequest(id, alice);
        assertGt(aliceFilled, 0);

        vm.warp(block.timestamp + juniorVault.CANCEL_AFTER_CLOSE());
        vm.prank(alice);
        juniorVault.cancelRedeemRequest(id, alice);
        assertApproxEqAbs(juniorVault.queuedExitAssets(), 100_000e6 - 25_000e6, 2, "alice's unfilled demand leaves");

        vm.prank(curator);
        juniorVault.fulfillRedeem(id, type(uint128).max);
        assertEq(juniorVault.claimableRedeemRequest(id, bob), sharesB, "bob is never diluted");
        assertEq(juniorVault.claimableRedeemRequest(id, alice), aliceFilled, "alice keeps her filled part");
        assertEq(juniorVault.queuedExitAssets(), 0);
    }

    function testFuzz_cancelsNeverDiluteTheOthers(
        uint96 a,
        uint96 b,
        uint96 c,
        uint96 firstFill,
        bool aliceCancelsWhileOpen,
        bool bobCancelsAfterTimeout
    ) public {
        _juniorDeposit(juniorSeed, 5_000_000e6);
        _seniorDeposit(stayer, 2_000_000e6);
        address carol = makeAddr("carol");
        uint256 sharesA = _seniorDeposit(alice, bound(a, 1_000e6, 300_000e6));
        uint256 sharesB = _seniorDeposit(bob, bound(b, 1_000e6, 300_000e6));
        uint256 sharesC = _seniorDeposit(carol, bound(c, 1_000e6, 300_000e6));

        vm.prank(alice);
        uint256 id = seniorVault.requestRedeem(sharesA, alice, alice);
        vm.prank(bob);
        seniorVault.requestRedeem(sharesB, bob, bob);
        vm.prank(carol);
        seniorVault.requestRedeem(sharesC, carol, carol);

        if (aliceCancelsWhileOpen) {
            vm.prank(alice);
            seniorVault.cancelRedeemRequest(id, alice);
        }
        vm.prank(curator);
        seniorVault.closeEpoch();
        vm.prank(curator);
        seniorVault.fulfill(id, bound(firstFill, 0, 900_000e6));

        if (bobCancelsAfterTimeout && seniorVault.pendingRedeemRequest(id, bob) > 0) {
            vm.warp(block.timestamp + seniorVault.CANCEL_AFTER_CLOSE());
            vm.prank(bob);
            seniorVault.cancelRedeemRequest(id, bob);
        }
        vm.prank(curator);
        seniorVault.fulfill(id, type(uint128).max);

        assertEq(seniorVault.claimableRedeemRequest(id, carol), sharesC, "carol always fills completely");
        (,,,,, bool closed) = seniorVault.epochs(id);
        assertTrue(closed);
        (, uint256 remaining,,,,) = seniorVault.epochs(id);
        assertEq(remaining, 0, "the batch completes");

        uint256 owed = seniorVault.owedRedeemAssets(id, alice) + seniorVault.owedRedeemAssets(id, bob)
            + seniorVault.owedRedeemAssets(id, carol);
        (, uint256 reserved,) = core.senior();
        assertLe(owed, reserved, "every promise is backed by reserved cash");
        assertLe(reserved - owed, 3, "and nothing beyond rounding is stranded");
    }

    function test_juniorExit_cancelAfterDustFill_movesAtMostOneWeiAndConservesTheBatch() public {
        _juniorDeposit(juniorSeed, 2_000_000e6);
        _juniorDeposit(alice, 1e6);
        _juniorDeposit(bob, 1e6);
        vm.prank(alice);
        uint256 id = juniorVault.requestRedeem(990_000_000_000, alice, alice);
        vm.prank(bob);
        juniorVault.requestRedeem(2_871_012_923_802_666, bob, bob);
        vm.prank(curator);
        juniorVault.closeRedeemEpoch();
        (,,,, uint256 ppsClose,) = juniorVault.redeemEpochs(id);

        vm.prank(curator);
        juniorVault.fulfillRedeem(id, 15);
        (,, uint256 sharesFilled, uint256 assetsFilled,,) = juniorVault.redeemEpochs(id);
        assertLe(assetsFilled * 1e18 / sharesFilled, ppsClose, "sanity: the fill itself is within the close price");

        vm.warp(block.timestamp + juniorVault.CANCEL_AFTER_CLOSE());
        vm.prank(alice);
        juniorVault.cancelRedeemRequest(id, alice);

        uint256 owedA = juniorVault.owedRedeemAssets(id, alice);
        uint256 owedB = juniorVault.owedRedeemAssets(id, bob);
        assertEq(owedA + owedB, assetsFilled, "the batch's filled assets are conserved across the cancel");

        uint256 frozenA = juniorVault.frozenRedeemShares(id, alice);
        uint256 liveB = juniorVault.claimableRedeemRequest(id, bob);
        assertEq(frozenA + liveB, sharesFilled, "the batch's filled shares are conserved across the cancel");
        assertLe(owedA, frozenA * ppsClose / 1e18, "the leaver never takes more than the close price");
        assertLe(owedB, liveB * ppsClose / 1e18 + 1, "the stayer gains at most one wei of rounding dust");

        (,, uint256 sharesLive, uint256 assetsLive,,) = juniorVault.redeemEpochs(id);
        assertGt(assetsLive * 1e18 / sharesLive, ppsClose, "the remaining live ratio alone can overshoot on dust");
    }

    function _params(Market memory market, uint256 cap) internal view returns (SeriesParams memory p) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = registry.idOf(market);
        uint256[] memory floors = new uint256[](1);
        floors[0] = 0.005e18;
        uint256[] memory caps = new uint256[](1);
        caps[0] = cap;
        p = SeriesParams({
            marketIds: ids,
            tDeployEnd: uint64(block.timestamp + 2 days),
            dWriteOff: uint64(7 days),
            covWad: 0.15e18,
            pi0Wad: 0.1e18,
            piTWad: 0.2e18,
            pi1Wad: 0.35e18,
            rateFloorWad: floors,
            marketCapAssets: caps,
            kMinAssets: 50_000e6,
            thetaWad: 0.1e18,
            feeRecipient: registry.FEE_RECIPIENT(),
            allocator: registry.ALLOCATOR(),
            parking: iParking(address(registry.parking())),
            offchainAttestationHash: bytes32(0)
        });
    }
}
