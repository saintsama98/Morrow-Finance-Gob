// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: Echidna and Medusa harness for the core and both vaults over a yield-bearing parking venue.
// @author adiii.eth

pragma solidity 0.8.34;

import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockMorphoVault} from "../mocks/MockMorphoVault.sol";
import {morphoParking} from "../../src/parking/morphoParking.sol";
import {iParking} from "../../src/parking/iParking.sol";
import {seriesFactory} from "../../src/series/seriesFactory.sol";
import {seriesCore} from "../../src/core/seriesCore.sol";
import {usdcSeniorVault} from "../../src/vaults/senior/usdcSeniorVault.sol";
import {usdcJuniorVault} from "../../src/vaults/junior/usdcJuniorVault.sol";
import {iMidnightMinimal} from "../../src/interfaces/iMidnightMinimal.sol";

interface IHevm {
    function warp(uint256) external;
}

contract CryticActor {
    address public immutable OWNER;

    constructor() {
        OWNER = msg.sender;
    }

    function exec(address target, bytes calldata data) external returns (bool ok, bytes memory ret) {
        require(msg.sender == OWNER, "owner");
        (ok, ret) = target.call(data);
    }
}

contract MorrowCrytic {
    IHevm internal constant HEVM = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    address internal constant SINK = address(0xdead);
    uint256 internal constant N = 4;

    MockUSDC public usdc;
    MockMorphoVault public venue;
    morphoParking public parking;
    seriesFactory public factory;
    seriesCore public core;
    usdcSeniorVault public sv;
    usdcJuniorVault public jv;

    CryticActor[N] public actors;
    CryticActor public curator;

    uint256 public ghostMinted;
    bool public ghostStrandedSlot;
    bool public ghostEarlyStrangerClose;
    bool public ghostEarlyStrangerFill;
    bool public ghostCoverageBreach;
    bool public ghostClaimOverpaid;
    bool public ghostSeniorHitByIdleLoss;

    constructor() {
        usdc = new MockUSDC();
        venue = new MockMorphoVault(usdc);
        parking = new morphoParking(address(usdc), address(venue), 0.1e18);
        factory =
            new seriesFactory(iMidnightMinimal(address(0x1)), address(0x2), address(usdc), address(this), 0.86e18, 4);
        curator = new CryticActor();
        core = new seriesCore(
            address(usdc),
            factory,
            iParking(address(parking)),
            address(this),
            address(0xA110C),
            address(curator),
            address(0xC0FFEE)
        );
        factory.setCore(address(core));
        sv = new usdcSeniorVault(core, address(usdc));
        jv = new usdcJuniorVault(core, address(usdc));
        core.setVaults(address(sv), address(jv));
        for (uint256 i = 0; i < N; i++) {
            actors[i] = new CryticActor();
        }

        _fund(curator, 300_000e6);
        _as(curator, address(usdc), abi.encodeWithSignature("approve(address,uint256)", address(jv), type(uint256).max));
        _as(
            curator,
            address(jv),
            abi.encodeWithSignature(
                "requestDeposit(uint256,address,address)", 300_000e6, address(curator), address(curator)
            )
        );
        _fund(actors[0], 2_000_000e6);
        _approveAll(actors[0]);
        _as(
            actors[0],
            address(jv),
            abi.encodeWithSignature(
                "requestDeposit(uint256,address,address)", 2_000_000e6, address(actors[0]), address(actors[0])
            )
        );
        _as(curator, address(jv), abi.encodeWithSignature("closeDepositEpoch()"));
        _as(curator, address(jv), abi.encodeWithSignature("fulfillDeposit(uint256,uint256)", 1, type(uint128).max));
        _as(curator, address(jv), abi.encodeWithSignature("claimDeposit(uint256)", 1));
        _as(actors[0], address(jv), abi.encodeWithSignature("claimDeposit(uint256)", 1));
        _fund(actors[1], 2_000_000e6);
        _approveAll(actors[1]);
        _as(
            actors[1], address(sv), abi.encodeWithSignature("deposit(uint256,address)", 2_000_000e6, address(actors[1]))
        );
        for (uint256 i = 2; i < N; i++) {
            _approveAll(actors[i]);
        }
        require(jv.balanceOf(address(actors[0])) > 0 && sv.balanceOf(address(actors[1])) > 0, "seed");
    }

    function _b(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }

    function _actor(uint256 seed) internal view returns (CryticActor) {
        return actors[seed % N];
    }

    function _as(CryticActor a, address target, bytes memory data) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = a.exec(target, data);
    }

    function _fund(CryticActor a, uint256 amount) internal {
        usdc.mint(address(a), amount);
        ghostMinted += amount;
    }

    function _approveAll(CryticActor a) internal {
        _as(a, address(usdc), abi.encodeWithSignature("approve(address,uint256)", address(sv), type(uint256).max));
        _as(a, address(usdc), abi.encodeWithSignature("approve(address,uint256)", address(jv), type(uint256).max));
    }

    function _fillSize(uint256 seed) internal pure returns (uint256) {
        return seed % 2 == 0 ? seed % 50_000e6 : seed % 5_000_000e6;
    }

    function seniorDeposit(uint256 actorSeed, uint256 assetsSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 assets = _b(assetsSeed, 1, 3_000_000e6);
        _fund(a, assets);
        _as(a, address(sv), abi.encodeWithSignature("deposit(uint256,address)", assets, address(a)));
    }

    function seniorMint(uint256 actorSeed, uint256 sharesSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 shares = _b(sharesSeed, 1, 3_000_000e18);
        _fund(a, shares / 1e12 + 10e6);
        _as(a, address(sv), abi.encodeWithSignature("mint(uint256,address)", shares, address(a)));
    }

    function seniorRequestRedeem(uint256 actorSeed, uint256 sharesSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 bal = sv.balanceOf(address(a));
        if (bal == 0) return;
        _as(
            a,
            address(sv),
            abi.encodeWithSignature(
                "requestRedeem(uint256,address,address)", _b(sharesSeed, 1, bal), address(a), address(a)
            )
        );
    }

    function seniorCancel(uint256 actorSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 id = sv.activeRedeemRequestId(address(a));
        if (id == 0) return;
        _as(a, address(sv), abi.encodeWithSignature("cancelRedeemRequest(uint256,address)", id, address(a)));
    }

    function seniorClaimCancel(uint256 actorSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 id = sv.activeRedeemRequestId(address(a));
        if (id == 0) return;
        _as(
            a,
            address(sv),
            abi.encodeWithSignature("claimCancelRedeemRequest(uint256,address,address)", id, address(a), address(a))
        );
    }

    function seniorClaimAll(uint256 actorSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 id = sv.activeRedeemRequestId(address(a));
        if (id == 0) return;
        uint256 claimable = sv.claimableRedeemRequest(id, address(a));
        if (claimable == 0) return;
        uint256 owed = sv.owedRedeemAssets(id, address(a));
        uint256 balBefore = usdc.balanceOf(address(a));
        (bool ok,) = _as(a, address(sv), abi.encodeWithSignature("claim(uint256)", id));
        if (!ok && sv.pendingRedeemRequest(id, address(a)) == 0) ghostStrandedSlot = true;
        if (ok && usdc.balanceOf(address(a)) - balBefore > owed) ghostClaimOverpaid = true;
    }

    function seniorRedeemPartial(uint256 actorSeed, uint256 sharesSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 id = sv.activeRedeemRequestId(address(a));
        if (id == 0) return;
        uint256 claimable = sv.claimableRedeemRequest(id, address(a));
        if (claimable == 0) return;
        _as(
            a,
            address(sv),
            abi.encodeWithSignature(
                "redeem(uint256,address,address)", _b(sharesSeed, 1, claimable), address(a), address(a)
            )
        );
    }

    function seniorWithdrawPartial(uint256 actorSeed, uint256 assetsSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 id = sv.activeRedeemRequestId(address(a));
        if (id == 0) return;
        uint256 owed = sv.owedRedeemAssets(id, address(a));
        if (owed == 0) return;
        _as(
            a,
            address(sv),
            abi.encodeWithSignature(
                "withdraw(uint256,address,address)", _b(assetsSeed, 1, owed), address(a), address(a)
            )
        );
    }

    function seniorTransfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        CryticActor from = _actor(fromSeed);
        uint256 bal = sv.balanceOf(address(from));
        if (bal == 0) return;
        _as(
            from,
            address(sv),
            abi.encodeWithSignature("transfer(address,uint256)", address(_actor(toSeed)), _b(amountSeed, 1, bal))
        );
    }

    function juniorRequestDeposit(uint256 actorSeed, uint256 assetsSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 assets = _b(assetsSeed, 1, 3_000_000e6);
        _fund(a, assets);
        _as(
            a,
            address(jv),
            abi.encodeWithSignature("requestDeposit(uint256,address,address)", assets, address(a), address(a))
        );
    }

    function juniorCancelDeposit(uint256 actorSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 id = jv.activeDepositRequestId(address(a));
        if (id == 0) return;
        _as(a, address(jv), abi.encodeWithSignature("cancelDepositRequest(uint256,address)", id, address(a)));
    }

    function juniorClaimCancelDeposit(uint256 actorSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 id = jv.activeDepositRequestId(address(a));
        if (id == 0) return;
        _as(
            a,
            address(jv),
            abi.encodeWithSignature("claimCancelDepositRequest(uint256,address,address)", id, address(a), address(a))
        );
    }

    function juniorClaimDepositAll(uint256 actorSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 id = jv.activeDepositRequestId(address(a));
        if (id == 0) return;
        if (jv.claimableDepositRequest(id, address(a)) == 0) return;
        (bool ok,) = _as(a, address(jv), abi.encodeWithSignature("claimDeposit(uint256)", id));
        if (!ok && jv.pendingDepositRequest(id, address(a)) == 0) ghostStrandedSlot = true;
    }

    function juniorDepositPartial(uint256 actorSeed, uint256 assetsSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 id = jv.activeDepositRequestId(address(a));
        if (id == 0) return;
        uint256 claimable = jv.claimableDepositRequest(id, address(a));
        if (claimable == 0) return;
        _as(
            a,
            address(jv),
            abi.encodeWithSignature(
                "deposit(uint256,address,address)", _b(assetsSeed, 1, claimable), address(a), address(a)
            )
        );
    }

    function juniorMintPartial(uint256 actorSeed, uint256 sharesSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 id = jv.activeDepositRequestId(address(a));
        if (id == 0) return;
        uint256 owed = jv.owedDepositShares(id, address(a));
        if (owed == 0) return;
        _as(
            a,
            address(jv),
            abi.encodeWithSignature("mint(uint256,address,address)", _b(sharesSeed, 1, owed), address(a), address(a))
        );
    }

    function juniorRequestRedeem(uint256 actorSeed, uint256 sharesSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 bal = jv.balanceOf(address(a));
        if (bal == 0) return;
        _as(
            a,
            address(jv),
            abi.encodeWithSignature(
                "requestRedeem(uint256,address,address)", _b(sharesSeed, 1, bal), address(a), address(a)
            )
        );
    }

    function juniorCancelRedeem(uint256 actorSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 id = jv.activeRedeemRequestId(address(a));
        if (id == 0) return;
        _as(a, address(jv), abi.encodeWithSignature("cancelRedeemRequest(uint256,address)", id, address(a)));
    }

    function juniorClaimCancelRedeem(uint256 actorSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 id = jv.activeRedeemRequestId(address(a));
        if (id == 0) return;
        _as(
            a,
            address(jv),
            abi.encodeWithSignature("claimCancelRedeemRequest(uint256,address,address)", id, address(a), address(a))
        );
    }

    function juniorClaimRedeemAll(uint256 actorSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 id = jv.activeRedeemRequestId(address(a));
        if (id == 0) return;
        if (jv.claimableRedeemRequest(id, address(a)) == 0) return;
        uint256 owed = jv.owedRedeemAssets(id, address(a));
        uint256 balBefore = usdc.balanceOf(address(a));
        (bool ok,) = _as(a, address(jv), abi.encodeWithSignature("claimRedeem(uint256)", id));
        if (!ok && jv.pendingRedeemRequest(id, address(a)) == 0) ghostStrandedSlot = true;
        if (ok && usdc.balanceOf(address(a)) - balBefore > owed) ghostClaimOverpaid = true;
    }

    function juniorRedeemPartial(uint256 actorSeed, uint256 sharesSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 id = jv.activeRedeemRequestId(address(a));
        if (id == 0) return;
        uint256 claimable = jv.claimableRedeemRequest(id, address(a));
        if (claimable == 0) return;
        _as(
            a,
            address(jv),
            abi.encodeWithSignature(
                "redeem(uint256,address,address)", _b(sharesSeed, 1, claimable), address(a), address(a)
            )
        );
    }

    function juniorWithdrawPartial(uint256 actorSeed, uint256 assetsSeed) external {
        CryticActor a = _actor(actorSeed);
        uint256 id = jv.activeRedeemRequestId(address(a));
        if (id == 0) return;
        uint256 owed = jv.owedRedeemAssets(id, address(a));
        if (owed == 0) return;
        _as(
            a,
            address(jv),
            abi.encodeWithSignature(
                "withdraw(uint256,address,address)", _b(assetsSeed, 1, owed), address(a), address(a)
            )
        );
    }

    function juniorTransfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        CryticActor from = _actor(fromSeed);
        uint256 bal = jv.balanceOf(address(from));
        if (bal == 0) return;
        _as(
            from,
            address(jv),
            abi.encodeWithSignature("transfer(address,uint256)", address(_actor(toSeed)), _b(amountSeed, 1, bal))
        );
    }

    function curatorCloseSenior() external {
        _as(curator, address(sv), abi.encodeWithSignature("closeEpoch()"));
    }

    function curatorFillSenior(uint256 assetsSeed) external {
        uint256 id = sv.nextEpochToFill();
        if (id >= sv.openEpochId()) return;
        _as(curator, address(sv), abi.encodeWithSignature("fulfill(uint256,uint256)", id, _fillSize(assetsSeed)));
    }

    function curatorCloseJuniorDeposit() external {
        _as(curator, address(jv), abi.encodeWithSignature("closeDepositEpoch()"));
    }

    function curatorFillJuniorDeposit(uint256 assetsSeed) external {
        uint256 id = jv.nextDepositEpochToFill();
        if (id >= jv.openDepositEpochId()) return;
        _as(curator, address(jv), abi.encodeWithSignature("fulfillDeposit(uint256,uint256)", id, _fillSize(assetsSeed)));
    }

    function curatorCloseJuniorRedeem() external {
        _as(curator, address(jv), abi.encodeWithSignature("closeRedeemEpoch()"));
    }

    function curatorFillJuniorRedeem(uint256 assetsSeed) external {
        uint256 id = jv.nextRedeemEpochToFill();
        if (id >= jv.openRedeemEpochId()) return;
        (, uint256 before,,,,) = jv.redeemEpochs(id);
        (bool ok,) = _as(
            curator, address(jv), abi.encodeWithSignature("fulfillRedeem(uint256,uint256)", id, _fillSize(assetsSeed))
        );
        (, uint256 afterFill,,,,) = jv.redeemEpochs(id);
        if (ok && afterFill != before) _checkCoverage();
    }

    function _checkCoverage() internal {
        uint256 sA = core.seniorAssets();
        uint256 jA = core.juniorAssets();
        if (sA + jA == 0) return;
        (,,, uint256 covVaultMinWad,,,,,,,,,,,,,,,) = core.policy();
        if (jA * 1e18 / (sA + jA) < covVaultMinWad) ghostCoverageBreach = true;
    }

    function strangerCloseSenior(uint256 actorSeed) external {
        uint256 id = sv.openEpochId();
        bool early = block.timestamp < sv.epochOpenedAt(id) + sv.MAX_EPOCH_DURATION();
        (bool ok,) = _as(_actor(actorSeed), address(sv), abi.encodeWithSignature("closeEpoch()"));
        if (ok && early) ghostEarlyStrangerClose = true;
    }

    function strangerFillSenior(uint256 actorSeed, uint256 assetsSeed) external {
        uint256 id = sv.nextEpochToFill();
        if (id >= sv.openEpochId()) return;
        bool early = block.timestamp < sv.epochClosedAt(id) + sv.FILL_GRACE();
        (, uint256 before,,,,) = sv.epochs(id);
        (bool ok,) = _as(
            _actor(actorSeed),
            address(sv),
            abi.encodeWithSignature("fulfill(uint256,uint256)", id, _fillSize(assetsSeed))
        );
        (, uint256 afterFill,,,,) = sv.epochs(id);
        if (ok && early && afterFill != before) ghostEarlyStrangerFill = true;
    }

    function strangerCloseJuniorDeposit(uint256 actorSeed) external {
        uint256 id = jv.openDepositEpochId();
        bool early = block.timestamp < jv.depositEpochOpenedAt(id) + jv.MAX_EPOCH_DURATION();
        (bool ok,) = _as(_actor(actorSeed), address(jv), abi.encodeWithSignature("closeDepositEpoch()"));
        if (ok && early) ghostEarlyStrangerClose = true;
    }

    function strangerFillJuniorDeposit(uint256 actorSeed, uint256 assetsSeed) external {
        uint256 id = jv.nextDepositEpochToFill();
        if (id >= jv.openDepositEpochId()) return;
        bool early = block.timestamp < jv.depositEpochClosedAt(id) + jv.FILL_GRACE();
        (, uint256 before,,,,) = jv.depositEpochs(id);
        (bool ok,) = _as(
            _actor(actorSeed),
            address(jv),
            abi.encodeWithSignature("fulfillDeposit(uint256,uint256)", id, _fillSize(assetsSeed))
        );
        (, uint256 afterFill,,,,) = jv.depositEpochs(id);
        if (ok && early && afterFill != before) ghostEarlyStrangerFill = true;
    }

    function strangerCloseJuniorRedeem(uint256 actorSeed) external {
        uint256 id = jv.openRedeemEpochId();
        bool early = block.timestamp < jv.redeemEpochOpenedAt(id) + jv.MAX_EPOCH_DURATION();
        (bool ok,) = _as(_actor(actorSeed), address(jv), abi.encodeWithSignature("closeRedeemEpoch()"));
        if (ok && early) ghostEarlyStrangerClose = true;
    }

    function strangerFillJuniorRedeem(uint256 actorSeed, uint256 assetsSeed) external {
        uint256 id = jv.nextRedeemEpochToFill();
        if (id >= jv.openRedeemEpochId()) return;
        bool early = block.timestamp < jv.redeemEpochClosedAt(id) + jv.FILL_GRACE();
        (, uint256 before,,,,) = jv.redeemEpochs(id);
        (bool ok,) = _as(
            _actor(actorSeed),
            address(jv),
            abi.encodeWithSignature("fulfillRedeem(uint256,uint256)", id, _fillSize(assetsSeed))
        );
        (, uint256 afterFill,,,,) = jv.redeemEpochs(id);
        if (ok && early && afterFill != before) ghostEarlyStrangerFill = true;
        if (ok && afterFill != before) _checkCoverage();
    }

    function warp(uint256 seed) external {
        HEVM.warp(block.timestamp + _b(seed, 0, 10 days));
    }

    function venueAccrue(uint256 bpsSeed) external {
        uint256 before = usdc.balanceOf(address(venue));
        venue.accrueBps(_b(bpsSeed, 0, 100));
        ghostMinted += usdc.balanceOf(address(venue)) - before;
    }

    function venueLose(uint256 seed) external {
        if (seed % 8 != 0) return;
        core.syncAll();
        uint256 parkedBefore = parking.totalAssets(address(core));
        uint256 seniorBefore = core.idle(true);
        uint256 juniorBefore = core.idle(false);
        venue.loseBps(_b(seed >> 8, 1, 50));
        uint256 parkedAfter = parking.totalAssets(address(core));
        uint256 coreLoss = parkedBefore > parkedAfter ? parkedBefore - parkedAfter : 0;
        if (juniorBefore > coreLoss + 2 && core.idle(true) + 2 < seniorBefore) ghostSeniorHitByIdleLoss = true;
    }

    function syncCore() external {
        core.syncAll();
    }

    function venueLiquidity(uint256 seed) external {
        uint256 mode = seed % 3;
        if (mode == 0) venue.setLiquidityCap(0);
        else if (mode == 1) venue.setLiquidityCap(_b(seed >> 8, 0, 2_000_000e6));
        else venue.setLiquidityCap(type(uint256).max);
    }

    function parkingRebalance() external {
        try parking.rebalance() {} catch {}
    }

    function donateToParking(uint256 amountSeed) external {
        uint256 amount = _b(amountSeed, 0, 10_000e6);
        usdc.mint(address(parking), amount);
        ghostMinted += amount;
    }

    function curatorPause() external {
        _as(curator, address(core), abi.encodeWithSignature("pause()"));
    }

    function governanceUnpause() external {
        try core.unpause() {} catch {}
    }

    function _holders() internal view returns (address[] memory h) {
        h = new address[](N + 6);
        for (uint256 i = 0; i < N; i++) {
            h[i] = address(actors[i]);
        }
        h[N] = address(curator);
        h[N + 1] = address(core);
        h[N + 2] = address(parking);
        h[N + 3] = address(venue);
        h[N + 4] = SINK;
        h[N + 5] = address(this);
    }

    function _who(uint256 i) internal view returns (address) {
        return i < N ? address(actors[i]) : address(curator);
    }

    function echidna_usdc_conserved_no_leak() external view returns (bool) {
        address[] memory h = _holders();
        uint256 sum;
        for (uint256 i = 0; i < h.length; i++) {
            sum += usdc.balanceOf(h[i]);
        }
        return sum == ghostMinted;
    }

    function echidna_I15_core_cash_reconciles() external view returns (bool) {
        (, uint256 sR,) = core.senior();
        (, uint256 jR, uint256 jP) = core.junior();
        return usdc.balanceOf(address(core)) == sR + jR + jP;
    }

    function echidna_I15_books_match_parking() external view returns (bool) {
        uint256 parked = parking.totalAssets(address(core));
        uint256 booked = core.idle(true) + core.idle(false);
        return booked <= parked && parked - booked <= 2;
    }

    function echidna_I16_vault_assets_equal_books() external view returns (bool) {
        return sv.totalAssets() == core.seniorAssets() && jv.totalAssets() == core.juniorAssets();
    }

    function echidna_I17_reserved_covers_owed() external view returns (bool) {
        (, uint256 sR,) = core.senior();
        (, uint256 jR,) = core.junior();
        uint256 sOwed;
        uint256 jOwed;
        for (uint256 id = 1; id < sv.openEpochId(); id++) {
            for (uint256 i = 0; i <= N; i++) {
                sOwed += sv.owedRedeemAssets(id, _who(i));
            }
        }
        for (uint256 id = 1; id < jv.openRedeemEpochId(); id++) {
            for (uint256 i = 0; i <= N; i++) {
                jOwed += jv.owedRedeemAssets(id, _who(i));
            }
        }
        return sR >= sOwed && jR >= jOwed;
    }

    function echidna_I18_pro_rata_sound() external view returns (bool) {
        for (uint256 id = 1; id < sv.openEpochId(); id++) {
            (uint256 total,, uint256 sharesF, uint256 assetsF,,) = sv.epochs(id);
            if (sharesF > total) return false;
            uint256 paid;
            uint256 frozen;
            for (uint256 i = 0; i <= N; i++) {
                paid += sv.claimedAssets(id, _who(i)) + sv.owedRedeemAssets(id, _who(i));
                frozen += sv.frozenAssets(id, _who(i));
            }
            if (paid > assetsF + frozen) return false;
        }
        for (uint256 id = 1; id < jv.openRedeemEpochId(); id++) {
            (uint256 total,, uint256 sharesF, uint256 assetsF,,) = jv.redeemEpochs(id);
            if (sharesF > total) return false;
            uint256 paid;
            uint256 frozen;
            for (uint256 i = 0; i <= N; i++) {
                paid += jv.claimedAssets(id, _who(i)) + jv.owedRedeemAssets(id, _who(i));
                frozen += jv.frozenRedeemAssets(id, _who(i));
            }
            if (paid > assetsF + frozen) return false;
        }
        for (uint256 id = 1; id < jv.openDepositEpochId(); id++) {
            (uint256 total,, uint256 assetsF, uint256 sharesF,,) = jv.depositEpochs(id);
            if (assetsF > total) return false;
            uint256 got;
            uint256 frozen;
            for (uint256 i = 0; i <= N; i++) {
                got += jv.claimedShares(id, _who(i)) + jv.owedDepositShares(id, _who(i));
                frozen += jv.frozenDepositShares(id, _who(i));
            }
            if (got > sharesF + frozen) return false;
        }
        return true;
    }

    function echidna_I19_batch_prices_within_bounds() external view returns (bool) {
        for (uint256 id = 1; id < sv.openEpochId(); id++) {
            (,, uint256 sharesF, uint256 assetsF, uint256 pps,) = sv.epochs(id);
            uint256 a = assetsF;
            uint256 s = sharesF;
            for (uint256 i = 0; i <= N; i++) {
                a += sv.frozenAssets(id, _who(i));
                s += sv.frozenShares(id, _who(i));
            }
            if (s > 0 && a * 1e18 / s > pps) return false;
        }
        for (uint256 id = 1; id < jv.openRedeemEpochId(); id++) {
            (,, uint256 sharesF, uint256 assetsF, uint256 pps,) = jv.redeemEpochs(id);
            uint256 a = assetsF;
            uint256 s = sharesF;
            for (uint256 i = 0; i <= N; i++) {
                a += jv.frozenRedeemAssets(id, _who(i));
                s += jv.frozenRedeemShares(id, _who(i));
            }
            if (s > 0 && a * 1e18 / s > pps) return false;
        }
        for (uint256 id = 1; id < jv.openDepositEpochId(); id++) {
            (,, uint256 assetsF, uint256 sharesF, uint256 pps,) = jv.depositEpochs(id);
            uint256 a = assetsF;
            uint256 s = sharesF;
            for (uint256 i = 0; i <= N; i++) {
                a += jv.frozenDepositAssets(id, _who(i));
                s += jv.frozenDepositShares(id, _who(i));
            }
            if (s > 0 && a * 1e18 / s < pps) return false;
        }
        return true;
    }

    function echidna_I30_batch_ledgers_balance() external view returns (bool) {
        for (uint256 id = 1; id <= sv.openEpochId(); id++) {
            (uint256 total, uint256 remaining, uint256 filled,,,) = sv.epochs(id);
            if (remaining != total - filled) return false;
        }
        for (uint256 id = 1; id <= jv.openRedeemEpochId(); id++) {
            (uint256 total, uint256 remaining, uint256 filled,,,) = jv.redeemEpochs(id);
            if (remaining != total - filled) return false;
        }
        for (uint256 id = 1; id <= jv.openDepositEpochId(); id++) {
            (uint256 total, uint256 remaining, uint256 filled,,,) = jv.depositEpochs(id);
            if (remaining != total - filled) return false;
        }
        return true;
    }

    function echidna_I31_fills_oldest_first() external view returns (bool) {
        uint256 ptr = sv.nextEpochToFill();
        for (uint256 id = 1; id < ptr; id++) {
            (, uint256 remaining,,,,) = sv.epochs(id);
            if (remaining != 0) return false;
        }
        for (uint256 id = ptr + 1; id < sv.openEpochId(); id++) {
            (,, uint256 filled,,,) = sv.epochs(id);
            if (filled != 0) return false;
        }
        ptr = jv.nextRedeemEpochToFill();
        for (uint256 id = 1; id < ptr; id++) {
            (, uint256 remaining,,,,) = jv.redeemEpochs(id);
            if (remaining != 0) return false;
        }
        for (uint256 id = ptr + 1; id < jv.openRedeemEpochId(); id++) {
            (,, uint256 filled,,,) = jv.redeemEpochs(id);
            if (filled != 0) return false;
        }
        ptr = jv.nextDepositEpochToFill();
        for (uint256 id = 1; id < ptr; id++) {
            (, uint256 remaining,,,,) = jv.depositEpochs(id);
            if (remaining != 0) return false;
        }
        for (uint256 id = ptr + 1; id < jv.openDepositEpochId(); id++) {
            (,, uint256 filled,,,) = jv.depositEpochs(id);
            if (filled != 0) return false;
        }
        return true;
    }

    function echidna_I32_queued_demand_matches() external view returns (bool) {
        uint256 expected;
        for (uint256 id = 1; id <= sv.openEpochId(); id++) {
            (, uint256 remaining,,, uint256 pps, bool closed) = sv.epochs(id);
            if (closed) expected += (remaining * pps + 1e18 - 1) / 1e18;
        }
        if (sv.queuedExitAssets() != expected || core.queuedExits(true) != expected) return false;
        expected = 0;
        for (uint256 id = 1; id <= jv.openRedeemEpochId(); id++) {
            (, uint256 remaining,,, uint256 pps, bool closed) = jv.redeemEpochs(id);
            if (closed) expected += (remaining * pps + 1e18 - 1) / 1e18;
        }
        return jv.queuedExitAssets() == expected && core.queuedExits(false) == expected;
    }

    function echidna_I33_done_batch_strands_nobody() external view returns (bool) {
        for (uint256 id = 1; id < sv.openEpochId(); id++) {
            (, uint256 remaining,,,,) = sv.epochs(id);
            if (remaining != 0) continue;
            for (uint256 i = 0; i <= N; i++) {
                if (sv.pendingRedeemRequest(id, _who(i)) != 0) return false;
            }
        }
        for (uint256 id = 1; id < jv.openRedeemEpochId(); id++) {
            (, uint256 remaining,,,,) = jv.redeemEpochs(id);
            if (remaining != 0) continue;
            for (uint256 i = 0; i <= N; i++) {
                if (jv.pendingRedeemRequest(id, _who(i)) != 0) return false;
            }
        }
        for (uint256 id = 1; id < jv.openDepositEpochId(); id++) {
            (, uint256 remaining,,,,) = jv.depositEpochs(id);
            if (remaining != 0) continue;
            for (uint256 i = 0; i <= N; i++) {
                if (jv.pendingDepositRequest(id, _who(i)) != 0) return false;
            }
        }
        return true;
    }

    function echidna_F02_no_stranded_request_slot() external view returns (bool) {
        return !ghostStrandedSlot;
    }

    function echidna_claims_never_overpay() external view returns (bool) {
        return !ghostClaimOverpaid;
    }

    function echidna_operator_windows_respected() external view returns (bool) {
        return !ghostEarlyStrangerClose && !ghostEarlyStrangerFill;
    }

    function echidna_junior_coverage_after_exit_fill() external view returns (bool) {
        return !ghostCoverageBreach;
    }

    function echidna_idle_loss_is_junior_first() external view returns (bool) {
        return !ghostSeniorHitByIdleLoss;
    }
}
