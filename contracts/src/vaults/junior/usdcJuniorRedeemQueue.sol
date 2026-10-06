// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: jrUSDC's exit batches: curator stake check, oldest-first fills bounded by the coverage floor, and
// queued exit demand.
// @author adiii.eth

pragma solidity 0.8.34;

import {usdcJuniorDepositCancels} from "./usdcJuniorDepositCancels.sol";
import {wadMath} from "../../libraries/wadMath.sol";
import {epochMath} from "../../libraries/epochMath.sol";

/// @notice Batched junior exits, filled oldest first and limited by the coverage floor.
abstract contract usdcJuniorRedeemQueue is usdcJuniorDepositCancels {
    using wadMath for uint256;

    error CuratorBelowMinShare();

    event RedeemEpochClosed(uint256 indexed epochId, uint256 ppsCloseWad);

    struct RedeemEpoch {
        uint256 totalSharesRequested;
        uint256 remainingFillable;
        uint256 sharesFulfilled;
        uint256 assetsFulfilled;
        uint256 ppsCloseWad;
        bool closed;
    }

    uint256 public openRedeemEpochId = 1;
    uint256 public nextRedeemEpochToFill = 1;
    uint256 public queuedExitAssets;
    mapping(uint256 => RedeemEpoch) public redeemEpochs;
    mapping(uint256 => uint256) public redeemEpochOpenedAt;
    mapping(uint256 => uint256) public redeemEpochClosedAt;
    mapping(uint256 => uint256) internal _redeemEpochDemand;
    mapping(uint256 => mapping(address => uint256)) public requestedShares;
    mapping(uint256 => mapping(address => uint256)) public frozenRedeemShares;
    mapping(uint256 => mapping(address => uint256)) public frozenRedeemAssets;
    mapping(uint256 => mapping(address => uint256)) public claimedSharesOnRedeem;
    mapping(uint256 => mapping(address => uint256)) public claimedAssets;
    mapping(uint256 => mapping(address => uint256)) public pendingCancelShares;
    mapping(uint256 => mapping(address => uint256)) public claimedCancelShares;
    mapping(address controller => uint256 requestId) public activeRedeemRequestId;

    constructor() {
        redeemEpochOpenedAt[1] = block.timestamp;
    }

    /// @notice Requests an exit into the open batch.
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId) {
        require(shares > 0, ZeroShares());
        require(activeRedeemRequestId[controller] == 0, RequestAlreadyActive());
        require(msg.sender == controller || isOperator[controller][msg.sender], NotControllerOrOperator());
        if (msg.sender != owner && !isOperator[owner][msg.sender]) {
            _spendAllowance(owner, msg.sender, shares);
        }

        requestId = openRedeemEpochId;
        _transfer(owner, address(this), shares);

        if (owner == CORE.curator() || controller == CORE.curator()) {
            (,,,,,,,,,,,,,,,,,, uint256 curatorMinShareWad) = CORE.policy();
            require(balanceOf(CORE.curator()) * WAD >= curatorMinShareWad * totalSupply(), CuratorBelowMinShare());
        }

        requestedShares[requestId][controller] += shares;
        redeemEpochs[requestId].totalSharesRequested += shares;
        redeemEpochs[requestId].remainingFillable += shares;
        activeRedeemRequestId[controller] = requestId;
        emit RedeemRequest(controller, owner, requestId, msg.sender, shares);
    }

    /// @notice Shares still waiting to be filled.
    function pendingRedeemRequest(uint256 requestId, address controller) public view returns (uint256 shares) {
        return _redeemRemainingUnfulfilled(requestId, controller);
    }

    /// @notice Filled shares ready to claim.
    function claimableRedeemRequest(uint256 requestId, address controller) public view returns (uint256 shares) {
        return _redeemEntitledSharesTotal(requestId, controller) - claimedSharesOnRedeem[requestId][controller];
    }

    /// @notice Assets owed for filled shares not yet claimed.
    function owedRedeemAssets(uint256 requestId, address controller) public view returns (uint256) {
        return _redeemOwedAssetsTotal(requestId, controller);
    }

    /// @notice Shares a controller can redeem now.
    function maxRedeem(address controller) public view returns (uint256) {
        uint256 requestId = activeRedeemRequestId[controller];
        return requestId == 0 ? 0 : claimableRedeemRequest(requestId, controller);
    }

    /// @notice Assets a controller can withdraw now.
    function maxWithdraw(address controller) external view returns (uint256) {
        uint256 requestId = activeRedeemRequestId[controller];
        return requestId == 0 ? 0 : _redeemOwedAssetsTotal(requestId, controller);
    }

    /// @notice Unsupported for asynchronous exits; reverts.
    function previewRedeem(uint256) external pure returns (uint256) {
        revert AsyncPreviewUnsupported();
    }

    /// @notice Unsupported for asynchronous exits; reverts.
    function previewWithdraw(uint256) external pure returns (uint256) {
        revert AsyncPreviewUnsupported();
    }

    /// @notice Closes the open batch and records its price; the curator or allocator, or anyone after the window.
    function closeRedeemEpoch() external returns (uint256 epochId) {
        epochId = openRedeemEpochId;
        _requireOperatorOrAfter(redeemEpochOpenedAt[epochId] + MAX_EPOCH_DURATION);
        RedeemEpoch storage e = redeemEpochs[epochId];
        require(!e.closed, EpochAlreadyClosed());
        e.closed = true;
        e.ppsCloseWad = pricePerShareWad();
        redeemEpochClosedAt[epochId] = block.timestamp;
        openRedeemEpochId = epochId + 1;
        redeemEpochOpenedAt[epochId + 1] = block.timestamp;
        _syncRedeemDemand(epochId);
        emit RedeemEpochClosed(epochId, e.ppsCloseWad);
    }

    /// @notice Fills the oldest closed batch within the coverage floor; the curator or allocator, or anyone after the grace period.
    function fulfillRedeem(uint256 epochId, uint256 assetsToUse) external {
        RedeemEpoch storage e = redeemEpochs[epochId];
        require(e.closed, EpochNotClosed());
        _requireOperatorOrAfter(redeemEpochClosedAt[epochId] + FILL_GRACE);
        uint256 oldest = _advanceRedeemFillPointer();
        if (epochId < oldest) return;
        require(epochId == oldest, NotOldestBatch(oldest));

        uint256 available = CORE.juniorRedeemable();
        uint256 cappedAssets = assetsToUse < available ? assetsToUse : available;

        uint256 priceWad = epochMath.redemptionPriceWad(e.ppsCloseWad, pricePerShareWad());
        uint256 sharesNow = epochMath.sharesFillable(e.remainingFillable, cappedAssets, priceWad);
        if (sharesNow == 0) return;
        uint256 assetsNow = epochMath.assetsForShares(sharesNow, priceWad);

        e.remainingFillable -= sharesNow;
        e.sharesFulfilled += sharesNow;
        e.assetsFulfilled += assetsNow;
        _syncRedeemDemand(epochId);
        _advanceRedeemFillPointer();

        CORE.reserveFor(false, assetsNow);
        _burn(address(this), sharesNow);
        emit RedeemFulfilled(epochId, sharesNow, assetsNow, priceWad);
    }

    function _advanceRedeemFillPointer() internal returns (uint256 pointer) {
        pointer = nextRedeemEpochToFill;
        while (pointer < openRedeemEpochId && redeemEpochs[pointer].remainingFillable == 0) {
            pointer++;
        }
        nextRedeemEpochToFill = pointer;
    }

    function _syncRedeemDemand(uint256 epochId) internal {
        RedeemEpoch storage e = redeemEpochs[epochId];
        uint256 demand = e.closed ? e.remainingFillable.mulDivUp(e.ppsCloseWad, WAD) : 0;
        queuedExitAssets = queuedExitAssets - _redeemEpochDemand[epochId] + demand;
        _redeemEpochDemand[epochId] = demand;
    }

    function _detachRedeem(uint256 requestId, address controller) internal returns (uint256 unfilled) {
        RedeemEpoch storage e = redeemEpochs[requestId];
        uint256 requested = requestedShares[requestId][controller];
        uint256 liveShares = requested.mulDivDown(e.sharesFulfilled, e.totalSharesRequested);
        uint256 liveAssets = requested.mulDivDown(e.assetsFulfilled, e.totalSharesRequested);
        unfilled = requested - liveShares;

        frozenRedeemShares[requestId][controller] += liveShares;
        frozenRedeemAssets[requestId][controller] += liveAssets;
        requestedShares[requestId][controller] = 0;

        e.totalSharesRequested -= requested;
        e.sharesFulfilled -= liveShares;
        e.assetsFulfilled -= liveAssets;
        e.remainingFillable -= unfilled;
    }

    function _liveRedeemShares(uint256 requestId, address controller) internal view returns (uint256) {
        RedeemEpoch storage e = redeemEpochs[requestId];
        if (e.totalSharesRequested == 0) return 0;
        return requestedShares[requestId][controller].mulDivDown(e.sharesFulfilled, e.totalSharesRequested);
    }

    function _redeemEntitledSharesTotal(uint256 requestId, address controller) internal view returns (uint256) {
        return frozenRedeemShares[requestId][controller] + _liveRedeemShares(requestId, controller);
    }

    function _redeemOwedAssetsTotal(uint256 requestId, address controller) internal view returns (uint256) {
        RedeemEpoch storage e = redeemEpochs[requestId];
        uint256 live = e.totalSharesRequested == 0
            ? 0
            : requestedShares[requestId][controller].mulDivDown(e.assetsFulfilled, e.totalSharesRequested);
        uint256 entitled = frozenRedeemAssets[requestId][controller] + live;
        uint256 claimed = claimedAssets[requestId][controller];
        return entitled > claimed ? entitled - claimed : 0;
    }

    function _redeemRemainingUnfulfilled(uint256 requestId, address controller) internal view returns (uint256) {
        return requestedShares[requestId][controller] - _liveRedeemShares(requestId, controller);
    }

    function _clearRedeemIfFullyResolved(uint256 requestId, address controller) internal {
        if (
            _redeemRemainingUnfulfilled(requestId, controller) == 0
                && claimableRedeemRequest(requestId, controller) == 0 && pendingCancelShares[requestId][controller] == 0
        ) {
            activeRedeemRequestId[controller] = 0;
        }
    }
}
