// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: core state layout: roles, the two books, the series registry, curator policy, errors and events.
// @author adiii.eth

pragma solidity 0.8.34;

import {seriesFactory} from "../../series/seriesFactory.sol";
import {iParking} from "../../parking/iParking.sol";
import {wadMath} from "../../libraries/wadMath.sol";

/// @notice Storage, policy defaults, events and errors of the core.
abstract contract coreStorage {
    using wadMath for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant VIRTUAL_CLAIMS = 1e6;
    uint256 public constant CURATOR_TIMELOCK = 3 days;
    uint64 public constant MIN_WRITE_OFF_DELAY = 1 days;
    uint64 public constant MAX_WRITE_OFF_DELAY = 30 days;

    error NotAllocator();
    error NotSeniorVault();
    error NotJuniorVault();
    error NotRegisteredSeries();
    error NotGovernance();
    error NotCuratorOrSentinel();
    error VaultsAlreadySet();
    error CoverageBand(uint256 aWad);
    error IdleInsufficient(bool senior, uint256 asked, uint256 available);
    error MaxSeriesExceeded();
    error PerSeriesCapExceeded();
    error MaturityWindowExceeded();
    error Paused();
    error TimelockNotElapsed();
    error TimelockIsRiskDecreasing();
    error WrongParking();
    error WrongAllocator();
    error WrongFeeRecipient();
    error PolicyMismatch();
    error RateFloorBelowMin(uint256 i);
    error KMinAboveCap();
    error WriteOffDelayOutOfRange();
    error ZeroAddress();
    error ParkingIlliquid(uint256 asked, uint256 available);
    error ParkingShortPaid(uint256 asked, uint256 received);

    event SeriesFunded(address indexed series, uint256 seniorAllocated, uint256 juniorAllocated);
    event ReturnReceived(address indexed series, uint256 toSenior, uint256 toJunior);
    event PayoutReceived(address indexed series, uint256 toSenior, uint256 toJunior);
    event Backstop(address indexed series, uint256 assets);
    event Synced(uint256 seniorAssets, uint256 juniorAssets);
    event StressGate(bool open);
    event VaultsSet(address seniorVault, address juniorVault);
    event PolicySubmitted(bytes32 indexed key, uint256 value, uint256 executableAt);
    event PolicyExecuted(bytes32 indexed key, uint256 value);
    event Paused_(bool paused);
    event FeeRecipientSet(address feeRecipient);
    event IdleLossAbsorbed(uint256 seniorLossAssets, uint256 claimsMoved);

    struct Book {
        uint256 parkingClaims;
        uint256 reservedAssets;
        uint256 pendingDeposits;
    }

    struct SeriesInfo {
        uint256 seniorAllocated;
        uint256 juniorAllocated;
        uint256 maturity;
        bool registered;
    }

    struct Policy {
        uint256 covWad;
        uint256 aMaxWad;
        uint256 covVaultWad;
        uint256 covVaultMinWad;
        uint256 pi0Wad;
        uint256 piTWad;
        uint256 pi1Wad;
        uint256 thetaWad;
        uint256 minRateFloorWad;
        uint256 maxSeries;
        uint256 maxRecovering;
        uint256 maxPerSeriesAssets;
        uint256 maxPerMaturityWindowWad;
        uint256 minIdleSeniorWad;
        uint256 minIdleJuniorWad;
        uint256 stressJuniorFloorWad;
        bool backstopEnabled;
        uint256 backstopWad;
        uint256 curatorMinShareWad;
    }

    struct PendingPolicyChange {
        bool active;
        uint256 value;
        uint256 executableAt;
    }

    address public immutable USDC;
    seriesFactory public immutable FACTORY;
    iParking public immutable PARKING;

    address public governance;
    address public allocator;
    address public curator;
    address public sentinel;
    address public seniorVault;
    address public juniorVault;
    bool public vaultsSet;
    bool public paused;
    address public feeRecipient;

    Book public senior;
    Book public junior;
    uint256 public totalParkingClaims;
    uint256 public claimPriceMark;

    address[] public liveSeries;
    address[] public recoveringSeries;
    mapping(address => SeriesInfo) public info;
    mapping(address => uint256) public backstopPaid;

    Policy public policy;
    uint256 public maxKMinAssets;
    mapping(bytes32 => PendingPolicyChange) public pendingPolicyChanges;

    modifier onlyAllocator() {
        require(msg.sender == allocator, NotAllocator());
        _;
    }

    modifier onlyJuniorVault() {
        require(msg.sender == juniorVault, NotJuniorVault());
        _;
    }

    modifier onlyRegisteredSeries() {
        require(info[msg.sender].registered, NotRegisteredSeries());
        _;
    }

    modifier onlyGovernance() {
        require(msg.sender == governance, NotGovernance());
        _;
    }

    modifier onlyCuratorOrSentinel() {
        require(msg.sender == curator || msg.sender == sentinel, NotCuratorOrSentinel());
        _;
    }

    constructor(
        address usdc,
        seriesFactory factory,
        iParking parking,
        address governance_,
        address allocator_,
        address curator_,
        address sentinel_
    ) {
        USDC = usdc;
        FACTORY = factory;
        PARKING = parking;
        governance = governance_;
        allocator = allocator_;
        curator = curator_;
        sentinel = sentinel_;
        feeRecipient = governance_;
        maxKMinAssets = 50_000e6;

        policy = Policy({
            covWad: 0.15e18,
            aMaxWad: 0.3e18,
            covVaultWad: 0.2e18,
            covVaultMinWad: 0.15e18,
            pi0Wad: 0.1e18,
            piTWad: 0.2e18,
            pi1Wad: 0.35e18,
            thetaWad: 0.1e18,
            minRateFloorWad: 0.005e18,
            maxSeries: 12,
            maxRecovering: 8,
            maxPerSeriesAssets: 1_000_000e6,
            maxPerMaturityWindowWad: 0.5e18,
            minIdleSeniorWad: 0.05e18,
            minIdleJuniorWad: 0.05e18,
            stressJuniorFloorWad: 0.5e18,
            backstopEnabled: true,
            backstopWad: 0.5e18,
            curatorMinShareWad: 0.1e18
        });
    }
}
