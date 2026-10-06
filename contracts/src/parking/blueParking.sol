// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: parking adapter that lends idle USDC directly in one Morpho Blue market while keeping a USDC buffer.
// @author adiii.eth

pragma solidity 0.8.34;

import {IMorpho, MarketParams, Market, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-org/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "@morpho-org/morpho-blue/src/libraries/SharesMathLib.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {iParking} from "./iParking.sol";
import {iErc20Like} from "../interfaces/iErc20Like.sol";
import {wadMath} from "../libraries/wadMath.sol";

/// @notice The part of the series factory the Blue adapter reads.
interface iParkingFactoryLike {
    /// @notice Core address.
    function core() external view returns (address);
    /// @notice Loan token.
    function USDC() external view returns (address);
    /// @notice Whether a collateral token is allowlisted.
    function collateralAllowed(address token) external view returns (bool);
    /// @notice Whether an oracle is allowlisted for a collateral.
    function oracleAllowed(address token, address oracle) external view returns (bool);
    /// @notice Highest permitted liquidation threshold.
    function maxLltvWad() external view returns (uint256);
}

/// @notice The part of the core the Blue adapter reads.
interface iParkingCoreLike {
    /// @notice Current curator.
    function curator() external view returns (address);
    /// @notice Current sentinel.
    function sentinel() external view returns (address);
    /// @notice Series registry entry; the last field is whether the address is a registered series.
    function info(address series) external view returns (uint256, uint256, uint256, bool);
}

/// @notice Parking that lends idle cash directly in one Morpho Blue market, with a raw USDC buffer.
contract blueParking is iParking {
    using wadMath for uint256;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using MorphoBalancesLib for IMorpho;

    error ZeroAddress();
    error AssetMismatch();
    error InvalidBuffer();
    error MarketNotEligible();
    error MarketNotCreated();
    error NotAuthorized();
    error InsufficientBalance();
    error Illiquid(uint256 asked, uint256 available);
    error Reentrancy();
    error ZeroShares();
    error TransferFailed();

    event Deposited(address indexed account, uint256 assets, uint256 shares);
    event Withdrawn(address indexed account, address indexed to, uint256 assets, uint256 shares);
    event Transferred(address indexed from, address indexed to, uint256 assets, uint256 shares);
    event Rebalanced(uint256 buffer, uint256 blueAssets);
    event ExitedToCash(address indexed by, uint256 pulled, uint256 blueAssetsLeft);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant VIRTUAL_SHARES = 1e12;

    uint256 public constant DUST_ASSETS = 100;

    iErc20Like public immutable USDC;
    IMorpho public immutable MORPHO;
    iParkingFactoryLike public immutable FACTORY;
    Id public immutable MARKET_ID;
    address public immutable COLLATERAL;
    address public immutable ORACLE;
    address public immutable IRM;
    uint256 public immutable LLTV;
    uint256 public immutable BUFFER_WAD;

    mapping(address account => uint256) public sharesOf;
    uint256 public totalShares;
    uint256 public blueShares;
    bool public exited;

    uint256 private _lock = 1;

    modifier nonReentrant() {
        require(_lock == 1, Reentrancy());
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier onlyMorrow() {
        _requireMorrow(msg.sender);
        _;
    }

    constructor(address usdc, address morpho, address factory, MarketParams memory params, uint256 bufferWad) {
        require(usdc != address(0) && morpho != address(0) && factory != address(0), ZeroAddress());
        require(params.loanToken == usdc && iParkingFactoryLike(factory).USDC() == usdc, AssetMismatch());
        require(bufferWad <= WAD, InvalidBuffer());
        require(
            iParkingFactoryLike(factory).collateralAllowed(params.collateralToken)
                && iParkingFactoryLike(factory).oracleAllowed(params.collateralToken, params.oracle)
                && params.lltv <= iParkingFactoryLike(factory).maxLltvWad(),
            MarketNotEligible()
        );
        Id id = params.id();
        require(IMorpho(morpho).market(id).lastUpdate != 0, MarketNotCreated());

        USDC = iErc20Like(usdc);
        MORPHO = IMorpho(morpho);
        FACTORY = iParkingFactoryLike(factory);
        MARKET_ID = id;
        COLLATERAL = params.collateralToken;
        ORACLE = params.oracle;
        IRM = params.irm;
        LLTV = params.lltv;
        BUFFER_WAD = bufferWad;
    }

    /// @notice Parks assets for the caller and lends the excess over the buffer in Blue.
    function deposit(uint256 assets) external nonReentrant onlyMorrow {
        if (assets == 0) return;
        uint256 pool = poolAssets();
        uint256 shares = assets.mulDivDown(totalShares + VIRTUAL_SHARES, pool + 1);
        require(shares > 0, ZeroShares());

        sharesOf[msg.sender] += shares;
        totalShares += shares;
        require(USDC.transferFrom(msg.sender, address(this), assets), TransferFailed());
        emit Deposited(msg.sender, assets, shares);

        _investExcess();
    }

    /// @notice Withdraws the caller's assets, pulling from Blue if the buffer is short.
    function withdraw(uint256 assets, address to) external nonReentrant onlyMorrow {
        if (assets == 0) return;
        require(to != address(0), ZeroAddress());
        uint256 shares = _burnFor(msg.sender, assets);

        _ensureBuffer(assets);
        require(USDC.transfer(to, assets), TransferFailed());
        emit Withdrawn(msg.sender, to, assets, shares);

        _refillIfLow();
    }

    /// @notice Moves part of the caller's position; a series may move it only to the core.
    function transferPosition(address to, uint256 assets) external nonReentrant onlyMorrow {
        if (assets == 0) return;
        require(to != address(0), ZeroAddress());
        address core = FACTORY.core();
        require(msg.sender == core || to == core, NotAuthorized());
        uint256 shares = _burnFor(msg.sender, assets);
        sharesOf[to] += shares;
        totalShares += shares;
        emit Transferred(msg.sender, to, assets, shares);
    }

    /// @notice Moves the raw buffer back to its target; anyone may call.
    function rebalance() external nonReentrant {
        uint256 target = poolAssets().mulDivDown(BUFFER_WAD, WAD);
        uint256 buffer = USDC.balanceOf(address(this));
        if (buffer > target) _supply(buffer - target);
        else if (buffer < target) _pull(target - buffer);
        emit Rebalanced(USDC.balanceOf(address(this)), blueAssets());
    }

    /// @notice Pulls everything liquid out of Blue and stops lending; sentinel or curator, one-way.
    function exitToCash() external nonReentrant {
        address core = FACTORY.core();
        require(
            msg.sender == iParkingCoreLike(core).sentinel() || msg.sender == iParkingCoreLike(core).curator(),
            NotAuthorized()
        );
        exited = true;
        uint256 before = USDC.balanceOf(address(this));
        _pull(type(uint256).max);
        emit ExitedToCash(msg.sender, USDC.balanceOf(address(this)) - before, blueAssets());
    }

    /// @notice Value of an account's position.
    function totalAssets(address account) public view returns (uint256) {
        return sharesOf[account].mulDivDown(poolAssets() + 1, totalShares + VIRTUAL_SHARES);
    }

    /// @notice Assets an account can withdraw now.
    function maxWithdraw(address account) external view returns (uint256) {
        uint256 owned = totalAssets(account);
        uint256 liquid = liquidity();
        return owned < liquid ? owned : liquid;
    }

    /// @notice Raw buffer plus the Blue position.
    function poolAssets() public view returns (uint256) {
        return USDC.balanceOf(address(this)) + blueAssets();
    }

    /// @notice Raw buffer plus what Blue can pay out now.
    function liquidity() public view returns (uint256) {
        return USDC.balanceOf(address(this)) + blueLiquidity();
    }

    /// @notice Parameters of the Blue market.
    function marketParams() public view returns (MarketParams memory) {
        return
            MarketParams({loanToken: address(USDC), collateralToken: COLLATERAL, oracle: ORACLE, irm: IRM, lltv: LLTV});
    }

    /// @notice Value of the Blue position after accrued interest.
    function blueAssets() public view returns (uint256) {
        uint256 shares = blueShares;
        if (shares == 0) return 0;
        (uint256 supplyAssets, uint256 supplyShares,,) = MORPHO.expectedMarketBalances(marketParams());
        return shares.toAssetsDown(supplyAssets, supplyShares);
    }

    /// @notice Part of the Blue position the market can pay out now.
    function blueLiquidity() public view returns (uint256) {
        uint256 shares = blueShares;
        if (shares == 0) return 0;
        (uint256 supplyAssets, uint256 supplyShares, uint256 borrowAssets,) =
            MORPHO.expectedMarketBalances(marketParams());
        uint256 owned = shares.toAssetsDown(supplyAssets, supplyShares);
        uint256 marketLiquid = supplyAssets > borrowAssets ? supplyAssets - borrowAssets : 0;
        return owned < marketLiquid ? owned : marketLiquid;
    }

    function _requireMorrow(address caller) internal view {
        address core = FACTORY.core();
        if (caller == core) return;
        (,,, bool registered) = iParkingCoreLike(core).info(caller);
        require(registered, NotAuthorized());
    }

    function _investExcess() internal {
        uint256 target = poolAssets().mulDivDown(BUFFER_WAD, WAD);
        uint256 buffer = USDC.balanceOf(address(this));
        if (buffer > target) _supply(buffer - target);
    }

    function _refillIfLow() internal {
        uint256 target = poolAssets().mulDivDown(BUFFER_WAD, WAD);
        uint256 buffer = USDC.balanceOf(address(this));
        if (buffer < target / 2) _pull(target - buffer);
    }

    function _supply(uint256 amount) internal {
        if (exited || amount == 0) return;
        require(USDC.approve(address(MORPHO), amount), TransferFailed());
        (, uint256 minted) = MORPHO.supply(marketParams(), amount, 0, address(this), "");
        blueShares += minted;
    }

    function _pull(uint256 amount) internal {
        uint256 owned = blueAssets();
        uint256 liquid = blueLiquidity();
        if (amount > liquid) amount = liquid;
        if (amount == 0) return;
        if (amount >= owned) {
            (, uint256 burned) = MORPHO.withdraw(marketParams(), 0, blueShares, address(this), address(this));
            blueShares -= burned;
        } else {
            (, uint256 burned) = MORPHO.withdraw(marketParams(), amount, 0, address(this), address(this));
            blueShares -= burned;
        }
    }

    function _ensureBuffer(uint256 assets) internal {
        uint256 buffer = USDC.balanceOf(address(this));
        if (buffer >= assets) return;
        uint256 need = assets - buffer;
        uint256 available = blueLiquidity();
        require(need <= available, Illiquid(assets, buffer + available));
        _pull(need);
    }

    function _burnFor(address account, uint256 assets) internal returns (uint256 shares) {
        uint256 pool = poolAssets();
        shares = assets.mulDivUp(totalShares + VIRTUAL_SHARES, pool + 1);
        uint256 held = sharesOf[account];
        if (shares > held) {
            uint256 heldValueUp = held.mulDivUp(pool + 1, totalShares + VIRTUAL_SHARES);
            require(held > 0 && assets <= heldValueUp + DUST_ASSETS, InsufficientBalance());
            shares = held;
        }
        sharesOf[account] = held - shares;
        totalShares -= shares;
    }
}
