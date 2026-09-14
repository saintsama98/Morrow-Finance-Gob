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

// Morrow Finance — a single dated series: lends a basket of Midnight markets, tracks the face ledger, and
// runs the senior/junior waterfall to settlement.
// @author adiii.eth

/// @notice One series per maturity. Deployed as a standalone contract by SeriesFactory, not a clone, so every
/// series runs its own immutable code.
contract Series is IBuyCallback {
    using WadMath for uint256;

    // --- errors ------------------------------------------------------------------------------------------

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
    error NotResolved(uint256 i);
    error TransferMismatch();

    // --- events --------------------------------------------------------------------------------------------

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
    event SettlementStarted();
    event Collected(uint256 indexed i, uint256 received, uint256 proceedsCum, bool resolved);
    event WrittenOff(uint256 proceedsCum);
    event Waterfall(uint256 proceeds, uint256 seniorPaid, uint256 juniorPaid, uint256 fee, uint256 dSenior, uint256 dJunior);
    event Settled(uint256 proceeds);
    event FeeClaimed(uint256 amount);
    event BufferUpdated(uint256 indexed i, uint256 credit, uint256 faceNetAtT, int256 buffer, uint256 lossAtT);

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

    uint256 public seniorAllocated; // senior capital committed to this series
    uint256 public juniorAllocated; // junior capital committed to this series
    uint256 public tFinalize;

    mapping(uint256 => uint256) public filled; // cumulative assets filled per basket market
    mapping(uint256 => uint256) public unitsBought; // cumulative credit units bought per basket market
    mapping(uint256 => uint256) public feeCrystallized; // continuous-fee credit locked in per basket market
    uint256 public totalFilled; // total assets deployed, frozen at finalize

    mapping(bytes32 => bool) public rootRegistered; // for revocation bookkeeping only

    // pricing results, frozen at finalize
    uint256 public juniorShareWad; // junior's share of allocated capital
    uint256 public utilizationWad;
    uint256 public premiumWad;
    uint256 public seniorDeployed;
    uint256 public juniorDeployed;
    uint256 public poolRateWad;
    uint256 public seniorRateWad;
    uint256 public seniorClaim; // senior's fixed face claim at maturity
    uint256 public attachmentWad; // junior's loss-absorption band as a fraction of face
    uint256 public faceGross;
    uint256 public faceNetAtFinalize;
    bool public negativeCarry;

    // --- settlement ----------------------------------------------------------------------------------------

    uint256 public tSettled;
    mapping(uint256 => uint256) public collected; // cumulative usdc withdrawn from each basket market
    mapping(uint256 => bool) public resolved;
    mapping(uint256 => bool) public writtenOff;

    uint256 public paidS; // cumulative payout pushed to senior so far
    uint256 public paidJ; // cumulative payout pushed to junior so far
    uint256 public feeAccounted; // cumulative operator fee recognized by the waterfall so far
    uint256 public feeClaimed; // cumulative fee actually paid out to FEE_RECIPIENT so far (<= feeAccounted)

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

        // the only Midnight authorization a series ever grants, for the life of the contract.
        midnight.setIsAuthorized(setterRatifier, true, address(this));
    }

    // --- funding -------------------------------------------------------------------------------------------

    /// @notice Records the senior/junior split and parks the funding the core has already transferred in.
    /// @dev The core must have transferred `seniorAllocated_ + juniorAllocated_` usdc to this contract before
    /// calling.
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

    /// @notice Cancels an unfilled series and returns all funding to the core.
    /// @dev Callable by the allocator or the core's sentinel, only in DEPLOYING and only while nothing has
    /// filled. Parking yield is split pro rata between senior and junior, junior taking the rounding.
    function cancel() external nonReentrant inState(SeriesState.DEPLOYING) {
        require(msg.sender == ALLOCATOR || msg.sender == ISeriesCoreMinimal(CORE).sentinel(), NotCoreOrSentinel());
        require(totalFilled == 0, AlreadyFilled());

        state = SeriesState.CANCELED;
        _returnAllCashToCore();
    }

    /// @dev Shared by cancel() and finalize()'s zero-fill path. Pulls everything out of parking, splits pro
    /// rata by junior's share of allocated capital, and pushes it to the core in one receiveReturn call.
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

    // --- deployment (maker path) ----------------------------------------------------------------------------

    /// @dev Max price per unit for market i, floored down so the realized rate is never below the floor.
    /// rateFloorWad[i] is a term rate matching this series' own tenor, not annualized.
    function _priceMax(uint256 i) internal view returns (uint256) {
        return WadMath.WAD.mulDivDown(WadMath.WAD, WadMath.WAD + _rateFloorWad[i]);
    }

    /// @dev Highest tick, a multiple of the market's current tick spacing, whose price is at or below the
    /// floor price. priceToTick returns the *lowest* tick with price >= target; we step down one spacing
    /// increment unless that tick's price lands exactly on the floor.
    function _tickMax(uint256 i) internal view returns (uint256 tickMax) {
        bytes32 id = _marketIds[i];
        (,,,,,,,,,,,, uint8 tickSpacing) = MIDNIGHT.marketState(id);
        uint256 pMax = _priceMax(i);
        uint256 candidate = TickLib.priceToTick(pMax, tickSpacing);
        if (candidate == 0) return 0;
        if (TickLib.tickToPrice(candidate) == pMax) return candidate;
        return candidate - tickSpacing;
    }

    /// @notice Public read of the same max tick an offer must respect, for an off-chain allocator building
    /// offers to query directly instead of reimplementing the formula.
    function tickMaxFor(uint256 i) external view returns (uint256) {
        return _tickMax(i);
    }

    /// @notice The floor price for market i, below which this series will not lend.
    function priceMaxFor(uint256 i) external view returns (uint256) {
        return _priceMax(i);
    }

    /// @notice Registers a batch of maker offers by recomputing and ratifying their merkle root on chain.
    /// @dev `leaves` must be the full, padded leaf list of the offer tree in leaf order (a complete binary
    /// tree, so `leaves.length` is a power of two, at most 64). The root is recomputed on chain from the
    /// leaves, never trusted from the caller, matching the exact hashing Midnight's setter ratifier itself
    /// verifies — this is what stops a compromised allocator from hiding a bad leaf behind a root the series
    /// only proves membership against. Leaves whose maker isn't this series are ignored: the setter ratifier
    /// looks up ratification keyed by the offer's own maker, so a leaf naming another maker is harmless unless
    /// that maker separately ratified the same root.
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
    /// and node hashing so this can never diverge from what the setter ratifier itself verifies.
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

    /// @notice Revokes a previously registered offer root.
    function revokeOffers(bytes32 root) external onlyAllocator {
        SETTER_RATIFIER.setIsRootRatified(address(this), root, false);
        emit OffersRevoked(root);
    }

    /// @notice Marks an entire offer group as consumed, killing every offer in it at once.
    function cancelGroup(bytes32 group) external onlyAllocator {
        MIDNIGHT.setConsumed(group, type(uint128).max, address(this));
    }

    /// @notice Midnight's buyer callback, invoked when a third party fills one of this series' registered
    /// bids.
    /// @dev Entered from inside Midnight's own take() while the series holds no lock of its own, so this is
    /// nonReentrant against re-entry through other series entry points.
    function onBuy(bytes32 id, Market memory, uint256 buyerAssets, uint256 units, uint256 pendingFeeIncrease, address buyer, bytes memory data)
        external
        nonReentrant
        returns (bytes32)
    {
        require(msg.sender == address(MIDNIGHT), NotMidnight());
        require(buyer == address(this), NotSelfBuyer());

        // a no-op take (units 0, assets 0) must change no state, in every series state, even one Midnight
        // calls through a fully-consumed offer's callback.
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

    /// @notice Taker path: the allocator takes an existing sell offer below the floor price directly, paying
    /// from the series' own parked balance. Used when the maker path isn't available or a cheaper fill exists.
    /// @dev `receiverIfTakerIsSeller` is forced to `address(0)` because the series is always the buyer here —
    /// Midnight itself enforces that this must be zero in that case.
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

    // --- finalize --------------------------------------------------------------------------------------------

    /// @notice Locks in the series' deployed pricing (senior/junior split, premium, rates, claim) and returns
    /// undeployed capital to the core. Callable by the allocator any time, or by anyone once the deploy window
    /// has closed.
    /// @dev A zero-fill series is treated as cancelled: all cash goes back to the core and pricing is skipped.
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
            // parking lost value while deploying: the shortfall is taken pro rata by junior's share, junior
            // taking the rounding.
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

        totalFilled = kD; // freeze the deployed total for downstream accounting/settlement reads
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

    // --- accounting ------------------------------------------------------------------------------------------

    /// @dev Current net face value: each market's live credit minus its pending fee, plus what's already been
    /// collected from it. View-only; does not accrue/realize the latest loss factor on chain (that's sync's
    /// job).
    function _faceNetNow() internal view returns (uint256 fNetNow) {
        uint256 length = _marketIds.length;
        for (uint256 i = 0; i < length; i++) {
            (uint128 credit, uint128 pendingFee,) = MIDNIGHT.updatePositionView(_markets[i], _marketIds[i], address(this));
            fNetNow += (uint256(credit) - uint256(pendingFee)) + collected[i];
        }
    }

    /// @dev Realized face loss since finalize, floored at 0.
    function _faceLossNow() internal view returns (uint256) {
        uint256 fNetNow = _faceNetNow();
        return faceNetAtFinalize > fNetNow ? faceNetAtFinalize - fNetNow : 0;
    }

    /// @notice Writes the latest loss factor and fee accrual for market i on chain and emits the series-wide
    /// buffer view. Permissionless.
    function sync(uint256 i) external {
        MIDNIGHT.updatePosition(_markets[i], address(this));

        uint256 fNetNow = _faceNetNow();
        int256 bufferAtT = int256(fNetNow) - int256(seniorClaim);
        uint256 lossAtT = _faceLossNow();
        (uint128 creditI,,) = MIDNIGHT.updatePositionView(_markets[i], _marketIds[i], address(this));

        emit BufferUpdated(i, creditI, fNetNow, bufferAtT, lossAtT);
    }

    /// @dev Display-only NAV split. DEPLOYING values the parked + spent-on-fills balance pro rata by junior's
    /// share; SETTLED/CANCELED are always 0 (everything already pushed to the core); LOCKED/SETTLING use
    /// SeriesMath's nav (or the pass-through split) with elapsed time capped at the remaining tenor once
    /// SETTLING.
    function _navs() internal view returns (uint256 navS, uint256 navJ, uint256 feeAccrued) {
        if (state == SeriesState.DEPLOYING) {
            uint256 kAlloc = seniorAllocated + juniorAllocated;
            if (kAlloc == 0) return (0, 0, 0);
            uint256 value = PARKING.totalAssets(address(this)) + totalFilled;
            uint256 aWad = juniorAllocated.wDivDown(kAlloc);
            navS = value.mulDivDown(WadMath.WAD - aWad, WadMath.WAD);
            navJ = value - navS;
            return (navS, navJ, 0);
        }

        if (state == SeriesState.SETTLED || state == SeriesState.CANCELED) {
            return (0, 0, 0);
        }

        // T > tFinalize in every normal path (tDeployEnd < T - MIN_TERM is enforced at construction, and
        // finalize can only run during DEPLOYING, i.e. before tDeployEnd). But nothing forces finalize() to be
        // called promptly -- anyone can call it after tDeployEnd, and if nobody does until at or after T, tau
        // would naively underflow. Floor it at 0: nav then shows no accretion yet rather than reverting: a
        // safe, conservative display value for a degenerate case that never affects actual settlement (collect
        // /settle read real proceeds, not this estimate).
        uint256 tau = T > tFinalize ? T - tFinalize : 0;
        uint256 elapsed = state == SeriesState.SETTLING ? tau : block.timestamp - tFinalize;
        uint256 faceLoss = _faceLossNow();

        if (passThrough) {
            uint256 s = elapsed > tau ? tau : elapsed;
            uint256 accretion = (tau > 0 && faceNetAtFinalize >= totalFilled)
                ? (faceNetAtFinalize - totalFilled).mulDivDown(s, tau)
                : 0;
            uint256 grossV = totalFilled + accretion;
            uint256 v = grossV > faceLoss ? grossV - faceLoss : 0;
            (navS, navJ) = SeriesMath.navPassThrough(v, seniorDeployed, totalFilled);
            return (navS, navJ, 0);
        }

        return SeriesMath.nav(
            elapsed, tau, totalFilled, faceNetAtFinalize, faceLoss, seniorDeployed, seniorClaim, juniorDeployed, THETA_WAD
        );
    }

    /// @notice The current senior/junior NAV split and accrued fee, for display.
    function navs() external view returns (uint256 navS, uint256 navJ, uint256 feeAccrued) {
        return _navs();
    }

    /// @notice Writes the latest loss factor/fee accrual for every basket market on chain first, then returns
    /// the same computation navs() would.
    /// @dev updatePositionView already reflects the live value even before this call, so the effect here is on
    /// Midnight's own storage, not on the result returned.
    function navsSynced() external returns (uint256 navS, uint256 navJ, uint256 feeAccrued) {
        uint256 length = _marketIds.length;
        for (uint256 i = 0; i < length; i++) {
            MIDNIGHT.updatePosition(_markets[i], address(this));
        }
        return _navs();
    }

    // --- settlement ----------------------------------------------------------------------------------------

    /// @notice Moves the series from LOCKED to SETTLING once maturity has been reached.
    function startSettlement() external inState(SeriesState.LOCKED) {
        require(block.timestamp >= T, TooEarly(block.timestamp));
        state = SeriesState.SETTLING;
        emit SettlementStarted();
    }

    /// @notice Pulls whatever is currently withdrawable from basket market i into parking.
    /// @dev Callable in LOCKED, SETTLING or SETTLED — collecting before maturity is allowed on purpose:
    /// withdrawable liquidity is shared by all lenders first-come-first-served, and taking it at par is
    /// strictly good for the series. A receipt after SETTLED is a recovery and reruns the waterfall
    /// immediately.
    function collect(uint256 i) external nonReentrant returns (uint256 received) {
        require(
            state == SeriesState.LOCKED || state == SeriesState.SETTLING || state == SeriesState.SETTLED,
            WrongState(SeriesState.SETTLING, state)
        );

        bytes32 id = _marketIds[i];
        Market memory m = _markets[i];

        MIDNIGHT.updatePosition(m, address(this));
        (uint128 credit,,) = MIDNIGHT.updatePositionView(m, id, address(this));
        uint128 withdrawableNow = MIDNIGHT.withdrawable(id);
        uint256 units = uint256(credit) < uint256(withdrawableNow) ? uint256(credit) : uint256(withdrawableNow);
        if (units == 0) return 0;

        uint256 balBefore = IERC20Like(USDC).balanceOf(address(this));
        MIDNIGHT.withdraw(m, units, address(this), address(this));
        received = IERC20Like(USDC).balanceOf(address(this)) - balBefore;
        require(received == units, TransferMismatch());

        collected[i] += received;
        ERC20Lib.safeApprove(USDC, address(PARKING), received);
        PARKING.deposit(received);

        (uint128 creditAfter,,) = MIDNIGHT.updatePositionView(m, id, address(this));
        if (block.timestamp > T && creditAfter == 0) resolved[i] = true;

        emit Collected(i, received, _proceeds(), resolved[i]);

        if (state == SeriesState.SETTLED) _rerunWaterfall();
    }

    /// @notice Settles the series once every basket market has resolved. Callable by anyone.
    function settle() external inState(SeriesState.SETTLING) {
        uint256 length = _marketIds.length;
        for (uint256 i = 0; i < length; i++) {
            require(resolved[i], NotResolved(i));
        }
        _rerunWaterfall();
        state = SeriesState.SETTLED;
        tSettled = block.timestamp;
        emit Settled(_proceeds());
    }

    /// @notice Writes off every still-unresolved basket market once the write-off delay has passed, then
    /// settles.
    /// @dev Time-based only. Written-off markets keep their credit; collect() stays callable on them forever,
    /// and every later receipt flows through _rerunWaterfall() as a recovery.
    function writeOff() external inState(SeriesState.SETTLING) {
        require(block.timestamp >= T + D_WRITE_OFF, TooEarly(block.timestamp));
        uint256 length = _marketIds.length;
        for (uint256 i = 0; i < length; i++) {
            if (!resolved[i]) writtenOff[i] = true;
        }
        _rerunWaterfall();
        state = SeriesState.SETTLED;
        tSettled = block.timestamp;
        emit WrittenOff(_proceeds());
    }

    /// @dev Cumulative proceeds ever received by this series. Cash already pushed to the core (paidS + paidJ)
    /// and fee already paid out (feeClaimed) are never double counted since they're added back explicitly, not
    /// re-read from a balance that no longer holds them.
    function _proceeds() internal view returns (uint256) {
        return IERC20Like(USDC).balanceOf(address(this)) + PARKING.totalAssets(address(this)) + paidS + paidJ + feeClaimed;
    }

    /// @dev The cumulative waterfall rerun. Correct for recoveries automatically because senior/junior/fee
    /// payouts are pure functions of cumulative proceeds; only the *delta* since the last rerun is pushed out.
    function _rerunWaterfall() internal {
        uint256 p = _proceeds();
        uint256 xs;
        uint256 xj;
        uint256 fee;

        if (passThrough) {
            (xs, xj) = SeriesMath.waterfallPassThrough(p, seniorDeployed, totalFilled);
        } else {
            (xs, xj, fee) = SeriesMath.waterfall(p, seniorClaim, juniorDeployed, THETA_WAD);
        }

        uint256 dSenior = xs - paidS;
        uint256 dJunior = xj - paidJ;
        uint256 dFee = fee - feeAccounted;

        paidS = xs;
        paidJ = xj;
        feeAccounted = fee;

        emit Waterfall(p, xs, xj, fee, dSenior, dJunior);

        // receivePayout must fire on every rerun, even a zero-delta one (e.g. a total loss where proceeds stay
        // 0 forever): it's the core's only signal that this series just settled, and it's what lets the core
        // apply its cross-series loss backstop when senior comes up short. Only the token transfer itself is
        // conditional.
        uint256 total = dSenior + dJunior;
        if (total > 0) {
            PARKING.withdraw(total, address(this));
            SafeTransferLib.safeTransfer(USDC, CORE, total);
        }
        ISeriesCoreMinimal(CORE).receivePayout(dSenior, dJunior);
        dFee; // recognized above via feeAccounted; claimFee() reads (feeAccounted - feeClaimed) directly
    }

    /// @notice Pays the operator's accrued, unclaimed fee to FEE_RECIPIENT. Callable by anyone.
    function claimFee() external nonReentrant {
        uint256 owed = feeAccounted - feeClaimed;
        if (owed == 0) return;
        feeClaimed += owed;
        PARKING.withdraw(owed, address(this));
        SafeTransferLib.safeTransfer(USDC, FEE_RECIPIENT, owed);
        emit FeeClaimed(owed);
    }

    // --- views -----------------------------------------------------------------------------------------------

    /// @notice The basket's Midnight market ids.
    function marketIds() external view returns (bytes32[] memory) {
        return _marketIds;
    }

    /// @notice The basket's canonical Midnight market configs, as snapshotted at deployment.
    function markets() external view returns (Market[] memory) {
        return _markets;
    }
}

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
}
