// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: one-market Morpho Blue stand-in using Blue's own share math and accrual, with borrow, rate and bad debt knobs.
// @author adiii.eth

pragma solidity 0.8.34;

import {MarketParams, Market, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-org/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "@morpho-org/morpho-blue/src/libraries/SharesMathLib.sol";
import {MathLib} from "@morpho-org/morpho-blue/src/libraries/MathLib.sol";
import {MockUSDC} from "./MockUSDC.sol";

contract MockBlueIrm {
    uint256 public rate;

    function setRate(uint256 ratePerSecond) external {
        rate = ratePerSecond;
    }

    function borrowRateView(MarketParams memory, Market memory) external view returns (uint256) {
        return rate;
    }

    function borrowRate(MarketParams memory, Market memory) external view returns (uint256) {
        return rate;
    }
}

contract MockMorphoBlue {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using MathLib for uint256;
    using MathLib for uint128;

    error NotCreated();
    error InsufficientLiquidity();
    error Unauthorized();

    address public constant SINK = address(0xB0B);

    MockUSDC public immutable USDC;
    mapping(Id => Market) internal _market;
    mapping(Id => MarketParams) internal _params;
    mapping(Id => mapping(address => uint256)) public supplyShares;
    mapping(Id => uint256) public liquidityCap;

    constructor(MockUSDC usdc) {
        USDC = usdc;
    }

    function createMarket(MarketParams memory params) external {
        Id id = params.id();
        _params[id] = params;
        _market[id].lastUpdate = uint128(block.timestamp);
        liquidityCap[id] = type(uint256).max;
    }

    function market(Id id) external view returns (Market memory) {
        return _market[id];
    }

    function accrueInterest(MarketParams memory params) public {
        Id id = params.id();
        Market storage m = _market[id];
        if (m.lastUpdate == 0) revert NotCreated();
        uint256 elapsed = block.timestamp - m.lastUpdate;
        if (elapsed == 0) return;
        if (m.totalBorrowAssets != 0 && params.irm != address(0)) {
            uint256 r = MockBlueIrm(params.irm).borrowRateView(params, m);
            uint256 interest = uint256(m.totalBorrowAssets).wMulDown(r.wTaylorCompounded(elapsed));
            m.totalBorrowAssets += uint128(interest);
            m.totalSupplyAssets += uint128(interest);
        }
        m.lastUpdate = uint128(block.timestamp);
    }

    function supply(MarketParams memory params, uint256 assets, uint256 shares, address onBehalf, bytes calldata)
        external
        returns (uint256, uint256)
    {
        accrueInterest(params);
        Market storage m = _market[params.id()];
        if (assets > 0) shares = assets.toSharesDown(m.totalSupplyAssets, m.totalSupplyShares);
        else assets = shares.toAssetsUp(m.totalSupplyAssets, m.totalSupplyShares);
        supplyShares[params.id()][onBehalf] += shares;
        m.totalSupplyShares += uint128(shares);
        m.totalSupplyAssets += uint128(assets);
        require(USDC.transferFrom(msg.sender, address(this), assets), "transfer");
        _applyCap(params);
        return (assets, shares);
    }

    function withdraw(MarketParams memory params, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalf) revert Unauthorized();
        accrueInterest(params);
        Market storage m = _market[params.id()];
        if (assets > 0) shares = assets.toSharesUp(m.totalSupplyAssets, m.totalSupplyShares);
        else assets = shares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
        supplyShares[params.id()][onBehalf] -= shares;
        m.totalSupplyShares -= uint128(shares);
        m.totalSupplyAssets -= uint128(assets);
        if (m.totalBorrowAssets > m.totalSupplyAssets) revert InsufficientLiquidity();
        require(USDC.transfer(receiver, assets), "transfer");
        return (assets, shares);
    }

    function borrow(MarketParams memory params, uint256 assets) external {
        accrueInterest(params);
        Market storage m = _market[params.id()];
        m.totalBorrowAssets += uint128(assets);
        if (m.totalBorrowAssets > m.totalSupplyAssets) revert InsufficientLiquidity();
        require(USDC.transfer(SINK, assets), "transfer");
    }

    function repay(MarketParams memory params, uint256 assets) external {
        accrueInterest(params);
        Market storage m = _market[params.id()];
        if (assets > m.totalBorrowAssets) assets = m.totalBorrowAssets;
        m.totalBorrowAssets -= uint128(assets);
        USDC.mint(address(this), assets);
    }

    function realizeBadDebt(MarketParams memory params, uint256 assets) external {
        accrueInterest(params);
        Market storage m = _market[params.id()];
        if (assets > m.totalBorrowAssets) assets = m.totalBorrowAssets;
        m.totalBorrowAssets -= uint128(assets);
        m.totalSupplyAssets -= uint128(assets);
    }

    function setLiquidityCap(MarketParams memory params, uint256 cap) external {
        accrueInterest(params);
        liquidityCap[params.id()] = cap;
        Market storage m = _market[params.id()];
        uint256 liquid = m.totalSupplyAssets - m.totalBorrowAssets;
        if (liquid < cap) {
            uint256 back = cap - liquid;
            if (back > m.totalBorrowAssets) back = m.totalBorrowAssets;
            m.totalBorrowAssets -= uint128(back);
            USDC.mint(address(this), back);
        }
        _applyCap(params);
    }

    function addYield(MarketParams memory params, uint256 assets) external {
        accrueInterest(params);
        _market[params.id()].totalSupplyAssets += uint128(assets);
        USDC.mint(address(this), assets);
    }

    function loseAssets(MarketParams memory params, uint256 assets) external {
        accrueInterest(params);
        Market storage m = _market[params.id()];
        uint256 cash = m.totalSupplyAssets - m.totalBorrowAssets;
        uint256 fromCash = assets < cash ? assets : cash;
        m.totalSupplyAssets -= uint128(fromCash);
        if (fromCash > 0) require(USDC.transfer(SINK, fromCash), "transfer");
        uint256 rest = assets - fromCash;
        if (rest > m.totalBorrowAssets) rest = m.totalBorrowAssets;
        m.totalBorrowAssets -= uint128(rest);
        m.totalSupplyAssets -= uint128(rest);
    }

    function _applyCap(MarketParams memory params) internal {
        Market storage m = _market[params.id()];
        uint256 cap = liquidityCap[params.id()];
        uint256 liquid = m.totalSupplyAssets - m.totalBorrowAssets;
        if (liquid > cap) {
            uint256 excess = liquid - cap;
            m.totalBorrowAssets += uint128(excess);
            require(USDC.transfer(SINK, excess), "transfer");
        }
    }
}
