// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SeriesCore} from "../core/SeriesCore.sol";
import {WadMath} from "../libraries/WadMath.sol";
import {EpochMath} from "../libraries/EpochMath.sol";

interface IERC20Like {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// Morrow Finance — junior tranche share token: epoch-based async deposits and redemptions.
// @author adiii.eth

/// @notice jrUSDC: the junior tranche's first-loss deposit token. Both deposits and redemptions queue into
/// epochs and settle at a price protected against the queue's wait: deposits can never buy in below the
/// epoch-close price, redemptions can never escape a loss realized while waiting.
contract JuniorVault is ERC20 {
    using WadMath for uint256;

    error ZeroAssets();
    error ZeroShares();
    error DepositsPaused();
    error NotOperator();
    error EpochAlreadyClosed();
    error EpochNotClosed();
    error NothingToClaim();
    error NothingToCancel();

    event DepositRequested(address indexed owner, uint256 indexed epochId, uint256 assets);
    event DepositEpochClosed(uint256 indexed epochId, uint256 ppsCloseWad);
    event DepositFulfilled(uint256 indexed epochId, uint256 assetsFulfilled, uint256 sharesFulfilled, uint256 priceWad);
    event DepositClaimed(address indexed owner, uint256 indexed epochId, uint256 shares);
    event DepositCanceled(address indexed owner, uint256 indexed epochId, uint256 assets);

    event RedeemRequested(address indexed owner, uint256 indexed epochId, uint256 shares);
    event RedeemEpochClosed(uint256 indexed epochId, uint256 ppsCloseWad);
    event RedeemFulfilled(uint256 indexed epochId, uint256 sharesFulfilled, uint256 assetsFulfilled, uint256 priceWad);
    event RedeemClaimed(address indexed owner, uint256 indexed epochId, uint256 assets);
    event RedeemCanceled(address indexed owner, uint256 indexed epochId, uint256 shares);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant INITIAL_PRICE_WAD = 1e6; // 1.0 USDC per whole share, before any supply exists

    SeriesCore public immutable CORE;
    address public immutable USDC;

    /// @dev Requests always target `openDepositEpochId`; closing it snapshots a price floor for the round
    /// (depositPriceWad's max rule) and opens a fresh one.
    struct DepositEpoch {
        uint256 totalAssetsRequested;
        uint256 assetsFulfilled; // cumulative, monotonic
        uint256 sharesFulfilled; // cumulative, monotonic
        uint256 ppsCloseWad;
        bool closed;
    }

    /// @dev Same shape as the deposit queue, mirrored for redemptions (priced by redemptionPriceWad's min rule).
    struct RedeemEpoch {
        uint256 totalSharesRequested;
        uint256 sharesFulfilled;
        uint256 assetsFulfilled;
        uint256 ppsCloseWad;
        bool closed;
    }

    uint256 public openDepositEpochId;
    mapping(uint256 => DepositEpoch) public depositEpochs;
    mapping(uint256 => mapping(address => uint256)) public requestedAssets;
    mapping(uint256 => mapping(address => uint256)) public claimedShares;
    mapping(uint256 => mapping(address => uint256)) public canceledAssets;

    uint256 public openRedeemEpochId;
    mapping(uint256 => RedeemEpoch) public redeemEpochs;
    mapping(uint256 => mapping(address => uint256)) public requestedShares;
    mapping(uint256 => mapping(address => uint256)) public claimedAssets;
    mapping(uint256 => mapping(address => uint256)) public canceledShares;

    modifier onlyOperator() {
        require(msg.sender == CORE.curator() || msg.sender == CORE.allocator(), NotOperator());
        _;
    }

    constructor(SeriesCore core_, address usdc_) ERC20("Morrow Junior USDC", "jrUSDC") {
        CORE = core_;
        USDC = usdc_;
        openDepositEpochId = 1;
        openRedeemEpochId = 1;
    }

    /// @notice Assets per whole (1e18) share, live.
    function pricePerShareWad() public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? INITIAL_PRICE_WAD : CORE.juniorAssets().mulDivDown(WAD, supply);
    }

    // --- deposit (async, epoch-based) ---------------------------------------------------------------------

    /// @notice Queues `assets` into the currently open deposit epoch. Cash moves straight to the core as a
    /// pending balance; nothing is invested (or priced) until the epoch is closed and fulfilled.
    function requestDeposit(uint256 assets) external returns (uint256 epochId) {
        require(assets > 0, ZeroAssets());
        require(!CORE.paused(), DepositsPaused());
        epochId = openDepositEpochId;
        require(IERC20Like(USDC).transferFrom(msg.sender, address(CORE), assets), "transfer failed");
        CORE.addPendingJunior(assets);
        requestedAssets[epochId][msg.sender] += assets;
        depositEpochs[epochId].totalAssetsRequested += assets;
        emit DepositRequested(msg.sender, epochId, assets);
    }

    /// @notice Stops the open deposit epoch from accepting new requests, snapshots its price floor, and opens
    /// the next one. Operator-only.
    function closeDepositEpoch() external onlyOperator returns (uint256 epochId) {
        epochId = openDepositEpochId;
        DepositEpoch storage e = depositEpochs[epochId];
        require(!e.closed, EpochAlreadyClosed());
        e.closed = true;
        e.ppsCloseWad = pricePerShareWad();
        openDepositEpochId = epochId + 1;
        emit DepositEpochClosed(epochId, e.ppsCloseWad);
    }

    /// @notice Invests up to `assetsToInvest` of a closed deposit epoch's outstanding requests into the junior
    /// book, minting the matching shares into escrow for claiming. Operator-only; callable repeatedly against
    /// the same epoch until it's fully filled.
    function fulfillDeposit(uint256 epochId, uint256 assetsToInvest) external onlyOperator {
        DepositEpoch storage e = depositEpochs[epochId];
        require(e.closed, EpochNotClosed());

        uint256 remaining = e.totalAssetsRequested - e.assetsFulfilled;
        uint256 assetsNow = assetsToInvest < remaining ? assetsToInvest : remaining;
        if (assetsNow == 0) return;

        uint256 priceWad = EpochMath.depositPriceWad(e.ppsCloseWad, pricePerShareWad());
        uint256 sharesNow = EpochMath.sharesForAssets(assetsNow, priceWad);

        CORE.investPendingJunior(assetsNow);
        _mint(address(this), sharesNow);

        e.assetsFulfilled += assetsNow;
        e.sharesFulfilled += sharesNow;
        emit DepositFulfilled(epochId, assetsNow, sharesNow, priceWad);
    }

    /// @notice Claims the caller's pro-rata share of a deposit epoch's fulfillment so far. Safe to call again
    /// after later fulfillment rounds on the same epoch; only the newly-entitled delta is paid each time.
    function claimDeposit(uint256 epochId) external returns (uint256 shares) {
        DepositEpoch storage e = depositEpochs[epochId];
        uint256 requested = requestedAssets[epochId][msg.sender];
        uint256 entitled = EpochMath.claimableShares(
            requested, e.sharesFulfilled, e.totalAssetsRequested, claimedShares[epochId][msg.sender]
        );
        require(entitled > 0, NothingToClaim());

        claimedShares[epochId][msg.sender] += entitled;
        _transfer(address(this), msg.sender, entitled);
        emit DepositClaimed(msg.sender, epochId, entitled);
        return entitled;
    }

    /// @notice Refunds the caller's still-uninvested portion of a deposit epoch's requested cash, paid
    /// directly from the core's pending balance.
    function cancelDeposit(uint256 epochId) external returns (uint256 assetsReturned) {
        DepositEpoch storage e = depositEpochs[epochId];
        uint256 requested = requestedAssets[epochId][msg.sender];
        require(requested > 0, NothingToCancel());

        uint256 filledEquivalent =
            e.totalAssetsRequested == 0 ? 0 : requested.mulDivDown(e.assetsFulfilled, e.totalAssetsRequested);
        uint256 alreadyReturned = canceledAssets[epochId][msg.sender];
        assetsReturned = requested - filledEquivalent - alreadyReturned;
        require(assetsReturned > 0, NothingToCancel());

        canceledAssets[epochId][msg.sender] += assetsReturned;
        CORE.removePendingJunior(assetsReturned, msg.sender);
        emit DepositCanceled(msg.sender, epochId, assetsReturned);
    }

    // --- redeem (async, epoch-based) ----------------------------------------------------------------------

    /// @notice Escrows `shares` and queues a redemption request against the currently open redeem epoch.
    function requestRedeem(uint256 shares) external returns (uint256 epochId) {
        require(shares > 0, ZeroShares());
        epochId = openRedeemEpochId;
        _transfer(msg.sender, address(this), shares);
        requestedShares[epochId][msg.sender] += shares;
        redeemEpochs[epochId].totalSharesRequested += shares;
        emit RedeemRequested(msg.sender, epochId, shares);
    }

    /// @notice Stops the open redeem epoch from accepting new requests, snapshots its price ceiling, and opens
    /// the next one. Operator-only.
    function closeRedeemEpoch() external onlyOperator returns (uint256 epochId) {
        epochId = openRedeemEpochId;
        RedeemEpoch storage e = redeemEpochs[epochId];
        require(!e.closed, EpochAlreadyClosed());
        e.closed = true;
        e.ppsCloseWad = pricePerShareWad();
        openRedeemEpochId = epochId + 1;
        emit RedeemEpochClosed(epochId, e.ppsCloseWad);
    }

    /// @notice Fulfills up to `assetsToUse` of a closed redeem epoch's outstanding requests, bounded by what
    /// the core will release without breaching the curator's coverage floor. Burns the fulfilled shares and
    /// reserves the matching assets for claiming. Operator-only; callable repeatedly until fully filled.
    function fulfillRedeem(uint256 epochId, uint256 assetsToUse) external onlyOperator {
        RedeemEpoch storage e = redeemEpochs[epochId];
        require(e.closed, EpochNotClosed());

        uint256 available = CORE.juniorRedeemable();
        uint256 cappedAssets = assetsToUse < available ? assetsToUse : available;

        uint256 priceWad = EpochMath.redemptionPriceWad(e.ppsCloseWad, pricePerShareWad());
        uint256 remainingShares = e.totalSharesRequested - e.sharesFulfilled;
        uint256 sharesNow = EpochMath.sharesFillable(remainingShares, cappedAssets, priceWad);
        if (sharesNow == 0) return;
        uint256 assetsNow = EpochMath.assetsForShares(sharesNow, priceWad);

        CORE.reserveFor(false, assetsNow);
        _burn(address(this), sharesNow);

        e.sharesFulfilled += sharesNow;
        e.assetsFulfilled += assetsNow;
        emit RedeemFulfilled(epochId, sharesNow, assetsNow, priceWad);
    }

    /// @notice Claims the caller's pro-rata share of a redeem epoch's fulfillment so far. Safe to call again
    /// after later fulfillment rounds on the same epoch; only the newly-entitled delta is paid each time.
    function claimRedeem(uint256 epochId) external returns (uint256 assets) {
        RedeemEpoch storage e = redeemEpochs[epochId];
        uint256 requested = requestedShares[epochId][msg.sender];
        uint256 entitled = EpochMath.claimableAssets(
            requested, e.assetsFulfilled, e.totalSharesRequested, claimedAssets[epochId][msg.sender]
        );
        require(entitled > 0, NothingToClaim());

        claimedAssets[epochId][msg.sender] += entitled;
        CORE.payFrom(false, msg.sender, entitled);
        emit RedeemClaimed(msg.sender, epochId, entitled);
        return entitled;
    }

    /// @notice Returns the caller's still-unfulfilled escrowed shares from a redeem epoch.
    function cancelRedeem(uint256 epochId) external returns (uint256 sharesReturned) {
        RedeemEpoch storage e = redeemEpochs[epochId];
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
