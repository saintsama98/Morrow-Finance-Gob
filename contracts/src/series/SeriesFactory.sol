// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {IMidnightMinimal} from "../interfaces/IMidnightMinimal.sol";
import {MidnightReader} from "../libraries/MidnightReader.sol";
import {SeriesParams} from "../interfaces/ISeries.sol";
import {Series} from "./Series.sol";

// Morrow Finance — collateral/oracle/LLTV allowlists and basket eligibility checks for new series.
// @author adiii.eth

/// @notice Deploys new Series contracts and is the sole on-chain enforcer of basket eligibility. Everything
/// about a proposed series that depends on the senior/junior split or coverage band is checked by the core
/// before it ever calls here.
contract SeriesFactory {
    using MidnightReader for IMidnightMinimal;

    error NotGovernance();
    error NotCore();
    error IneligibleMarket(bytes32 id, uint8 rule);
    error BasketTooLarge();
    error BasketEmpty();
    error DuplicateMarket(bytes32 id);
    error TimelockNotElapsed();
    error DecimalsNotSix();

    /// @dev The loan token must be 6-decimal USDC, enforced both here and in the core.
    uint8 internal constant USDC_DECIMALS = 6;

    /// @dev Hard ceilings enforced in code regardless of what governance sets.
    uint256 internal constant HARD_MAX_LLTV_WAD = 0.915e18;
    uint256 internal constant HARD_MAX_MARKETS_PER_SERIES = 8;
    uint256 internal constant MAX_COLLATERALS_CHECKED = 8;
    uint256 internal constant TIMELOCK = 48 hours;

    IMidnightMinimal public immutable MIDNIGHT;
    address public immutable SETTER_RATIFIER;
    address public immutable USDC;
    address public governance;
    address public core;

    mapping(address token => bool) public collateralAllowed; // governance-set collateral allowlist
    mapping(address token => mapping(address oracle => bool)) public oracleAllowed; // allowlisted oracle per token
    uint256 public maxLltvWad;
    uint256 public maxMarketsPerSeries;

    /// @dev A change never affects a series already open, because each series snapshots what it needs at
    /// creation (the eligibility check itself, run once, at open time).
    struct PendingChange {
        bool active;
        uint256 executableAt;
    }

    mapping(bytes32 changeId => PendingChange) public pendingChanges;

    event GovernanceUpdated(address indexed newGovernance);
    event CoreSet(address indexed core);
    event CollateralAllowlistProposed(address indexed token, bool allowed, uint256 executableAt);
    event CollateralAllowlistExecuted(address indexed token, bool allowed);
    event OracleAllowlistProposed(address indexed token, address indexed oracle, bool allowed, uint256 executableAt);
    event OracleAllowlistExecuted(address indexed token, address indexed oracle, bool allowed);
    event MaxLltvProposed(uint256 newMaxLltvWad, uint256 executableAt);
    event MaxLltvExecuted(uint256 newMaxLltvWad);
    event MaxMarketsPerSeriesProposed(uint256 newMax, uint256 executableAt);
    event MaxMarketsPerSeriesExecuted(uint256 newMax);

    modifier onlyGovernance() {
        require(msg.sender == governance, NotGovernance());
        _;
    }

    constructor(
        IMidnightMinimal midnight,
        address setterRatifier,
        address usdc,
        address governance_,
        uint256 initialMaxLltvWad,
        uint256 initialMaxMarketsPerSeries
    ) {
        require(_decimalsOf(usdc) == USDC_DECIMALS, DecimalsNotSix());
        MIDNIGHT = midnight;
        SETTER_RATIFIER = setterRatifier;
        USDC = usdc;
        governance = governance_;
        maxLltvWad = initialMaxLltvWad <= HARD_MAX_LLTV_WAD ? initialMaxLltvWad : HARD_MAX_LLTV_WAD;
        maxMarketsPerSeries = initialMaxMarketsPerSeries <= HARD_MAX_MARKETS_PER_SERIES
            ? initialMaxMarketsPerSeries
            : HARD_MAX_MARKETS_PER_SERIES;
    }

    /// @notice Binds the core contract, once. Core and factory reference each other, so neither can be passed
    /// to the other's constructor; governance-only, and only while unset, so it can never be rebound out from
    /// under an already-live product.
    function setCore(address core_) external onlyGovernance {
        require(core == address(0), NotGovernance());
        core = core_;
        emit CoreSet(core_);
    }

    // --- timelocked allowlist changes ------------------------------------------------------------------

    /// @notice Queues a change to whether `token` may be used as collateral, executable after the timelock.
    function proposeCollateralAllowed(address token, bool allowed) external onlyGovernance returns (bytes32 id) {
        id = keccak256(abi.encode("collateral", token, allowed));
        uint256 executableAt = block.timestamp + TIMELOCK;
        pendingChanges[id] = PendingChange(true, executableAt);
        emit CollateralAllowlistProposed(token, allowed, executableAt);
    }

    /// @notice Applies a previously queued, now-matured collateral allowlist change.
    function executeCollateralAllowed(address token, bool allowed) external {
        bytes32 id = keccak256(abi.encode("collateral", token, allowed));
        _consumeTimelock(id);
        collateralAllowed[token] = allowed;
        emit CollateralAllowlistExecuted(token, allowed);
    }

    /// @notice Queues a change to whether `oracle` is allowed for `token`, executable after the timelock.
    function proposeOracleAllowed(address token, address oracle, bool allowed)
        external
        onlyGovernance
        returns (bytes32 id)
    {
        id = keccak256(abi.encode("oracle", token, oracle, allowed));
        uint256 executableAt = block.timestamp + TIMELOCK;
        pendingChanges[id] = PendingChange(true, executableAt);
        emit OracleAllowlistProposed(token, oracle, allowed, executableAt);
    }

    /// @notice Applies a previously queued, now-matured oracle allowlist change.
    function executeOracleAllowed(address token, address oracle, bool allowed) external {
        bytes32 id = keccak256(abi.encode("oracle", token, oracle, allowed));
        _consumeTimelock(id);
        oracleAllowed[token][oracle] = allowed;
        emit OracleAllowlistExecuted(token, oracle, allowed);
    }

    /// @notice Queues a new max-LLTV ceiling, capped by the hard ceiling and executable after the timelock.
    function proposeMaxLltv(uint256 newMaxLltvWad) external onlyGovernance returns (bytes32 id) {
        require(newMaxLltvWad <= HARD_MAX_LLTV_WAD, IneligibleMarket(bytes32(0), 4));
        id = keccak256(abi.encode("maxLltv", newMaxLltvWad));
        uint256 executableAt = block.timestamp + TIMELOCK;
        pendingChanges[id] = PendingChange(true, executableAt);
        emit MaxLltvProposed(newMaxLltvWad, executableAt);
    }

    /// @notice Applies a previously queued, now-matured max-LLTV change.
    function executeMaxLltv(uint256 newMaxLltvWad) external {
        bytes32 id = keccak256(abi.encode("maxLltv", newMaxLltvWad));
        _consumeTimelock(id);
        maxLltvWad = newMaxLltvWad;
        emit MaxLltvExecuted(newMaxLltvWad);
    }

    /// @notice Queues a new max-markets-per-series ceiling, capped by the hard ceiling and executable after
    /// the timelock.
    function proposeMaxMarketsPerSeries(uint256 newMax) external onlyGovernance returns (bytes32 id) {
        require(newMax <= HARD_MAX_MARKETS_PER_SERIES, IneligibleMarket(bytes32(0), 6));
        id = keccak256(abi.encode("maxMarkets", newMax));
        uint256 executableAt = block.timestamp + TIMELOCK;
        pendingChanges[id] = PendingChange(true, executableAt);
        emit MaxMarketsPerSeriesProposed(newMax, executableAt);
    }

    /// @notice Applies a previously queued, now-matured max-markets-per-series change.
    function executeMaxMarketsPerSeries(uint256 newMax) external {
        bytes32 id = keccak256(abi.encode("maxMarkets", newMax));
        _consumeTimelock(id);
        maxMarketsPerSeries = newMax;
        emit MaxMarketsPerSeriesExecuted(newMax);
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        governance = newGovernance;
        emit GovernanceUpdated(newGovernance);
    }

    function _consumeTimelock(bytes32 id) internal {
        PendingChange memory change = pendingChanges[id];
        require(change.active && block.timestamp >= change.executableAt, TimelockNotElapsed());
        delete pendingChanges[id];
    }

    // --- series creation --------------------------------------------------------------------------------

    error InvalidCovBand();
    error InvalidPremiumAnchors();
    error ThetaAboveCeiling();
    error ZeroRateFloor();
    error MarketArrayLengthMismatch();

    modifier onlyCore() {
        require(msg.sender == core, NotCore());
        _;
    }

    /// @notice Validates a proposed series' basket eligibility and static params, then deploys it.
    /// @dev Runs full basket eligibility plus every SeriesParams check that doesn't depend on the senior/junior
    /// split (that split isn't known yet — the core calls this before computing the allocation, and the
    /// corresponding cap check happens in Series.initialize once the split is known). Deploys a standalone
    /// Series contract, not a clone; the core funds it and calls initialize() separately.
    /// @param p The series' creation parameters.
    /// @return series The freshly deployed, uninitialized Series contract.
    function createSeries(SeriesParams calldata p) external onlyCore returns (address series) {
        require(
            p.rateFloorWad.length == p.marketIds.length && p.marketCapAssets.length == p.marketIds.length,
            MarketArrayLengthMismatch()
        );
        require(p.covWad >= 0.05e18 && p.covWad <= 0.5e18, InvalidCovBand());
        require(p.pi0Wad <= p.piTWad && p.piTWad <= p.pi1Wad && p.pi1Wad < 1e18, InvalidPremiumAnchors());
        require(p.thetaWad <= 0.2e18, ThetaAboveCeiling());
        for (uint256 i = 0; i < p.rateFloorWad.length; i++) {
            require(p.rateFloorWad[i] > 0, ZeroRateFloor());
        }

        Market[] memory markets = checkEligibility(p.marketIds);

        series = address(new Series(MIDNIGHT, SETTER_RATIFIER, USDC, core, markets, p));
    }

    // --- eligibility ------------------------------------------------------------------------------------

    /// @notice Checks every eligibility rule (E1-E6) for a proposed basket of markets.
    /// @dev The canonical Market struct for each id is always read from Midnight itself, never trusted from
    /// the caller — a caller-supplied struct could describe a market that doesn't match the id actually traded
    /// against, making the whole check meaningless. Reverts with IneligibleMarket(id, rule) on the first
    /// violation found, where `rule` is the 1-indexed eligibility rule number (E1..E6).
    /// @param marketIds The proposed basket's Midnight market ids.
    /// @return markets Each market's canonical config, as read from Midnight, in the same order.
    function checkEligibility(bytes32[] memory marketIds) public view returns (Market[] memory markets) {
        uint256 length = marketIds.length;
        require(length > 0, BasketEmpty());
        require(length <= maxMarketsPerSeries, BasketTooLarge());

        markets = new Market[](length);
        for (uint256 i = 0; i < length; i++) {
            markets[i] = MIDNIGHT.marketConfig(marketIds[i]);
        }

        uint256 maturity = markets[0].maturity;

        for (uint256 i = 0; i < length; i++) {
            Market memory market = markets[i];
            bytes32 id = marketIds[i];

            // E1: loanToken == usdc
            require(market.loanToken == USDC, IneligibleMarket(id, 1));

            // E2: maturity == T, same T for every market in the basket
            require(market.maturity == maturity, IneligibleMarket(id, 2));

            // E3: ungated
            require(market.enterGate == address(0) && market.liquidatorGate == address(0), IneligibleMarket(id, 3));

            // E4: every accepted collateral is allowed, with an allowed oracle, within the lltv ceiling
            uint256 collateralCount = market.collateralParams.length;
            require(collateralCount <= MAX_COLLATERALS_CHECKED, IneligibleMarket(id, 4));
            for (uint256 c = 0; c < collateralCount; c++) {
                address token = market.collateralParams[c].token;
                address oracle = market.collateralParams[c].oracle;
                uint256 lltv = market.collateralParams[c].lltv;
                require(collateralAllowed[token], IneligibleMarket(id, 4));
                require(oracleAllowed[token][oracle], IneligibleMarket(id, 4));
                require(lltv <= maxLltvWad && lltv < 1e18, IneligibleMarket(id, 4));
            }

            // E5: no duplicate market ids in the basket
            for (uint256 j = 0; j < i; j++) {
                require(marketIds[j] != id, DuplicateMarket(id));
            }
        }

        // E6: 1 <= basket.length <= maxMarketsPerSeries -- length already bounded above; this restates the
        // lower bound explicitly for clarity at the call site.
        require(length >= 1, BasketEmpty());
    }

    function _decimalsOf(address token) internal view returns (uint8) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok && data.length >= 32, DecimalsNotSix());
        return abi.decode(data, (uint8));
    }
}
