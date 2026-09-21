// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {SeriesParams, SeriesState} from "../interfaces/ISeries.sol";
import {IMidnightMinimal} from "../interfaces/IMidnightMinimal.sol";
import {Series} from "../series/Series.sol";
import {SeriesFactory} from "../series/SeriesFactory.sol";
import {IParking} from "../parking/IParking.sol";
import {WadMath} from "../libraries/WadMath.sol";

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

// Morrow Finance — the protocol's single custody and accounting layer: owns every series, keeps the senior
// and junior books, and enforces coverage/capacity/stress-gate policy.
// @author adiii.eth

/// @notice Single custody and accounting contract. Holds all idle cash in parking, owns every series, keeps
/// the senior and junior books, enforces coverage/capacity/stress-gate rules, and rolls settled cash back
/// into the books. The senior and junior vaults are share ledgers on top of these books; this contract is
/// where value actually lives and is counted.
contract SeriesCore {
    using WadMath for uint256;

    uint256 internal constant WAD = 1e18;

    // --- errors ---------------------------------------------------------------------------------------------

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

    // --- events -----------------------------------------------------------------------------------------------

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

    // --- roles ------------------------------------------------------------------------------------------------

    address public immutable USDC;
    SeriesFactory public immutable FACTORY;
    IParking public immutable PARKING;

    address public governance;
    address public allocator;
    address public curator;
    address public sentinel;
    address public seniorVault;
    address public juniorVault;
    bool public vaultsSet;
    bool public paused;

    // --- books -----------------------------------------------------------------------------------------------

    /// @dev parkingShares is a literal asset amount, not a proportional vault share: the only parking adapter
    /// built so far holds usdc 1:1 with no yield, so "shares" and "assets" coincide. A yield-bearing parking
    /// adapter later would need this reworked into true proportional shares so each book keeps its own claim
    /// on appreciating parked value.
    struct Book {
        uint256 parkingShares;
        uint256 reservedAssets;
        uint256 pendingDeposits; // junior only
    }

    Book public senior;
    Book public junior;

    address[] public liveSeries; // DEPLOYING, LOCKED, SETTLING
    address[] public recoveringSeries; // SETTLED with written-off credit still outstanding

    struct SeriesInfo {
        uint256 seniorAllocated;
        uint256 juniorAllocated;
        uint256 maturity;
        bool registered;
    }

    mapping(address => SeriesInfo) public info;
    mapping(address => uint256) public backstopPaid; // cumulative junior-to-senior backstop transfer per series

    // --- curator policy ----------------------------------------------------------------------------------------

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

    Policy public policy;
    uint256 public constant CURATOR_TIMELOCK = 3 days;

    struct PendingPolicyChange {
        bool active;
        uint256 value;
        uint256 executableAt;
    }

    mapping(bytes32 => PendingPolicyChange) public pendingPolicyChanges;

    // --- modifiers --------------------------------------------------------------------------------------------

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

    constructor(
        address usdc,
        SeriesFactory factory,
        IParking parking,
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
            backstopEnabled: true, // decided: on by default for this build
            backstopWad: 0.5e18,
            curatorMinShareWad: 0.1e18
        });
    }

    /// @notice Wires in the senior and junior vaults, once.
    /// @dev Vaults need the core's address in their own constructor, so they're always deployed after it.
    function setVaults(address seniorVault_, address juniorVault_) external onlyGovernance {
        require(!vaultsSet, VaultsAlreadySet());
        seniorVault = seniorVault_;
        juniorVault = juniorVault_;
        vaultsSet = true;
        emit VaultsSet(seniorVault_, juniorVault_);
    }

    // --- openSeries --------------------------------------------------------------------------------------------

    /// @notice Opens a new series: validates coverage, idle liquidity, and maturity-window exposure, deploys
    /// it through the factory, and funds it from the senior/junior books.
    /// @param p The series' creation parameters.
    /// @param S Senior capital to allocate.
    /// @param J Junior capital to allocate.
    /// @return seriesAddr The newly deployed and funded series.
    function openSeries(SeriesParams calldata p, uint256 S, uint256 J)
        external
        onlyAllocator
        returns (address seriesAddr)
    {
        require(!paused, Paused());
        require(liveSeries.length < policy.maxSeries, MaxSeriesExceeded());

        uint256 kAlloc = S + J;
        require(kAlloc > 0 && kAlloc <= policy.maxPerSeriesAssets, PerSeriesCapExceeded());

        // junior's share of allocated capital, rounded down, must sit inside the curator's coverage band.
        uint256 aWad = J.mulDivDown(WAD, kAlloc);
        require(policy.covWad <= aWad && aWad <= policy.aMaxWad, CoverageBand(aWad));

        // idle after reserved redemptions and idle floors.
        uint256 seniorAvail = idleAvailable(true);
        uint256 juniorAvail = idleAvailable(false);
        require(S <= seniorAvail, IdleInsufficient(true, S, seniorAvail));
        require(J <= juniorAvail, IdleInsufficient(false, J, juniorAvail));

        // maturity window cap. T is read directly off the basket's first market -- eligibility (run inside
        // factory.createSeries below) independently requires every market in the basket to share one maturity,
        // so reading just the first is sound and avoids duplicating that check here.
        uint256 T = _maturityOfFirstMarket(p.marketIds[0]);
        uint256 windowExposure = _maturityWindowExposure(T) + kAlloc;
        uint256 totalAum = seniorAssets() + juniorAssets();
        require(windowExposure <= totalAum.mulDivDown(policy.maxPerMaturityWindowWad, WAD), MaturityWindowExceeded());

        seriesAddr = FACTORY.createSeries(p);

        senior.parkingShares -= S;
        junior.parkingShares -= J;
        PARKING.withdraw(kAlloc, address(this));
        require(IERC20Like(USDC).transfer(seriesAddr, kAlloc), "transfer failed");
        Series(seriesAddr).initialize(S, J);

        liveSeries.push(seriesAddr);
        info[seriesAddr] = SeriesInfo({seniorAllocated: S, juniorAllocated: J, maturity: T, registered: true});

        emit SeriesFunded(seriesAddr, S, J);
    }

    function _maturityOfFirstMarket(bytes32 marketId) internal view returns (uint256) {
        Market memory market = IMidnightMinimal(address(FACTORY.MIDNIGHT())).toMarket(marketId);
        return market.maturity;
    }

    /// @dev Sum of S+J for every live series whose maturity falls within 30 days of `T` (either direction).
    function _maturityWindowExposure(uint256 T) internal view returns (uint256 exposure) {
        uint256 length = liveSeries.length;
        for (uint256 i = 0; i < length; i++) {
            SeriesInfo memory s = info[liveSeries[i]];
            uint256 diff = s.maturity > T ? s.maturity - T : T - s.maturity;
            if (diff <= 30 days) exposure += s.seniorAllocated + s.juniorAllocated;
        }
    }

    // --- series-only payout hooks ------------------------------------------------------------------------------

    /// @notice Credits the books when a registered series returns undeployed capital, at finalize or cancel.
    /// @dev The series has already transferred the cash in the same call; this credits the books and prunes
    /// the series from liveSeries if it just went terminal (cancelled).
    function receiveReturn(uint256 toSenior, uint256 toJunior) external onlyRegisteredSeries {
        _creditBooks(toSenior, toJunior);

        if (uint8(Series(msg.sender).state()) == uint8(SeriesState.CANCELED)) {
            _removeLive(msg.sender);
        }

        emit ReturnReceived(msg.sender, toSenior, toJunior);
    }

    /// @notice Credits the books on a registered series' waterfall payout, applies the cross-series loss
    /// backstop if enabled, and prunes the series once it settles.
    /// @dev Called by a series at every waterfall rerun. Applies the backstop if senior is still short of its
    /// claim, then moves the series into recoveringSeries or out entirely once it reaches SETTLED.
    function receivePayout(uint256 toSenior, uint256 toJunior) external onlyRegisteredSeries {
        _creditBooks(toSenior, toJunior);

        if (policy.backstopEnabled) {
            _applyBackstop(msg.sender);
        }

        Series s = Series(msg.sender);
        if (uint8(s.state()) == uint8(SeriesState.SETTLED)) {
            bool stillRecovering = _hasWrittenOffCredit(s);
            _removeLive(msg.sender);
            if (stillRecovering && recoveringSeries.length < policy.maxRecovering) {
                recoveringSeries.push(msg.sender);
            }
        }

        emit PayoutReceived(msg.sender, toSenior, toJunior);
    }

    function _creditBooks(uint256 toSenior, uint256 toJunior) internal {
        uint256 total = toSenior + toJunior;
        if (total == 0) return;
        require(IERC20Like(USDC).approve(address(PARKING), total), "approve failed");
        PARKING.deposit(total);
        senior.parkingShares += toSenior;
        junior.parkingShares += toJunior;
    }

    /// @dev When senior is short of its frozen claim on a series, tops it up from junior's idle cash, capped by
    /// a curator-set fraction of that idle and by the shortfall itself. Cumulative per series via backstopPaid,
    /// which tracks how much of junior's advance would need to be reimbursed before anything else flows to
    /// junior (the series' own waterfall pays senior first up to its claim regardless).
    function _applyBackstop(address seriesAddr) internal {
        Series s = Series(seriesAddr);
        if (s.passThrough()) return; // no fixed claim to compare against

        uint256 claim = s.seniorClaim();
        uint256 paid = s.paidS();
        if (paid >= claim) return;

        uint256 shortfall = claim - paid;
        uint256 already = backstopPaid[seriesAddr];
        if (already >= shortfall) return;
        uint256 remaining = shortfall - already;

        uint256 maxFromIdle = junior.parkingShares.mulDivDown(policy.backstopWad, WAD);
        uint256 backstop = remaining < maxFromIdle ? remaining : maxFromIdle;
        if (backstop == 0) return;

        junior.parkingShares -= backstop;
        senior.parkingShares += backstop;
        backstopPaid[seriesAddr] += backstop;

        emit Backstop(seriesAddr, backstop);
    }

    function _hasWrittenOffCredit(Series s) internal view returns (bool) {
        bytes32[] memory ids = s.marketIds();
        for (uint256 i = 0; i < ids.length; i++) {
            if (s.writtenOff(i) && !s.resolved(i)) return true;
        }
        return false;
    }

    function _removeLive(address seriesAddr) internal {
        uint256 length = liveSeries.length;
        for (uint256 i = 0; i < length; i++) {
            if (liveSeries[i] == seriesAddr) {
                liveSeries[i] = liveSeries[length - 1];
                liveSeries.pop();
                return;
            }
        }
    }

    function _requireVault(bool isSenior) internal view {
        if (isSenior) {
            require(msg.sender == seniorVault, NotSeniorVault());
        } else {
            require(msg.sender == juniorVault, NotJuniorVault());
        }
    }

    // --- vault-only functions ----------------------------------------------------------------------------------

    /// @notice Credits `assets` of freshly deposited capital into the calling vault's book.
    function depositFor(bool isSenior, uint256 assets) external {
        _requireVault(isSenior);
        require(IERC20Like(USDC).approve(address(PARKING), assets), "approve failed");
        PARKING.deposit(assets);
        if (isSenior) senior.parkingShares += assets;
        else junior.parkingShares += assets;
    }

    /// @notice Records a junior deposit as pending, before it is invested into the book.
    function addPendingJunior(uint256 assets) external onlyJuniorVault {
        junior.pendingDeposits += assets;
    }

    /// @notice Refunds a pending junior deposit that was never invested, e.g. on a cancelled epoch fill.
    function removePendingJunior(uint256 assets, address to) external onlyJuniorVault {
        junior.pendingDeposits -= assets;
        require(IERC20Like(USDC).transfer(to, assets), "transfer failed");
    }

    /// @notice Moves a pending junior deposit into the junior book, once its epoch fills.
    function investPendingJunior(uint256 assets) external onlyJuniorVault {
        junior.pendingDeposits -= assets;
        require(IERC20Like(USDC).approve(address(PARKING), assets), "approve failed");
        PARKING.deposit(assets);
        junior.parkingShares += assets;
    }

    /// @notice Pulls `assets` out of parking into a reserved balance for the calling vault, ahead of a payout.
    function reserveFor(bool isSenior, uint256 assets) external {
        _requireVault(isSenior);
        PARKING.withdraw(assets, address(this));
        if (isSenior) {
            senior.parkingShares -= assets;
            senior.reservedAssets += assets;
        } else {
            junior.parkingShares -= assets;
            junior.reservedAssets += assets;
        }
    }

    /// @notice Pays `assets` from the calling vault's reserved balance to `to`.
    function payFrom(bool isSenior, address to, uint256 assets) external {
        _requireVault(isSenior);
        if (isSenior) senior.reservedAssets -= assets;
        else junior.reservedAssets -= assets;
        require(IERC20Like(USDC).transfer(to, assets), "transfer failed");
    }

    // --- anyone -------------------------------------------------------------------------------------------------

    /// @notice Writes the latest loss factor/fee accrual for every live series on chain. Permissionless.
    function syncAll() external {
        uint256 length = liveSeries.length;
        for (uint256 i = 0; i < length; i++) {
            Series(liveSeries[i]).navsSynced();
        }
        emit Synced(seniorAssets(), juniorAssets());
    }

    /// @notice Sweeps liveSeries and recoveringSeries for state that has moved on without a triggering call.
    /// @dev Moves settled/canceled series out of liveSeries (into recoveringSeries if they still hold
    /// written-off credit), and drops fully-resolved series out of recoveringSeries. receiveReturn/receivePayout
    /// already do this inline on every call that reaches a terminal state; this is a bounded catch-up sweep.
    function pruneSeries() external {
        uint256 i;
        while (i < liveSeries.length) {
            Series s = Series(liveSeries[i]);
            uint8 st = uint8(s.state());
            if (st == uint8(SeriesState.SETTLED) || st == uint8(SeriesState.CANCELED)) {
                bool stillRecovering = st == uint8(SeriesState.SETTLED) && _hasWrittenOffCredit(s);
                address addr = liveSeries[i];
                liveSeries[i] = liveSeries[liveSeries.length - 1];
                liveSeries.pop();
                if (stillRecovering && recoveringSeries.length < policy.maxRecovering) {
                    recoveringSeries.push(addr);
                }
            } else {
                i++;
            }
        }

        uint256 j;
        while (j < recoveringSeries.length) {
            if (!_hasWrittenOffCredit(Series(recoveringSeries[j]))) {
                recoveringSeries[j] = recoveringSeries[recoveringSeries.length - 1];
                recoveringSeries.pop();
            } else {
                j++;
            }
        }
    }

    // --- views ---------------------------------------------------------------------------------------------------

    function liveSeriesCount() external view returns (uint256) {
        return liveSeries.length;
    }

    function recoveringSeriesCount() external view returns (uint256) {
        return recoveringSeries.length;
    }

    /// @notice Total senior book value: idle senior cash plus the senior NAV of every live series.
    function seniorAssets() public view returns (uint256 total) {
        total = senior.parkingShares;
        uint256 length = liveSeries.length;
        for (uint256 i = 0; i < length; i++) {
            (uint256 navS,,) = Series(liveSeries[i]).navs();
            total += navS;
        }
    }

    /// @notice Total junior book value: idle junior cash plus the junior NAV of every live series.
    function juniorAssets() public view returns (uint256 total) {
        total = junior.parkingShares;
        uint256 length = liveSeries.length;
        for (uint256 i = 0; i < length; i++) {
            (, uint256 navJ,) = Series(liveSeries[i]).navs();
            total += navJ;
        }
    }

    /// @notice Same as seniorAssets, but first writes each live series' latest state to chain.
    function seniorAssetsSynced() external returns (uint256 total) {
        total = senior.parkingShares;
        uint256 length = liveSeries.length;
        for (uint256 i = 0; i < length; i++) {
            (uint256 navS,,) = Series(liveSeries[i]).navsSynced();
            total += navS;
        }
    }

    /// @notice Same as juniorAssets, but first writes each live series' latest state to chain.
    function juniorAssetsSynced() external returns (uint256 total) {
        total = junior.parkingShares;
        uint256 length = liveSeries.length;
        for (uint256 i = 0; i < length; i++) {
            (, uint256 navJ,) = Series(liveSeries[i]).navsSynced();
            total += navJ;
        }
    }

    /// @notice Max senior book size implied by the current junior book, given the curator's vault coverage
    /// target.
    function seniorCapacity() public view returns (uint256) {
        return juniorAssets().mulDivDown(WAD - policy.covVaultWad, policy.covVaultWad);
    }

    /// @dev Book idle, floor included (i.e. the raw parked balance not yet in a series).
    function idle(bool isSenior) public view returns (uint256) {
        return isSenior ? senior.parkingShares : junior.parkingShares;
    }

    /// @dev Book idle minus the curator's idle floor for that book.
    function idleAvailable(bool isSenior) public view returns (uint256) {
        uint256 bookAssets = isSenior ? seniorAssets() : juniorAssets();
        uint256 floorWad = isSenior ? policy.minIdleSeniorWad : policy.minIdleJuniorWad;
        uint256 floor = bookAssets.mulDivDown(floorWad, WAD);
        uint256 idleNow = idle(isSenior);
        return idleNow > floor ? idleNow - floor : 0;
    }

    /// @notice Whether new senior deposits are currently allowed.
    /// @dev False while any live series' junior NAV has fallen below the stress floor, or any recovering
    /// series still holds written-off credit — a recovery there would jump the senior price, letting a
    /// deposit made just before capture part of it.
    function stressGateOpen() public view returns (bool) {
        uint256 length = liveSeries.length;
        for (uint256 i = 0; i < length; i++) {
            Series s = Series(liveSeries[i]);
            if (uint8(s.state()) == uint8(SeriesState.DEPLOYING)) continue; // J_d not priced yet
            uint256 jD = s.juniorDeployed();
            if (jD == 0) continue;
            (, uint256 navJ,) = s.navs();
            if (navJ < jD.mulDivDown(policy.stressJuniorFloorWad, WAD)) return false;
        }

        uint256 recLength = recoveringSeries.length;
        for (uint256 i = 0; i < recLength; i++) {
            if (_hasWrittenOffCredit(Series(recoveringSeries[i]))) return false;
        }

        return true;
    }

    /// @dev Max junior assets redeemable while keeping vault coverage at or above covVaultMinWad afterward,
    /// bounded by what's actually idle and liquid.
    function juniorRedeemable() public view returns (uint256) {
        uint256 sA = seniorAssets();
        uint256 jA = juniorAssets();
        // floor rounds up so a redemption can never push coverage strictly below the minimum.
        uint256 floorJ = sA.mulDivUp(policy.covVaultMinWad, WAD - policy.covVaultMinWad);
        if (jA <= floorJ) return 0;
        uint256 maxRedeemable = jA - floorJ;
        uint256 idleAvail = idle(false);
        return maxRedeemable < idleAvail ? maxRedeemable : idleAvail;
    }

    // --- curator policy ------------------------------------------------------------------------------------------

    /// @notice Queues a curator policy change, executable after the timelock.
    /// @dev `key` is keccak256("<fieldName>"); see _writePolicy for the recognized set.
    function proposePolicyChange(bytes32 key, uint256 value) external returns (uint256 executableAt) {
        require(msg.sender == curator, NotCuratorOrSentinel());
        executableAt = block.timestamp + CURATOR_TIMELOCK;
        pendingPolicyChanges[key] = PendingPolicyChange(true, value, executableAt);
        emit PolicySubmitted(key, value, executableAt);
    }

    /// @notice Applies a previously queued, now-matured policy change.
    function executePolicyChange(bytes32 key) external {
        PendingPolicyChange memory change = pendingPolicyChanges[key];
        require(change.active && block.timestamp >= change.executableAt, TimelockNotElapsed());
        delete pendingPolicyChanges[key];
        _writePolicy(key, change.value);
        emit PolicyExecuted(key, change.value);
    }

    /// @dev A hand-picked subset of clearly-risk-decreasing single-direction changes, callable immediately by
    /// curator or sentinel without the timelock — pausing deposits and lowering caps is the sentinel's whole
    /// mandate. Each function only allows moving the parameter in its safe direction.
    function pause() external {
        require(msg.sender == curator || msg.sender == sentinel, NotCuratorOrSentinel());
        paused = true;
        emit Paused_(true);
    }

    function unpause() external onlyGovernance {
        paused = false;
        emit Paused_(false);
    }

    function lowerMaxSeries(uint256 newMax) external {
        require(msg.sender == curator || msg.sender == sentinel, NotCuratorOrSentinel());
        require(newMax <= policy.maxSeries, TimelockIsRiskDecreasing());
        policy.maxSeries = newMax;
        emit PolicyExecuted(keccak256("maxSeries"), newMax);
    }

    function lowerMaxPerSeriesAssets(uint256 newMax) external {
        require(msg.sender == curator || msg.sender == sentinel, NotCuratorOrSentinel());
        require(newMax <= policy.maxPerSeriesAssets, TimelockIsRiskDecreasing());
        policy.maxPerSeriesAssets = newMax;
        emit PolicyExecuted(keccak256("maxPerSeriesAssets"), newMax);
    }

    function lowerAMaxWad(uint256 newAMax) external {
        require(msg.sender == curator || msg.sender == sentinel, NotCuratorOrSentinel());
        require(newAMax <= policy.aMaxWad && newAMax >= policy.covWad, TimelockIsRiskDecreasing());
        policy.aMaxWad = newAMax;
        emit PolicyExecuted(keccak256("aMaxWad"), newAMax);
    }

    function raiseMinIdleSeniorWad(uint256 newFloor) external {
        require(msg.sender == curator || msg.sender == sentinel, NotCuratorOrSentinel());
        require(newFloor >= policy.minIdleSeniorWad && newFloor <= WAD, TimelockIsRiskDecreasing());
        policy.minIdleSeniorWad = newFloor;
        emit PolicyExecuted(keccak256("minIdleSeniorWad"), newFloor);
    }

    function raiseMinIdleJuniorWad(uint256 newFloor) external {
        require(msg.sender == curator || msg.sender == sentinel, NotCuratorOrSentinel());
        require(newFloor >= policy.minIdleJuniorWad && newFloor <= WAD, TimelockIsRiskDecreasing());
        policy.minIdleJuniorWad = newFloor;
        emit PolicyExecuted(keccak256("minIdleJuniorWad"), newFloor);
    }

    function raiseStressJuniorFloorWad(uint256 newFloor) external {
        require(msg.sender == curator || msg.sender == sentinel, NotCuratorOrSentinel());
        require(newFloor >= policy.stressJuniorFloorWad && newFloor <= WAD, TimelockIsRiskDecreasing());
        policy.stressJuniorFloorWad = newFloor;
        emit PolicyExecuted(keccak256("stressJuniorFloorWad"), newFloor);
    }

    function raiseCovVaultMinWad(uint256 newFloor) external {
        require(msg.sender == curator || msg.sender == sentinel, NotCuratorOrSentinel());
        require(newFloor >= policy.covVaultMinWad && newFloor < WAD, TimelockIsRiskDecreasing());
        policy.covVaultMinWad = newFloor;
        emit PolicyExecuted(keccak256("covVaultMinWad"), newFloor);
    }

    function disableBackstop() external {
        require(msg.sender == curator || msg.sender == sentinel, NotCuratorOrSentinel());
        policy.backstopEnabled = false;
        emit PolicyExecuted(keccak256("backstopEnabled"), 0);
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        governance = newGovernance;
    }

    function setAllocator(address newAllocator) external onlyGovernance {
        allocator = newAllocator;
    }

    function setCurator(address newCurator) external onlyGovernance {
        curator = newCurator;
    }

    function setSentinel(address newSentinel) external onlyGovernance {
        sentinel = newSentinel;
    }

    function _writePolicy(bytes32 key, uint256 value) internal {
        if (key == keccak256("covWad")) policy.covWad = value;
        else if (key == keccak256("aMaxWad")) policy.aMaxWad = value;
        else if (key == keccak256("covVaultWad")) policy.covVaultWad = value;
        else if (key == keccak256("covVaultMinWad")) policy.covVaultMinWad = value;
        else if (key == keccak256("pi0Wad")) policy.pi0Wad = value;
        else if (key == keccak256("piTWad")) policy.piTWad = value;
        else if (key == keccak256("pi1Wad")) policy.pi1Wad = value;
        else if (key == keccak256("thetaWad")) policy.thetaWad = value;
        else if (key == keccak256("minRateFloorWad")) policy.minRateFloorWad = value;
        else if (key == keccak256("maxSeries")) policy.maxSeries = value;
        else if (key == keccak256("maxRecovering")) policy.maxRecovering = value;
        else if (key == keccak256("maxPerSeriesAssets")) policy.maxPerSeriesAssets = value;
        else if (key == keccak256("maxPerMaturityWindowWad")) policy.maxPerMaturityWindowWad = value;
        else if (key == keccak256("minIdleSeniorWad")) policy.minIdleSeniorWad = value;
        else if (key == keccak256("minIdleJuniorWad")) policy.minIdleJuniorWad = value;
        else if (key == keccak256("stressJuniorFloorWad")) policy.stressJuniorFloorWad = value;
        else if (key == keccak256("backstopEnabled")) policy.backstopEnabled = value != 0;
        else if (key == keccak256("backstopWad")) policy.backstopWad = value;
        else if (key == keccak256("curatorMinShareWad")) policy.curatorMinShareWad = value;
    }
}
