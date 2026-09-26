// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: shared system-under-test setup, series registry and ghost variables for the invariant suite.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Midnight} from "@morpho-org/midnight/src/Midnight.sol";
import {SetterRatifier} from "@morpho-org/midnight/src/ratifiers/SetterRatifier.sol";
import {Market, CollateralParams, Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {IdLib} from "@morpho-org/midnight/src/libraries/IdLib.sol";

import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {MockOracle} from "../../mocks/MockOracle.sol";
import {StubCore} from "../../mocks/StubCore.sol";
import {seriesFactory} from "../../../src/series/seriesFactory.sol";
import {creditSeries} from "../../../src/series/creditSeries.sol";
import {SeriesParams} from "../../../src/interfaces/iSeries.sol";
import {iMidnightMinimal} from "../../../src/interfaces/iMidnightMinimal.sol";
import {iParking} from "../../../src/parking/iParking.sol";
import {idleParking} from "../../../src/parking/idleParking.sol";
import {seriesCore} from "../../../src/core/seriesCore.sol";
import {usdcSeniorVault} from "../../../src/vaults/senior/usdcSeniorVault.sol";
import {usdcJuniorVault} from "../../../src/vaults/junior/usdcJuniorVault.sol";

contract SeriesRegistry is Test {
    uint256 public constant WAD = 1e18;
    uint256 public constant LLTV = 0.77e18;
    uint256 public constant CURSOR = 0.25e18;

    Midnight public midnight;
    SetterRatifier public setterRatifier;
    MockUSDC public usdc;
    MockOracle public oracle;
    address public collateralToken;
    seriesFactory public factory;
    StubCore public core;
    seriesFactory public realFactory;
    iParking public parking;

    seriesCore public realCore;
    usdcSeniorVault public seniorVault;
    usdcJuniorVault public juniorVault;

    address public constant ALLOCATOR = address(0xA110C000);
    address public constant SENTINEL = address(0xC0FFEE);
    address public constant FEE_RECIPIENT = address(0xFEE);
    address public constant CURATOR = address(0xCADA702);
    address public constant GOVERNANCE = address(0x60F);

    struct SeriesInfo {
        bytes32 marketId;
        uint256 maturity;
        bool registeredAnOffer;
        address lastBorrower;
    }

    address[] public activeSeries;
    address[] public everSeries;
    mapping(address => bool) public everSeen;
    mapping(address => SeriesInfo) public info;
    mapping(address => Offer) internal _lastOffer;
    mapping(address => bytes32) public lastOfferRoot;

    uint256 public ghost_totalUsdcFundedIntoSeries;
    uint256 public ghost_totalUnitsBought;
    uint256 public ghost_callCount;
    mapping(bytes4 => uint256) public ghost_callsPerSelector;
    mapping(bytes4 => uint256) public ghost_revertsPerSelector;

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

        factory = new seriesFactory(
            iMidnightMinimal(address(midnight)), address(setterRatifier), address(usdc), address(this), 0.86e18, 4
        );
        core = new StubCore(address(usdc), SENTINEL);
        factory.setCore(address(core));

        realFactory = new seriesFactory(
            iMidnightMinimal(address(midnight)), address(setterRatifier), address(usdc), address(this), 0.86e18, 4
        );

        factory.proposeCollateralAllowed(collateralToken, true);
        factory.proposeOracleAllowed(collateralToken, address(oracle), true);
        realFactory.proposeCollateralAllowed(collateralToken, true);
        realFactory.proposeOracleAllowed(collateralToken, address(oracle), true);
        vm.warp(block.timestamp + 48 hours);
        factory.executeCollateralAllowed(collateralToken, true);
        factory.executeOracleAllowed(collateralToken, address(oracle), true);
        realFactory.executeCollateralAllowed(collateralToken, true);
        realFactory.executeOracleAllowed(collateralToken, address(oracle), true);

        parking = _deployParking();
        usdc.mint(address(core), 100_000_000e6);

        realCore = new seriesCore(address(usdc), realFactory, parking, GOVERNANCE, ALLOCATOR, CURATOR, SENTINEL);
        realFactory.setCore(address(realCore));
        seniorVault = new usdcSeniorVault(realCore, address(usdc));
        juniorVault = new usdcJuniorVault(realCore, address(usdc));
        vm.prank(GOVERNANCE);
        realCore.setVaults(address(seniorVault), address(juniorVault));
        vm.prank(GOVERNANCE);
        realCore.setFeeRecipient(FEE_RECIPIENT);
    }

    function _deployParking() internal virtual returns (iParking) {
        return new idleParking(address(usdc));
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

    function pickActive(uint256 seed) public view returns (address series, uint256 index) {
        uint256 length = activeSeries.length;
        if (length == 0) return (address(0), 0);
        index = seed % length;
        series = activeSeries[index];
    }

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
        if (!everSeen[series]) {
            everSeen[series] = true;
            everSeries.push(series);
        }
    }

    function everSeriesCount() external view returns (uint256) {
        return everSeries.length;
    }

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

    function setDefaultContinuousFee(uint256 fee) external {
        midnight.setDefaultContinuousFee(address(usdc), fee);
    }

    function recordCall(bytes4 selector, bool reverted) external {
        ghost_callCount++;
        ghost_callsPerSelector[selector]++;
        if (reverted) ghost_revertsPerSelector[selector]++;
    }
}
