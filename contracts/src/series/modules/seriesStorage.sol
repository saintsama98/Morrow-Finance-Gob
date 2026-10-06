// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: a series' frozen terms, lifecycle state, fill and settlement ledgers, errors and events.
// @author adiii.eth

pragma solidity 0.8.34;

import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {ISetterRatifier} from "@morpho-org/midnight/src/ratifiers/interfaces/ISetterRatifier.sol";
import {iMidnightMinimal} from "../../interfaces/iMidnightMinimal.sol";
import {SeriesParams, SeriesState} from "../../interfaces/iSeries.sol";
import {iParking} from "../../parking/iParking.sol";

/// @notice Storage, immutables, events and errors of a series.
abstract contract seriesStorage {
    uint256 internal constant U_T_WAD = 0.9e18;
    uint256 internal constant MIN_TERM = 14 days;

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
    event Waterfall(
        uint256 proceeds, uint256 seniorPaid, uint256 juniorPaid, uint256 fee, uint256 dSenior, uint256 dJunior
    );
    event Settled(uint256 proceeds);
    event FeeClaimed(uint256 amount);
    event BufferUpdated(uint256 indexed i, uint256 credit, uint256 faceNetAtT, int256 buffer, uint256 lossAtT);

    iMidnightMinimal public immutable MIDNIGHT;
    ISetterRatifier public immutable SETTER_RATIFIER;
    address public immutable USDC;
    address public immutable CORE;
    iParking public immutable PARKING;
    address public immutable ALLOCATOR;
    address public immutable FEE_RECIPIENT;

    uint256 public immutable COV_WAD;
    uint256 public immutable PI0_WAD;
    uint256 public immutable PIT_WAD;
    uint256 public immutable PI1_WAD;
    uint64 public immutable T_DEPLOY_END;
    uint64 public immutable D_WRITE_OFF;
    uint256 public immutable K_MIN_ASSETS;
    uint256 public immutable THETA_WAD;
    bytes32 public immutable ATTESTATION_HASH;
    uint256 public immutable T;
    uint256 public immutable T_OPEN;

    bytes32[] internal _marketIds;
    Market[] internal _markets;
    uint256[] internal _rateFloorWad;
    uint256[] internal _marketCapAssets;

    SeriesState public state;
    bool public passThrough;
    bool internal _entered;

    uint256 public seniorAllocated;
    uint256 public juniorAllocated;
    uint256 public tFinalize;

    mapping(uint256 => uint256) public filled;
    mapping(uint256 => uint256) public unitsBought;
    mapping(uint256 => uint256) public feeCrystallized;
    uint256 public totalFilled;
    mapping(bytes32 => bool) public rootRegistered;

    uint256 public juniorShareWad;
    uint256 public utilizationWad;
    uint256 public premiumWad;
    uint256 public seniorDeployed;
    uint256 public juniorDeployed;
    uint256 public poolRateWad;
    uint256 public seniorRateWad;
    uint256 public seniorClaim;
    uint256 public attachmentWad;
    uint256 public faceGross;
    uint256 public faceNetAtFinalize;
    bool public negativeCarry;

    uint256 public tSettled;
    mapping(uint256 => uint256) public collected;
    mapping(uint256 => bool) public resolved;
    mapping(uint256 => bool) public writtenOff;

    uint256 public paidS;
    uint256 public paidJ;
    uint256 public feeAccounted;
    uint256 public feeClaimed;

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
        iMidnightMinimal midnight,
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

        T = basketMarkets[0].maturity;
        T_OPEN = block.timestamp;

        require(block.timestamp < p.tDeployEnd, InvalidTiming());
        require(T >= MIN_TERM && p.tDeployEnd < T - MIN_TERM, InvalidTiming());

        midnight.setIsAuthorized(setterRatifier, true, address(this));
    }
}
