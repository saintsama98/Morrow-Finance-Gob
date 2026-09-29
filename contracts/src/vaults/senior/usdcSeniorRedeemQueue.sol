// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: srUSDC's exit batches: requests, oldest-first fills at the lower price, and queued exit demand.
// @author adiii.eth

pragma solidity 0.8.34;

import {usdcSeniorDeposits} from "./usdcSeniorDeposits.sol";
import {wadMath} from "../../libraries/wadMath.sol";
import {epochMath} from "../../libraries/epochMath.sol";

abstract contract usdcSeniorRedeemQueue is usdcSeniorDeposits {
    using wadMath for uint256;

    event EpochClosed(uint256 indexed epochId, uint256 ppsCloseWad);

    struct RedeemEpoch {
        uint256 totalSharesRequested;
        uint256 remainingFillable;
        uint256 sharesFulfilled;
        uint256 assetsFulfilled;
        uint256 ppsCloseWad;
        bool closed;
    }

    uint256 public openEpochId = 1;
    uint256 public nextEpochToFill = 1;
    uint256 public queuedExitAssets;
    mapping(uint256 => RedeemEpoch) public epochs;
    mapping(uint256 => uint256) public epochOpenedAt;
    mapping(uint256 => uint256) public epochClosedAt;
    mapping(uint256 => uint256) internal _epochDemand;
    mapping(uint256 => mapping(address => uint256)) public requestedShares;
    mapping(uint256 => mapping(address => uint256)) public frozenShares;
    mapping(uint256 => mapping(address => uint256)) public frozenAssets;
    mapping(uint256 => mapping(address => uint256)) public claimedShares;
    mapping(uint256 => mapping(address => uint256)) public claimedAssets;
    mapping(uint256 => mapping(address => uint256)) public pendingCancelShares;
    mapping(uint256 => mapping(address => uint256)) public claimedCancelShares;
    mapping(address controller => uint256 requestId) public activeRedeemRequestId;

    constructor() {
        epochOpenedAt[1] = block.timestamp;
    }

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId) {
        require(shares > 0, ZeroShares());
        require(activeRedeemRequestId[controller] == 0, RequestAlreadyActive());
        require(msg.sender == controller || isOperator[controller][msg.sender], NotControllerOrOperator());
        if (msg.sender != owner && !isOperator[owner][msg.sender]) {
            _spendAllowance(owner, msg.sender, shares);
        }

        requestId = openEpochId;
        _transfer(owner, address(this), shares);
        requestedShares[requestId][controller] += shares;
        epochs[requestId].totalSharesRequested += shares;
        epochs[requestId].remainingFillable += shares;
        activeRedeemRequestId[controller] = requestId;
        emit RedeemRequest(controller, owner, requestId, msg.sender, shares);
    }

    function pendingRedeemRequest(uint256 requestId, address controller) public view returns (uint256 shares) {
        return _remainingUnfulfilled(requestId, controller);
    }

    function claimableRedeemRequest(uint256 requestId, address controller) public view returns (uint256 shares) {
        return _entitledSharesTotal(requestId, controller) - claimedShares[requestId][controller];
    }

    function owedRedeemAssets(uint256 requestId, address controller) public view returns (uint256) {
        return _owedAssetsTotal(requestId, controller);
    }

    function maxRedeem(address controller) public view returns (uint256) {
        uint256 requestId = activeRedeemRequestId[controller];
        return requestId == 0 ? 0 : claimableRedeemRequest(requestId, controller);
    }

    function maxWithdraw(address controller) external view returns (uint256) {
        uint256 requestId = activeRedeemRequestId[controller];
        return requestId == 0 ? 0 : _owedAssetsTotal(requestId, controller);
    }

    function previewRedeem(uint256) external pure returns (uint256) {
        revert AsyncPreviewUnsupported();
    }

    function previewWithdraw(uint256) external pure returns (uint256) {
        revert AsyncPreviewUnsupported();
    }

    function closeEpoch() external returns (uint256 epochId) {
        epochId = openEpochId;
        _requireOperatorOrAfter(epochOpenedAt[epochId] + MAX_EPOCH_DURATION);
        RedeemEpoch storage e = epochs[epochId];
        require(!e.closed, EpochAlreadyClosed());
        e.closed = true;
        e.ppsCloseWad = pricePerShareWad();
        epochClosedAt[epochId] = block.timestamp;
        openEpochId = epochId + 1;
        epochOpenedAt[epochId + 1] = block.timestamp;
        _syncDemand(epochId);
        emit EpochClosed(epochId, e.ppsCloseWad);
    }

    function fulfill(uint256 epochId, uint256 assetsToUse) external {
        RedeemEpoch storage e = epochs[epochId];
        require(e.closed, EpochNotClosed());
        _requireOperatorOrAfter(epochClosedAt[epochId] + FILL_GRACE);
        uint256 oldest = _advanceFillPointer();
        if (epochId < oldest) return;
        require(epochId == oldest, NotOldestBatch(oldest));

        uint256 available = CORE.idleAvailable(true);
        uint256 liquid = CORE.parkingLiquidity();
        if (liquid < available) available = liquid;
        uint256 cappedAssets = assetsToUse < available ? assetsToUse : available;

        uint256 priceWad = epochMath.redemptionPriceWad(e.ppsCloseWad, pricePerShareWad());
        uint256 sharesNow = epochMath.sharesFillable(e.remainingFillable, cappedAssets, priceWad);
        if (sharesNow == 0) return;
        uint256 assetsNow = epochMath.assetsForShares(sharesNow, priceWad);

        e.remainingFillable -= sharesNow;
        e.sharesFulfilled += sharesNow;
        e.assetsFulfilled += assetsNow;
        _syncDemand(epochId);
        _advanceFillPointer();

        CORE.reserveFor(true, assetsNow);
        _burn(address(this), sharesNow);
        emit RedeemFulfilled(epochId, sharesNow, assetsNow, priceWad);
    }

    function _advanceFillPointer() internal returns (uint256 pointer) {
        pointer = nextEpochToFill;
        while (pointer < openEpochId && epochs[pointer].remainingFillable == 0) {
            pointer++;
        }
        nextEpochToFill = pointer;
    }

    function _syncDemand(uint256 epochId) internal {
        RedeemEpoch storage e = epochs[epochId];
        uint256 demand = e.closed ? e.remainingFillable.mulDivUp(e.ppsCloseWad, WAD) : 0;
        queuedExitAssets = queuedExitAssets - _epochDemand[epochId] + demand;
        _epochDemand[epochId] = demand;
    }

    function _detach(uint256 requestId, address controller) internal returns (uint256 unfilled) {
        RedeemEpoch storage e = epochs[requestId];
        uint256 requested = requestedShares[requestId][controller];
        uint256 liveShares = requested.mulDivDown(e.sharesFulfilled, e.totalSharesRequested);
        uint256 liveAssets = requested.mulDivDown(e.assetsFulfilled, e.totalSharesRequested);
        unfilled = requested - liveShares;

        frozenShares[requestId][controller] += liveShares;
        frozenAssets[requestId][controller] += liveAssets;
        requestedShares[requestId][controller] = 0;

        e.totalSharesRequested -= requested;
        e.sharesFulfilled -= liveShares;
        e.assetsFulfilled -= liveAssets;
        e.remainingFillable -= unfilled;
    }

    function _liveEntitledShares(uint256 requestId, address controller) internal view returns (uint256) {
        RedeemEpoch storage e = epochs[requestId];
        if (e.totalSharesRequested == 0) return 0;
        return requestedShares[requestId][controller].mulDivDown(e.sharesFulfilled, e.totalSharesRequested);
    }

    function _entitledSharesTotal(uint256 requestId, address controller) internal view returns (uint256) {
        return frozenShares[requestId][controller] + _liveEntitledShares(requestId, controller);
    }

    function _owedAssetsTotal(uint256 requestId, address controller) internal view returns (uint256) {
        RedeemEpoch storage e = epochs[requestId];
        uint256 live = e.totalSharesRequested == 0
            ? 0
            : requestedShares[requestId][controller].mulDivDown(e.assetsFulfilled, e.totalSharesRequested);
        uint256 entitled = frozenAssets[requestId][controller] + live;
        uint256 claimed = claimedAssets[requestId][controller];
        return entitled > claimed ? entitled - claimed : 0;
    }

    function _remainingUnfulfilled(uint256 requestId, address controller) internal view returns (uint256) {
        return requestedShares[requestId][controller] - _liveEntitledShares(requestId, controller);
    }

    function _clearIfFullyResolved(uint256 requestId, address controller) internal {
        if (
            _remainingUnfulfilled(requestId, controller) == 0 && claimableRedeemRequest(requestId, controller) == 0
                && pendingCancelShares[requestId][controller] == 0
        ) {
            activeRedeemRequestId[controller] = 0;
        }
    }
}
