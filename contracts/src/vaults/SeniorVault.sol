// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SeriesCore} from "../core/SeriesCore.sol";
import {WadMath} from "../libraries/WadMath.sol";
import {EpochMath} from "../libraries/EpochMath.sol";

interface IERC20Like {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// Morrow Finance — senior tranche share token: synchronous deposits, epoch-based async redemptions.
// @author adiii.eth

/// @notice srUSDC: the senior tranche's deposit token. Deposits mint immediately at the live price, gated by
/// capacity and the stress gate. Redemptions queue into epochs and settle against whatever senior liquidity
/// the operator releases, at the lower of the epoch-close price and the fulfillment-time price.
contract SeniorVault is ERC20 {
    using WadMath for uint256;

    error ZeroAssets();
    error ZeroShares();
    error DepositsPaused();
    error StressGateClosed();
    error CapacityExceeded();
    error NotOperator();
    error EpochAlreadyClosed();
    error EpochNotClosed();
    error NothingToClaim();
    error NothingToCancel();

    event Deposit(address indexed sender, address indexed receiver, uint256 assets, uint256 shares);
    event RedeemRequested(address indexed owner, uint256 indexed epochId, uint256 shares);
    event EpochClosed(uint256 indexed epochId, uint256 ppsCloseWad);
    event RedeemFulfilled(uint256 indexed epochId, uint256 sharesFulfilled, uint256 assetsFulfilled, uint256 priceWad);
    event RedeemClaimed(address indexed owner, uint256 indexed epochId, uint256 assets);
    event RedeemCanceled(address indexed owner, uint256 indexed epochId, uint256 shares);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant INITIAL_PRICE_WAD = 1e6; // 1.0 USDC per whole share, before any supply exists

    SeriesCore public immutable CORE;
    address public immutable USDC;

    /// @dev One redemption request queue at a time. Requests always target `openEpochId`; closing it snapshots
    /// the price and opens a fresh one, so later requests can never be priced off an earlier close.
    struct RedeemEpoch {
        uint256 totalSharesRequested;
        uint256 sharesFulfilled; // cumulative, monotonic
        uint256 assetsFulfilled; // cumulative, monotonic
        uint256 ppsCloseWad;
        bool closed;
    }

    uint256 public openEpochId;
    mapping(uint256 => RedeemEpoch) public epochs;
    mapping(uint256 => mapping(address => uint256)) public requestedShares;
    mapping(uint256 => mapping(address => uint256)) public claimedAssets;
    mapping(uint256 => mapping(address => uint256)) public canceledShares;

    modifier onlyOperator() {
        require(msg.sender == CORE.curator() || msg.sender == CORE.allocator(), NotOperator());
        _;
    }

    constructor(SeriesCore core_, address usdc_) ERC20("Morrow Senior USDC", "srUSDC") {
        CORE = core_;
        USDC = usdc_;
        openEpochId = 1;
    }

    /// @notice Assets per whole (1e18) share, live.
    function pricePerShareWad() public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? INITIAL_PRICE_WAD : CORE.seniorAssets().mulDivDown(WAD, supply);
    }

    // --- deposit (synchronous) ----------------------------------------------------------------------------

    /// @notice Deposits `assets` and mints shares to `receiver` at the live price. Reverts while paused, while
    /// the stress gate is closed, or if the deposit would push the senior book past its junior-backed capacity.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(assets > 0, ZeroAssets());
        require(!CORE.paused(), DepositsPaused());
        require(CORE.stressGateOpen(), StressGateClosed());
        require(CORE.seniorAssets() + assets <= CORE.seniorCapacity(), CapacityExceeded());

        shares = EpochMath.sharesForAssets(assets, pricePerShareWad());
        require(shares > 0, ZeroShares());

        require(IERC20Like(USDC).transferFrom(msg.sender, address(CORE), assets), "transfer failed");
        CORE.depositFor(true, assets);

        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    // --- redeem (async, epoch-based) ----------------------------------------------------------------------

    /// @notice Escrows `shares` and queues a redemption request against the currently open epoch.
    function requestRedeem(uint256 shares) external returns (uint256 epochId) {
        require(shares > 0, ZeroShares());
        epochId = openEpochId;
        _transfer(msg.sender, address(this), shares);
        requestedShares[epochId][msg.sender] += shares;
        epochs[epochId].totalSharesRequested += shares;
        emit RedeemRequested(msg.sender, epochId, shares);
    }

    /// @notice Stops the open epoch from accepting new requests, snapshots its price ceiling, and opens the
    /// next one. Operator-only.
    function closeEpoch() external onlyOperator returns (uint256 epochId) {
        epochId = openEpochId;
        RedeemEpoch storage e = epochs[epochId];
        require(!e.closed, EpochAlreadyClosed());
        e.closed = true;
        e.ppsCloseWad = pricePerShareWad();
        openEpochId = epochId + 1;
        emit EpochClosed(epochId, e.ppsCloseWad);
    }

    /// @notice Fulfills up to `assetsToUse` of a closed epoch's outstanding requests, bounded by what's
    /// actually idle and available. Burns the fulfilled shares and reserves the matching assets for claiming.
    /// Operator-only; callable repeatedly against the same epoch until it's fully filled.
    function fulfill(uint256 epochId, uint256 assetsToUse) external onlyOperator {
        RedeemEpoch storage e = epochs[epochId];
        require(e.closed, EpochNotClosed());

        uint256 available = CORE.idleAvailable(true);
        uint256 cappedAssets = assetsToUse < available ? assetsToUse : available;

        uint256 priceWad = EpochMath.redemptionPriceWad(e.ppsCloseWad, pricePerShareWad());
        uint256 remainingShares = e.totalSharesRequested - e.sharesFulfilled;
        uint256 sharesNow = EpochMath.sharesFillable(remainingShares, cappedAssets, priceWad);
        if (sharesNow == 0) return;
        uint256 assetsNow = EpochMath.assetsForShares(sharesNow, priceWad);

        CORE.reserveFor(true, assetsNow);
        _burn(address(this), sharesNow);

        e.sharesFulfilled += sharesNow;
        e.assetsFulfilled += assetsNow;
        emit RedeemFulfilled(epochId, sharesNow, assetsNow, priceWad);
    }

    /// @notice Claims the caller's pro-rata share of an epoch's fulfillment so far. Safe to call again after
    /// later fulfillment rounds on the same epoch; only the newly-entitled delta is paid each time.
    function claim(uint256 epochId) external returns (uint256 assets) {
        RedeemEpoch storage e = epochs[epochId];
        uint256 requested = requestedShares[epochId][msg.sender];
        uint256 entitled = EpochMath.claimableAssets(
            requested, e.assetsFulfilled, e.totalSharesRequested, claimedAssets[epochId][msg.sender]
        );
        require(entitled > 0, NothingToClaim());

        claimedAssets[epochId][msg.sender] += entitled;
        CORE.payFrom(true, msg.sender, entitled);
        emit RedeemClaimed(msg.sender, epochId, entitled);
        return entitled;
    }

    /// @notice Returns the caller's still-unfulfilled escrowed shares from an epoch.
    function cancelRedeem(uint256 epochId) external returns (uint256 sharesReturned) {
        RedeemEpoch storage e = epochs[epochId];
        uint256 requested = requestedShares[epochId][msg.sender];
        require(requested > 0, NothingToCancel());

        uint256 filledEquivalent =
            e.totalSharesRequested == 0 ? 0 : requested.mulDivDown(e.sharesFulfilled, e.totalSharesRequested);
        uint256 alreadyReturned = canceledShares[epochId][msg.sender];
        sharesReturned = requested - filledEquivalent - alreadyReturned;
        require(sharesReturned > 0, NothingToCancel());

        canceledShares[epochId][msg.sender] += sharesReturned;
        _transfer(address(this), msg.sender, sharesReturned);
        emit RedeemCanceled(msg.sender, epochId, sharesReturned);
    }
}
