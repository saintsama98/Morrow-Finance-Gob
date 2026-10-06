// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: collateral/oracle/LLTV allowlists and basket eligibility checks for new series.
// @author adiii.eth

pragma solidity 0.8.34;

import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {iMidnightMinimal} from "../interfaces/iMidnightMinimal.sol";
import {midnightReader} from "../libraries/midnightReader.sol";
import {SeriesParams} from "../interfaces/iSeries.sol";
import {creditSeries} from "./creditSeries.sol";

/// @notice Market eligibility rules, the governance allowlists behind a 48-hour timelock, and series creation.
contract seriesFactory {
    using midnightReader for iMidnightMinimal;

    error NotGovernance();
    error NotCore();
    error IneligibleMarket(bytes32 id, uint8 rule);
    error BasketTooLarge();
    error BasketEmpty();
    error DuplicateMarket(bytes32 id);
    error TimelockNotElapsed();
    error DecimalsNotSix();

    uint8 internal constant USDC_DECIMALS = 6;

    uint256 internal constant HARD_MAX_LLTV_WAD = 0.915e18;
    uint256 public constant CURSOR_RULE_LLTV_WAD = 0.915e18;
    uint256 public constant CURSOR_RULE_MIN_WAD = 0.5e18;
    uint256 public constant TENOR_TIER_DURATION = 91 days;
    uint256 public constant TENOR_TIER_MAX_LLTV_WAD = 0.86e18;
    uint256 internal constant HARD_MAX_MARKETS_PER_SERIES = 8;
    uint256 internal constant MAX_COLLATERALS_CHECKED = 8;
    uint256 internal constant TIMELOCK = 48 hours;

    iMidnightMinimal public immutable MIDNIGHT;
    address public immutable SETTER_RATIFIER;
    address public immutable USDC;
    address public governance;
    address public core;

    mapping(address token => bool) public collateralAllowed;
    mapping(address token => mapping(address oracle => bool)) public oracleAllowed;
    uint256 public maxLltvWad;
    uint256 public maxMarketsPerSeries;

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
        iMidnightMinimal midnight,
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

    /// @notice Wires the core; callable once.
    function setCore(address core_) external onlyGovernance {
        require(core == address(0), NotGovernance());
        core = core_;
        emit CoreSet(core_);
    }

    /// @notice Queues an allowlist change for a collateral token.
    function proposeCollateralAllowed(address token, bool allowed) external onlyGovernance returns (bytes32 id) {
        id = keccak256(abi.encode("collateral", token, allowed));
        uint256 executableAt = block.timestamp + TIMELOCK;
        pendingChanges[id] = PendingChange(true, executableAt);
        emit CollateralAllowlistProposed(token, allowed, executableAt);
    }

    /// @notice Applies a queued collateral allowlist change.
    function executeCollateralAllowed(address token, bool allowed) external {
        bytes32 id = keccak256(abi.encode("collateral", token, allowed));
        _consumeTimelock(id);
        collateralAllowed[token] = allowed;
        emit CollateralAllowlistExecuted(token, allowed);
    }

    /// @notice Queues an allowlist change for a collateral's oracle.
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

    /// @notice Applies a queued oracle allowlist change.
    function executeOracleAllowed(address token, address oracle, bool allowed) external {
        bytes32 id = keccak256(abi.encode("oracle", token, oracle, allowed));
        _consumeTimelock(id);
        oracleAllowed[token][oracle] = allowed;
        emit OracleAllowlistExecuted(token, oracle, allowed);
    }

    /// @notice Queues a new liquidation threshold ceiling, capped at 0.915.
    function proposeMaxLltv(uint256 newMaxLltvWad) external onlyGovernance returns (bytes32 id) {
        require(newMaxLltvWad <= HARD_MAX_LLTV_WAD, IneligibleMarket(bytes32(0), 4));
        id = keccak256(abi.encode("maxLltv", newMaxLltvWad));
        uint256 executableAt = block.timestamp + TIMELOCK;
        pendingChanges[id] = PendingChange(true, executableAt);
        emit MaxLltvProposed(newMaxLltvWad, executableAt);
    }

    /// @notice Applies a queued threshold ceiling.
    function executeMaxLltv(uint256 newMaxLltvWad) external {
        bytes32 id = keccak256(abi.encode("maxLltv", newMaxLltvWad));
        _consumeTimelock(id);
        maxLltvWad = newMaxLltvWad;
        emit MaxLltvExecuted(newMaxLltvWad);
    }

    /// @notice Queues a new limit on markets per basket, capped at 8.
    function proposeMaxMarketsPerSeries(uint256 newMax) external onlyGovernance returns (bytes32 id) {
        require(newMax <= HARD_MAX_MARKETS_PER_SERIES, IneligibleMarket(bytes32(0), 6));
        id = keccak256(abi.encode("maxMarkets", newMax));
        uint256 executableAt = block.timestamp + TIMELOCK;
        pendingChanges[id] = PendingChange(true, executableAt);
        emit MaxMarketsPerSeriesProposed(newMax, executableAt);
    }

    /// @notice Applies a queued market limit.
    function executeMaxMarketsPerSeries(uint256 newMax) external {
        bytes32 id = keccak256(abi.encode("maxMarkets", newMax));
        _consumeTimelock(id);
        maxMarketsPerSeries = newMax;
        emit MaxMarketsPerSeriesExecuted(newMax);
    }

    /// @notice Hands factory governance to a new address.
    function transferGovernance(address newGovernance) external onlyGovernance {
        governance = newGovernance;
        emit GovernanceUpdated(newGovernance);
    }

    function _consumeTimelock(bytes32 id) internal {
        PendingChange memory change = pendingChanges[id];
        require(change.active && block.timestamp >= change.executableAt, TimelockNotElapsed());
        delete pendingChanges[id];
    }

    error InvalidCovBand();
    error InvalidPremiumAnchors();
    error ThetaAboveCeiling();
    error ZeroRateFloor();
    error MarketArrayLengthMismatch();

    modifier onlyCore() {
        require(msg.sender == core, NotCore());
        _;
    }

    /// @notice Deploys a series for the core.
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

        series = address(new creditSeries(MIDNIGHT, SETTER_RATIFIER, USDC, core, markets, p));
    }

    /// @notice Returns the markets if every one passes the rules, else reverts with the failed rule.
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

            require(market.loanToken == USDC, IneligibleMarket(id, 1));

            require(market.maturity == maturity, IneligibleMarket(id, 2));

            require(market.enterGate == address(0) && market.liquidatorGate == address(0), IneligibleMarket(id, 3));

            uint256 collateralCount = market.collateralParams.length;
            require(collateralCount <= MAX_COLLATERALS_CHECKED, IneligibleMarket(id, 4));
            for (uint256 c = 0; c < collateralCount; c++) {
                address token = market.collateralParams[c].token;
                address oracle = market.collateralParams[c].oracle;
                uint256 lltv = market.collateralParams[c].lltv;
                require(collateralAllowed[token], IneligibleMarket(id, 4));
                require(oracleAllowed[token][oracle], IneligibleMarket(id, 4));
                require(lltv <= maxLltvWad && lltv < 1e18, IneligibleMarket(id, 4));
                require(
                    lltv < CURSOR_RULE_LLTV_WAD || market.collateralParams[c].liquidationCursor >= CURSOR_RULE_MIN_WAD,
                    IneligibleMarket(id, 7)
                );
                require(
                    market.maturity <= block.timestamp + TENOR_TIER_DURATION || lltv <= TENOR_TIER_MAX_LLTV_WAD,
                    IneligibleMarket(id, 8)
                );
            }

            for (uint256 j = 0; j < i; j++) {
                require(marketIds[j] != id, DuplicateMarket(id));
            }
        }

        require(length >= 1, BasketEmpty());
    }

    function _decimalsOf(address token) internal view returns (uint8) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok && data.length >= 32, DecimalsNotSix());
        return abi.decode(data, (uint8));
    }
}
