// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Market, Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {IdLib} from "@morpho-org/midnight/src/libraries/IdLib.sol";
import {HashLib} from "@morpho-org/midnight/src/ratifiers/libraries/HashLib.sol";
import {ISetterRatifier} from "@morpho-org/midnight/src/ratifiers/interfaces/ISetterRatifier.sol";
import {TickLib, MAX_TICK} from "@morpho-org/midnight/src/libraries/TickLib.sol";
import {SafeTransferLib} from "@morpho-org/midnight/src/libraries/SafeTransferLib.sol";
import {ERC20Lib} from "@morpho-org/midnight/src/periphery/libraries/ERC20Lib.sol";

import {IMidnightMinimal} from "../interfaces/IMidnightMinimal.sol";
import {IBuyCallback} from "../interfaces/IBuyCallback.sol";
import {ISeriesCoreMinimal} from "../interfaces/ISeriesCoreMinimal.sol";
import {SeriesParams, SeriesState} from "../interfaces/ISeries.sol";
import {IParking} from "../parking/IParking.sol";
import {WadMath} from "../libraries/WadMath.sol";
import {PremiumCurve} from "../libraries/PremiumCurve.sol";
import {SeriesMath} from "../libraries/SeriesMath.sol";

/// @dev One series per maturity (sections 6, 8, 10, 11). Lends into a basket of Midnight markets, keeps the
/// face ledger, and (in a later milestone) runs the waterfall. Deployed as a full contract by SeriesFactory,
/// not a clone -- every series is immutable code (section 4).
contract Series is IBuyCallback {
    using WadMath for uint256;

    // --- errors (section 18 subset relevant here) -----------------------------------------------------------

    error WrongState(SeriesState expected, SeriesState actual);
    error TooEarly(uint256 at);
    error TooLate(uint256 at);
    error NotAllocator();
    error NotCoreOrSentinel();
    error NotMidnight();
    error NotSelfBuyer();
    error CapExceeded(uint256 i);
    error PriceFloorBreached(uint256 i, uint256 priceWad, uint256 maxWad);
    error ZeroUnits();
    error UnitsMismatch();
    error MarketMismatch(bytes32 expected, bytes32 actual);
    error AlreadyFilled();
    error InvalidTree();
    error InvalidLeaf(uint256 index);
    error Reentrancy();
    error InsufficientCash();
    error CapacityBelowAllocation();
    error InvalidTiming();

    // --- events (section 17 subset) --------------------------------------------------------------------------

    event Initialized(uint256 seniorAllocated, uint256 juniorAllocated);
    event OffersRegistered(bytes32 root, uint64 expiry, uint256 leafCount);
    event OffersRevoked(bytes32 root);
    event Filled(uint256 indexed i, uint256 assets, uint256 units, uint256 priceWad, bool maker);
    event Finalized(
        uint256 kDeployed,
        uint256 seniorDeployed,
        uint256 juniorDeployed,
        uint256 faceGross,
        uint256 faceNet,
        uint256 juniorShareWad,
        uint256 utilizationWad,
        uint256 premiumWad,
        uint256 poolRateWad,
        uint256 seniorRateWad,
        uint256 seniorClaim,
        uint256 attachmentWad,
        bool passThrough,
        bool negativeCarry
    );
    event Canceled(uint256 toSenior, uint256 toJunior);

    // --- immutables -------------------------------------------------------------------------------------------

    IMidnightMinimal public immutable MIDNIGHT;
    ISetterRatifier public immutable SETTER_RATIFIER;
    address public immutable USDC;
    address public immutable CORE;
    IParking public immutable PARKING;
    address public immutable ALLOCATOR;
    address public immutable FEE_RECIPIENT;

    uint256 public immutable COV_WAD;
    uint256 public immutable PI0_WAD;
    uint256 public immutable PIT_WAD;
    uint256 public immutable PI1_WAD;
    uint256 internal constant U_T_WAD = 0.9e18;
    uint256 internal constant MIN_TERM = 14 days;

    uint64 public immutable T_DEPLOY_END;
    uint64 public immutable D_WRITE_OFF;
    uint256 public immutable K_MIN_ASSETS;
    uint256 public immutable THETA_WAD;
    bytes32 public immutable ATTESTATION_HASH;

    uint256 public immutable T; // maturity, common to every market in the basket
    uint256 public immutable T_OPEN;

    // --- basket, parallel-indexed by i -----------------------------------------------------------------------

    bytes32[] internal _marketIds;
    Market[] internal _markets;
    uint256[] internal _rateFloorWad;
    uint256[] internal _marketCapAssets;

    // --- mutable state ------------------------------------------------------------------------------------

    SeriesState public state;
    bool public passThrough;
    bool internal _entered;

    uint256 public seniorAllocated; // S
    uint256 public juniorAllocated; // J
    uint256 public tFinalize;

    mapping(uint256 => uint256) public filled; // filled_i, assets
    mapping(uint256 => uint256) public unitsBought; // U_i
    mapping(uint256 => uint256) public feeCrystallized; // feeCrystallized_i
    uint256 public totalFilled; // K_d, set at finalize

    mapping(bytes32 => bool) public rootRegistered; // for revocation bookkeeping only

    // pricing results, frozen at finalize (section 9.3)
    uint256 public juniorShareWad; // a
    uint256 public utilizationWad; // u
    uint256 public premiumWad; // pi
    uint256 public seniorDeployed; // S_d
    uint256 public juniorDeployed; // J_d
    uint256 public poolRateWad; // r_pool
    uint256 public seniorRateWad; // r_s
    uint256 public seniorClaim; // C_S
    uint256 public attachmentWad; // A_F
    uint256 public faceGross; // F
    uint256 public faceNetAtFinalize; // F_net at tFinalize
    bool public negativeCarry;

    // --- modifiers -----------------------------------------------------------------------------------------

    modifier nonReentrant() {
        require(!_entered, Reentrancy());
        _entered = true;
        _;
        _entered = false;
    }

    modifier onlyAllocator() {
        require(msg.sender == ALLOCATOR, NotAllocator());
        _;
    }

    modifier inState(SeriesState expected) {
        require(state == expected, WrongState(expected, state));
        _;
    }

    constructor(
        IMidnightMinimal midnight,
        address setterRatifier,
        address usdc,
        address core,
        Market[] memory basketMarkets,
        SeriesParams memory p
    ) {
        MIDNIGHT = midnight;
        SETTER_RATIFIER = ISetterRatifier(setterRatifier);
        USDC = usdc;
        CORE = core;
        PARKING = p.parking;
        ALLOCATOR = p.allocator;
        FEE_RECIPIENT = p.feeRecipient;

        COV_WAD = p.covWad;
        PI0_WAD = p.pi0Wad;
        PIT_WAD = p.piTWad;
        PI1_WAD = p.pi1Wad;
        T_DEPLOY_END = p.tDeployEnd;
        D_WRITE_OFF = p.dWriteOff;
        K_MIN_ASSETS = p.kMinAssets;
        THETA_WAD = p.thetaWad;
        ATTESTATION_HASH = p.offchainAttestationHash;

        _marketIds = p.marketIds;
        _rateFloorWad = p.rateFloorWad;
        _marketCapAssets = p.marketCapAssets;

        uint256 length = basketMarkets.length;
        for (uint256 i = 0; i < length; i++) {
            _markets.push(basketMarkets[i]);
        }

        T = basketMarkets[0].maturity; // eligibility already required every market to share this maturity
        T_OPEN = block.timestamp;

        require(block.timestamp < p.tDeployEnd, InvalidTiming());
        require(T >= MIN_TERM && p.tDeployEnd < T - MIN_TERM, InvalidTiming());

        // section 10.3, guard G3: the only midnight authorization a series ever grants, ever.
        midnight.setIsAuthorized(setterRatifier, true, address(this));
    }

    // --- section 8: funding -----------------------------------------------------------------------------

    /// @dev Core has already transferred `seniorAllocated_ + juniorAllocated_` usdc to this contract before
    /// calling; this just records the split and parks the cash (section 8.2).
    function initialize(uint256 seniorAllocated_, uint256 juniorAllocated_) external inState(SeriesState.DEPLOYING) {
        require(msg.sender == CORE, NotCoreOrSentinel());

        uint256 kAlloc = seniorAllocated_ + juniorAllocated_;
        uint256 sumCaps;
        uint256 length = _marketCapAssets.length;
        for (uint256 i = 0; i < length; i++) {
            sumCaps += _marketCapAssets[i];
        }
        require(sumCaps >= kAlloc, CapacityBelowAllocation());

        seniorAllocated = seniorAllocated_;
        juniorAllocated = juniorAllocated_;

        uint256 balance = IERC20Like(USDC).balanceOf(address(this));
        require(balance >= kAlloc, InsufficientCash());

        ERC20Lib.safeApprove(USDC, address(PARKING), kAlloc);
        PARKING.deposit(kAlloc);

        emit Initialized(seniorAllocated_, juniorAllocated_);
    }

    /// @dev section 8.5: allocator or sentinel, only in DEPLOYING and only while nothing has filled. Returns
    /// all cash to the core, split by S and J (parking yield split by a, junior taking the rounding).
    function cancel() external nonReentrant inState(SeriesState.DEPLOYING) {
        require(msg.sender == ALLOCATOR || msg.sender == ISeriesCoreMinimal(CORE).sentinel(), NotCoreOrSentinel());
        require(totalFilled == 0, AlreadyFilled());

        state = SeriesState.CANCELED;
        _returnAllCashToCore();
    }

    /// @dev Shared by cancel() and finalize()'s K_d == 0 path (section 11: "if K_d == 0: return all cash to
    /// the core (as in cancel)"). Pulls everything out of parking, splits pro rata by a = J/(S+J), and pushes
    /// it to the core in one receiveReturn call.
    function _returnAllCashToCore() internal {
        uint256 parked = PARKING.totalAssets(address(this));
        if (parked > 0) PARKING.withdraw(parked, address(this));
        uint256 balance = IERC20Like(USDC).balanceOf(address(this));

        uint256 kAlloc = seniorAllocated + juniorAllocated;
        uint256 aWad = kAlloc == 0 ? 0 : juniorAllocated.wDivDown(kAlloc);
        uint256 toSenior = balance.mulDivDown(WadMath.WAD - aWad, WadMath.WAD);
        uint256 toJunior = balance - toSenior;

        if (balance > 0) SafeTransferLib.safeTransfer(USDC, CORE, balance);
        ISeriesCoreMinimal(CORE).receiveReturn(toSenior, toJunior);

        emit Canceled(toSenior, toJunior);
    }

    // --- section 10: deployment (maker path) --------------------------------------------------------------

    /// @dev section 10.2: max price per unit for market i, floored down so the realized rate is never below
    /// the floor. rateFloorWad[i] is a term rate (matching this series' own tau), not annualized.
    function _priceMax(uint256 i) internal view returns (uint256) {
        return WadMath.WAD.mulDivDown(WadMath.WAD, WadMath.WAD + _rateFloorWad[i]);
    }

    /// @dev section 10.2/10.4 step 1: highest tick, a multiple of the market's current tick spacing, whose
    /// price is at or below P_max_i. priceToTick returns the *lowest* tick with price >= target; we step down
    /// one spacing increment unless that tick's price lands exactly on P_max_i.
    function _tickMax(uint256 i) internal view returns (uint256 tickMax) {
        bytes32 id = _marketIds[i];
        (,,,,,,,,,,,, uint8 tickSpacing) = MIDNIGHT.marketState(id);
        uint256 pMax = _priceMax(i);
        uint256 candidate = TickLib.priceToTick(pMax, tickSpacing);
        if (candidate == 0) return 0;
        if (TickLib.tickToPrice(candidate) == pMax) return candidate;
        return candidate - tickSpacing;
    }

    /// @dev Public read of the same tick-max an offer must respect (section 10.2), so an allocator building
    /// offers off chain -- or a test -- can query it directly instead of reimplementing the formula.
    function tickMaxFor(uint256 i) external view returns (uint256) {
        return _tickMax(i);
    }

    function priceMaxFor(uint256 i) external view returns (uint256) {
        return _priceMax(i);
    }

    /// @dev section 10.4 step 2. `leaves` must be the full, padded leaf list of the offer tree in leaf order
    /// (a complete binary tree, so `leaves.length` is a power of two, at most 64). The root is recomputed on
    /// chain from the leaves (never trusted from the caller), matching the exact hashing of HashLib -- this is
    /// what stops a compromised allocator from hiding a bad leaf behind a root the series only proves
    /// membership against. Leaves whose maker isn't this series are ignored: the setter ratifier looks up
    /// `isRootRatified[offer.maker][root]`, keyed by the offer's own maker, so a leaf naming another maker is
    /// harmless unless that maker separately ratified the same root.
    function registerOffers(bytes32 root, Offer[] calldata leaves) external onlyAllocator inState(SeriesState.DEPLOYING) {
        require(block.timestamp <= T_DEPLOY_END, TooLate(block.timestamp));

        bytes32 computedRoot = _computeRoot(leaves);
        require(computedRoot == root, InvalidTree());

        uint256 length = leaves.length;
        for (uint256 idx = 0; idx < length; idx++) {
            Offer calldata offer = leaves[idx];
            if (offer.maker != address(this)) continue;
            _validateSelfOffer(offer, idx);
        }

        rootRegistered[root] = true;
        SETTER_RATIFIER.setIsRootRatified(address(this), root, true);

        emit OffersRegistered(root, uint64(block.timestamp), length);
    }

    function _validateSelfOffer(Offer calldata offer, uint256 leafIndex) internal view {
        uint256 i = _marketIndexOf(offer);
        require(offer.buy, InvalidLeaf(leafIndex));
        require(offer.expiry <= T_DEPLOY_END, InvalidLeaf(leafIndex));
        require(offer.callback == address(this), InvalidLeaf(leafIndex));
        require(offer.ratifier == address(SETTER_RATIFIER), InvalidLeaf(leafIndex));
        require(!offer.reduceOnly, InvalidLeaf(leafIndex));
        require(abi.decode(offer.callbackData, (uint256)) == i, InvalidLeaf(leafIndex));
        require(offer.tick <= _tickMax(i), PriceFloorBreached(i, offer.tick, _tickMax(i)));
    }

    function _marketIndexOf(Offer calldata offer) internal view returns (uint256) {
        bytes32 id = IdLib.toId(offer.market);
        uint256 length = _marketIds.length;
        for (uint256 i = 0; i < length; i++) {
            if (_marketIds[i] == id) return i;
        }
        revert MarketMismatch(bytes32(0), id);
    }

    /// @dev Rebuilds the root of a complete binary tree from its leaves, bottom-up, using Midnight's own leaf
    /// and node hashing (HashLib) so this can never diverge from what the setter ratifier itself verifies.
    function _computeRoot(Offer[] calldata leaves) internal pure returns (bytes32) {
        uint256 n = leaves.length;
        require(n > 0 && (n & (n - 1)) == 0 && n <= 64, InvalidTree());

        bytes32[] memory level = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            level[i] = HashLib.hashOffer(leaves[i]);
        }
        while (n > 1) {
            uint256 half = n / 2;
            for (uint256 i = 0; i < half; i++) {
                level[i] = HashLib.hashNode(level[2 * i], level[2 * i + 1]);
            }
            n = half;
        }
        return level[0];
    }

    function revokeOffers(bytes32 root) external onlyAllocator {
        SETTER_RATIFIER.setIsRootRatified(address(this), root, false);
        emit OffersRevoked(root);
    }

    function cancelGroup(bytes32 group) external onlyAllocator {
        MIDNIGHT.setConsumed(group, type(uint128).max, address(this));
    }

    /// @dev section 10.4 step 4/5: Midnight's buyer callback. Entered from inside a third party's take of one
    /// of our registered bids -- the series lock is free at this point (guard G6), so this is nonReentrant.
    function onBuy(bytes32 id, Market memory, uint256 buyerAssets, uint256 units, uint256 pendingFeeIncrease, address buyer, bytes memory data)
        external
        nonReentrant
        returns (bytes32)
    {
        require(msg.sender == address(MIDNIGHT), NotMidnight());
        require(buyer == address(this), NotSelfBuyer());

        // invariant I28: a no-op take (units 0, assets 0) changes no state, in every series state, even one
        // Midnight calls through a fully-consumed offer's callback.
        if (units == 0 && buyerAssets == 0) return bytes32(keccak256("morpho.midnight.callbackSuccess"));

        require(state == SeriesState.DEPLOYING && block.timestamp <= T_DEPLOY_END, WrongState(SeriesState.DEPLOYING, state));
        require(units > 0, ZeroUnits());

        uint256 i = abi.decode(data, (uint256));
        require(id == _marketIds[i], MarketMismatch(_marketIds[i], id));

        uint256 priceWad = buyerAssets.mulDivUp(WadMath.WAD, units);
        require(priceWad <= _priceMax(i), PriceFloorBreached(i, priceWad, _priceMax(i)));

        uint256 kAlloc = seniorAllocated + juniorAllocated;
        require(filled[i] + buyerAssets <= _marketCapAssets[i], CapExceeded(i));
        require(totalFilled + buyerAssets <= kAlloc, CapExceeded(i));

        PARKING.withdraw(buyerAssets, address(this));
        ERC20Lib.safeApprove(USDC, address(MIDNIGHT), buyerAssets);

        filled[i] += buyerAssets;
        unitsBought[i] += units;
        feeCrystallized[i] += pendingFeeIncrease;
        totalFilled += buyerAssets;

        emit Filled(i, buyerAssets, units, priceWad, true);
        return bytes32(keccak256("morpho.midnight.callbackSuccess"));
    }

    /// @dev section 10.5, taker path: the allocator has found an existing sell offer (ask) below the floor
    /// price and the series takes it directly, paying from its own parked balance. Used when the maker path
    /// (the default) isn't available or a cheaper fill exists. `receiverIfTakerIsSeller` is forced to
    /// `address(0)` because the series is the buyer -- Midnight itself enforces that this must be zero in
    /// that case.
    function deployTake(uint256 i, Offer calldata offer, bytes calldata ratifierData, uint256 units)
        external
        onlyAllocator
        nonReentrant
        inState(SeriesState.DEPLOYING)
    {
        require(block.timestamp <= T_DEPLOY_END, TooLate(block.timestamp));
        bytes32 id = _marketIds[i];
        require(IdLib.toId(offer.market) == id && !offer.buy, MarketMismatch(id, IdLib.toId(offer.market)));

        uint256 ttm = T > block.timestamp ? T - block.timestamp : 0;
        uint256 fee = MIDNIGHT.settlementFee(id, ttm);
        uint256 price = TickLib.tickToPrice(offer.tick);
        uint256 maxAssets = units.mulDivUp(price + fee, WadMath.WAD);

        uint256 kAlloc = seniorAllocated + juniorAllocated;
        require(filled[i] + maxAssets <= _marketCapAssets[i], CapExceeded(i));
        require(totalFilled + maxAssets <= kAlloc, CapExceeded(i));

        PARKING.withdraw(maxAssets, address(this));
        ERC20Lib.safeApprove(USDC, address(MIDNIGHT), maxAssets);

        (uint128 creditBefore, uint128 pendingFeeBefore,) = MIDNIGHT.updatePositionView(offer.market, id, address(this));
        (uint256 buyerAssets,) = MIDNIGHT.take(offer, ratifierData, units, address(this), address(0), address(0), "");
        (uint128 creditAfter, uint128 pendingFeeAfter,) = MIDNIGHT.updatePositionView(offer.market, id, address(this));

        require(uint256(creditAfter) - uint256(creditBefore) == units, UnitsMismatch());

        uint256 priceWad = buyerAssets.mulDivUp(WadMath.WAD, units);
        require(priceWad <= _priceMax(i), PriceFloorBreached(i, priceWad, _priceMax(i)));

        if (maxAssets > buyerAssets) {
            uint256 leftover = maxAssets - buyerAssets;
            ERC20Lib.safeApprove(USDC, address(PARKING), leftover);
            PARKING.deposit(leftover);
        }
        ERC20Lib.safeApprove(USDC, address(MIDNIGHT), 0);

        filled[i] += buyerAssets;
        unitsBought[i] += units;
        feeCrystallized[i] += uint256(pendingFeeAfter) - uint256(pendingFeeBefore);
        totalFilled += buyerAssets;

        emit Filled(i, buyerAssets, units, priceWad, false);
    }

    // --- section 11: finalize ------------------------------------------------------------------------------

    function finalize() external nonReentrant inState(SeriesState.DEPLOYING) {
        require(msg.sender == ALLOCATOR || block.timestamp > T_DEPLOY_END, NotAllocator());

        uint256 kD = totalFilled;
        if (kD == 0) {
            state = SeriesState.CANCELED;
            _returnAllCashToCore();
            return;
        }

        passThrough = kD < K_MIN_ASSETS;

        uint256 length = _marketIds.length;
        uint256 fGross;
        uint256 fNet;
        for (uint256 i = 0; i < length; i++) {
            fGross += unitsBought[i];
            fNet += unitsBought[i] - feeCrystallized[i];
        }
        faceGross = fGross;
        faceNetAtFinalize = fNet;

        uint256 kAlloc = seniorAllocated + juniorAllocated;
        uint256 aWad = juniorAllocated.wDivDown(kAlloc);
        juniorShareWad = aWad;
        utilizationWad = COV_WAD.wDivUp(aWad);
        premiumWad = PremiumCurve.pi(utilizationWad, U_T_WAD, PI0_WAD, PIT_WAD, PI1_WAD);

        SeriesMath.PricingResult memory r = SeriesMath.price(kD, aWad, fNet, premiumWad);
        seniorDeployed = r.seniorDeployed;
        juniorDeployed = r.juniorDeployed;
        poolRateWad = r.poolRateWad;
        seniorRateWad = r.seniorRateWad;
        seniorClaim = r.seniorClaim;
        attachmentWad = r.attachmentWad;
        negativeCarry = r.negativeCarry;

        uint256 returnS = seniorAllocated - r.seniorDeployed;
        uint256 returnJ = juniorAllocated - r.juniorDeployed;

        uint256 parked = PARKING.totalAssets(address(this));
        if (parked > 0) PARKING.withdraw(parked, address(this));
        uint256 balance = IERC20Like(USDC).balanceOf(address(this));

        uint256 undeployed = returnS + returnJ;
        uint256 extraS;
        uint256 extraJ;
        if (balance >= undeployed) {
            uint256 extra = balance - undeployed;
            extraS = extra.mulDivDown(WadMath.WAD - aWad, WadMath.WAD);
            extraJ = extra - extraS;
        } else {
            // parking lost value while deploying: the shortfall is taken pro rata by a, junior taking the
            // rounding (section 11).
            uint256 shortfall = undeployed - balance;
            uint256 shortfallS = shortfall.mulDivDown(WadMath.WAD - aWad, WadMath.WAD);
            returnS -= shortfallS;
            returnJ -= (shortfall - shortfallS);
        }

        uint256 totalToSenior = returnS + extraS;
        uint256 totalToJunior = returnJ + extraJ;
        if (totalToSenior + totalToJunior > 0) {
            SafeTransferLib.safeTransfer(USDC, CORE, totalToSenior + totalToJunior);
        }
        ISeriesCoreMinimal(CORE).receiveReturn(totalToSenior, totalToJunior);

        totalFilled = kD; // freeze K_d for downstream reads (accounting/settlement, later milestones)
        tFinalize = block.timestamp;
        state = SeriesState.LOCKED;

        emit Finalized(
            kD,
            r.seniorDeployed,
            r.juniorDeployed,
            fGross,
            fNet,
            aWad,
            utilizationWad,
            premiumWad,
            r.poolRateWad,
            r.seniorRateWad,
            r.seniorClaim,
            r.attachmentWad,
            passThrough,
            r.negativeCarry
        );
    }

    // --- views -----------------------------------------------------------------------------------------------

    function marketIds() external view returns (bytes32[] memory) {
        return _marketIds;
    }

    function markets() external view returns (Market[] memory) {
        return _markets;
    }
}

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
}
