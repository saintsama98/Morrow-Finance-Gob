// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Midnight} from "@morpho-org/midnight/src/Midnight.sol";
import {SetterRatifier} from "@morpho-org/midnight/src/ratifiers/SetterRatifier.sol";
import {Market, CollateralParams, Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {IdLib} from "@morpho-org/midnight/src/libraries/IdLib.sol";

import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {MockOracle} from "../../mocks/MockOracle.sol";
import {StubCore} from "../../mocks/StubCore.sol";
import {SeriesFactory} from "../../../src/series/SeriesFactory.sol";
import {Series} from "../../../src/series/Series.sol";
import {SeriesParams} from "../../../src/interfaces/ISeries.sol";
import {IMidnightMinimal} from "../../../src/interfaces/IMidnightMinimal.sol";
import {IParking} from "../../../src/parking/IParking.sol";
import {IdleParking} from "../../../src/parking/IdleParking.sol";

// Morrow Finance — shared system-under-test setup, series registry and ghost variables for the invariant suite.
// @author adiii.eth

/// @notice Shared SUT references, series registry and ghost variables for the invariant suite.
/// @dev Not itself a handler (not registered as a fuzz target) -- every handler holds a reference to one
/// instance of this and reads/writes its state. All series share ALLOCATOR = address(this registry), so any
/// handler calling an allocator-gated Series function must prank as the registry.
contract SeriesRegistry is Test {
    uint256 public constant WAD = 1e18;
    uint256 public constant LLTV = 0.77e18;
    uint256 public constant CURSOR = 0.25e18;

    Midnight public midnight;
    SetterRatifier public setterRatifier;
    MockUSDC public usdc;
    MockOracle public oracle;
    address public collateralToken;
    SeriesFactory public factory;
    StubCore public core;
    IdleParking public parking;

    address public constant ALLOCATOR = address(0xA110C000);
    address public constant SENTINEL = address(0xC0FFEE);
    address public constant FEE_RECIPIENT = address(0xFEE);

    /// @dev Per-series bookkeeping the handlers need. `active` series are anything not yet SETTLED/CANCELED.
    struct SeriesInfo {
        bytes32 marketId;
        uint256 maturity;
        bool registeredAnOffer;
        address lastBorrower;
    }

    address[] public activeSeries;
    mapping(address => SeriesInfo) public info;
    mapping(address => Offer) internal _lastOffer;
    mapping(address => bytes32) public lastOfferRoot;

    // ghost variables, read by the invariant assertions
    uint256 public ghost_totalUsdcFundedIntoSeries;
    uint256 public ghost_totalUnitsBought;
    uint256 public ghost_callCount;
    mapping(bytes4 => uint256) public ghost_callsPerSelector;
    mapping(bytes4 => uint256) public ghost_revertsPerSelector;

    /// @dev per-series snapshots the invariant test compares against on each run.
    mapping(address => uint256) public ghost_lastCredit;
    mapping(address => uint8) public ghost_lastState;
    mapping(address => bool) public ghost_seenState;

    function setGhostSnapshot(address series, uint256 credit, uint8 stateNow) external {
        ghost_lastCredit[series] = credit;
        ghost_lastState[series] = stateNow;
        ghost_seenState[series] = true;
    }

    constructor() {
        midnight = new Midnight();
        setterRatifier = new SetterRatifier(address(midnight));
        midnight.setFeeSetter(address(this));
        midnight.setTickSpacingSetter(address(this));
        midnight.enableLiquidationCursor(CURSOR);
        midnight.enableLltv(LLTV);

        usdc = new MockUSDC();
        oracle = new MockOracle(1e36 * 60_000);
        collateralToken = address(new MockUSDC());

        factory = new SeriesFactory(
            IMidnightMinimal(address(midnight)), address(setterRatifier), address(usdc), address(this), 0.86e18, 4
        );
        core = new StubCore(address(usdc), SENTINEL);
        factory.setCore(address(core));

        factory.proposeCollateralAllowed(collateralToken, true);
        factory.proposeOracleAllowed(collateralToken, address(oracle), true);
        vm.warp(block.timestamp + 48 hours);
        factory.executeCollateralAllowed(collateralToken, true);
        factory.executeOracleAllowed(collateralToken, address(oracle), true);

        parking = new IdleParking(address(usdc));
        usdc.mint(address(core), 100_000_000e6);
    }

    function activeSeriesCount() external view returns (uint256) {
        return activeSeries.length;
    }

    function idOf(Market memory market) public pure returns (bytes32) {
        return IdLib.toId(market);
    }

    function marketFor(uint256 maturity) public view returns (Market memory market) {
        CollateralParams[] memory params = new CollateralParams[](1);
        params[0] =
            CollateralParams({token: collateralToken, lltv: LLTV, liquidationCursor: CURSOR, oracle: address(oracle)});
        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(usdc),
            collateralParams: params,
            maturity: maturity,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    /// @dev Picks a pseudo-random already-known active series (or address(0) if none), bounded by a caller
    /// supplied seed. Kept here so every handler resolves "which series" the same way.
    function pickActive(uint256 seed) public view returns (address series, uint256 index) {
        uint256 length = activeSeries.length;
        if (length == 0) return (address(0), 0);
        index = seed % length;
        series = activeSeries[index];
    }

    /// @dev Like pickActive, but scans forward (wrapping) from the random start index for the first series
    /// whose registeredAnOffer flag matches `wantOfferRegistered`, instead of giving up on the first miss. Two
    /// independent uniform-random picks (e.g. registerOffer's target and borrowerTakesBid's target) rarely land
    /// on the same series once more than a handful exist; scanning is what makes registerOffer ->
    /// borrowerTakesBid sequences actually correlate often enough to exercise real fills during fuzzing.
    function pickActiveWithOffer(uint256 seed, bool wantOfferRegistered)
        external
        view
        returns (address series, uint256 index)
    {
        uint256 length = activeSeries.length;
        if (length == 0) return (address(0), 0);
        uint256 start = seed % length;
        for (uint256 offset = 0; offset < length; offset++) {
            uint256 i = (start + offset) % length;
            address candidate = activeSeries[i];
            if (info[candidate].registeredAnOffer == wantOfferRegistered) {
                return (candidate, i);
            }
        }
        return (address(0), 0);
    }

    function removeActive(uint256 index) external {
        uint256 length = activeSeries.length;
        require(index < length, "bad index");
        activeSeries[index] = activeSeries[length - 1];
        activeSeries.pop();
    }

    function pushActive(address series, SeriesInfo memory i) external {
        activeSeries.push(series);
        info[series] = i;
    }

    /// @dev Mutates an already-active series' bookkeeping without re-appending it to activeSeries.
    function updateInfo(address series, SeriesInfo memory i) external {
        info[series] = i;
    }

    function setLastOffer(address series, Offer memory offer, bytes32 root) external {
        _lastOffer[series] = offer;
        lastOfferRoot[series] = root;
    }

    function getLastOffer(address series) external view returns (Offer memory) {
        return _lastOffer[series];
    }

    function recordFunded(uint256 amount) external {
        ghost_totalUsdcFundedIntoSeries += amount;
    }

    function recordUnitsBought(uint256 units) external {
        ghost_totalUnitsBought += units;
    }

    /// @dev The registry itself is Midnight's feeSetter (set in the constructor); handlers route fee changes
    /// through this passthrough rather than calling Midnight directly.
    function setDefaultContinuousFee(uint256 fee) external {
        midnight.setDefaultContinuousFee(address(usdc), fee);
    }

    function recordCall(bytes4 selector, bool reverted) external {
        ghost_callCount++;
        ghost_callsPerSelector[selector]++;
        if (reverted) ghost_revertsPerSelector[selector]++;
    }
}
