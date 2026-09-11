// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {IMidnightMinimal} from "../interfaces/IMidnightMinimal.sol";
import {MidnightReader} from "../libraries/MidnightReader.sol";

/// @dev Factory allowlists and per-series eligibility checks, section 7. The factory is the only place basket
/// eligibility is enforced on chain (E1-E6); everything else about a proposed series (params, S/J split,
/// coverage band) is checked by the core before it ever calls here (section 8.2).
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

    /// @dev section 5.5: reject any loan token whose decimals() != 6, both here and in the core.
    uint8 internal constant USDC_DECIMALS = 6;

    /// @dev section 7.1 hard ceilings, enforced in code regardless of what governance sets.
    uint256 internal constant HARD_MAX_LLTV_WAD = 0.915e18;
    uint256 internal constant HARD_MAX_MARKETS_PER_SERIES = 8;
    uint256 internal constant MAX_COLLATERALS_CHECKED = 8;
    uint256 internal constant TIMELOCK = 48 hours;

    IMidnightMinimal public immutable MIDNIGHT;
    address public immutable USDC;
    address public governance;
    address public core;

    mapping(address token => bool) public collateralAllowed;
    mapping(address token => mapping(address oracle => bool)) public oracleAllowed;
    uint256 public maxLltvWad;
    uint256 public maxMarketsPerSeries;

    /// @dev Timelocked allowlist changes (section 7.1). A change never affects a series already open, because
    /// each series snapshots what it needs at creation (the eligibility check itself, run once, at open time).
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

    constructor(IMidnightMinimal midnight, address usdc, address governance_, uint256 initialMaxLltvWad, uint256 initialMaxMarketsPerSeries)
    {
        require(_decimalsOf(usdc) == USDC_DECIMALS, DecimalsNotSix());
        MIDNIGHT = midnight;
        USDC = usdc;
        governance = governance_;
        maxLltvWad = initialMaxLltvWad <= HARD_MAX_LLTV_WAD ? initialMaxLltvWad : HARD_MAX_LLTV_WAD;
        maxMarketsPerSeries =
            initialMaxMarketsPerSeries <= HARD_MAX_MARKETS_PER_SERIES ? initialMaxMarketsPerSeries : HARD_MAX_MARKETS_PER_SERIES;
    }

    /// @dev The core is set once, after deployment (core and factory reference each other, so neither can be
    /// passed to the other's constructor). Governance-only, and only while unset, so it can never be rebound
    /// out from under an already-live product.
    function setCore(address core_) external onlyGovernance {
        require(core == address(0), NotGovernance());
        core = core_;
        emit CoreSet(core_);
    }

    // --- timelocked allowlist changes (section 7.1) -----------------------------------------------------

    function proposeCollateralAllowed(address token, bool allowed) external onlyGovernance returns (bytes32 id) {
        id = keccak256(abi.encode("collateral", token, allowed));
        uint256 executableAt = block.timestamp + TIMELOCK;
        pendingChanges[id] = PendingChange(true, executableAt);
        emit CollateralAllowlistProposed(token, allowed, executableAt);
    }

    function executeCollateralAllowed(address token, bool allowed) external {
        bytes32 id = keccak256(abi.encode("collateral", token, allowed));
        _consumeTimelock(id);
        collateralAllowed[token] = allowed;
        emit CollateralAllowlistExecuted(token, allowed);
    }

    function proposeOracleAllowed(address token, address oracle, bool allowed) external onlyGovernance returns (bytes32 id) {
        id = keccak256(abi.encode("oracle", token, oracle, allowed));
        uint256 executableAt = block.timestamp + TIMELOCK;
        pendingChanges[id] = PendingChange(true, executableAt);
        emit OracleAllowlistProposed(token, oracle, allowed, executableAt);
    }

    function executeOracleAllowed(address token, address oracle, bool allowed) external {
        bytes32 id = keccak256(abi.encode("oracle", token, oracle, allowed));
        _consumeTimelock(id);
        oracleAllowed[token][oracle] = allowed;
        emit OracleAllowlistExecuted(token, oracle, allowed);
    }

    function proposeMaxLltv(uint256 newMaxLltvWad) external onlyGovernance returns (bytes32 id) {
        require(newMaxLltvWad <= HARD_MAX_LLTV_WAD, IneligibleMarket(bytes32(0), 4));
        id = keccak256(abi.encode("maxLltv", newMaxLltvWad));
        uint256 executableAt = block.timestamp + TIMELOCK;
        pendingChanges[id] = PendingChange(true, executableAt);
        emit MaxLltvProposed(newMaxLltvWad, executableAt);
    }

    function executeMaxLltv(uint256 newMaxLltvWad) external {
        bytes32 id = keccak256(abi.encode("maxLltv", newMaxLltvWad));
        _consumeTimelock(id);
        maxLltvWad = newMaxLltvWad;
        emit MaxLltvExecuted(newMaxLltvWad);
    }

    function proposeMaxMarketsPerSeries(uint256 newMax) external onlyGovernance returns (bytes32 id) {
        require(newMax <= HARD_MAX_MARKETS_PER_SERIES, IneligibleMarket(bytes32(0), 6));
        id = keccak256(abi.encode("maxMarkets", newMax));
        uint256 executableAt = block.timestamp + TIMELOCK;
        pendingChanges[id] = PendingChange(true, executableAt);
        emit MaxMarketsPerSeriesProposed(newMax, executableAt);
    }

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

    // --- eligibility (section 7.2) ------------------------------------------------------------------------

    /// @dev Checks E1-E6 for a proposed basket, given market ids. The canonical Market struct for each id is
    /// read from Midnight itself (section 7.2: "read the market config from midnight through
    /// MidnightReader.marketConfig(id)"), never trusted from the caller -- a caller-supplied struct could
    /// describe a market that doesn't match the id actually traded against, making the whole eligibility check
    /// meaningless. Reverts with IneligibleMarket(id, rule) on the first violation found; rule numbers match
    /// the spec's E-numbering (1-indexed: E1..E6) for easy cross-reference.
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
