// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: srUSDC's exit batches: requests, batch close and liquidity-bounded fills at the lower price.
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
    mapping(uint256 => RedeemEpoch) public epochs;
    mapping(uint256 => mapping(address => uint256)) public requestedShares;
    mapping(uint256 => mapping(address => uint256)) public claimedShares;
    mapping(uint256 => mapping(address => uint256)) public claimedAssets;
    mapping(uint256 => mapping(address => uint256)) public pendingCancelShares;
    mapping(uint256 => mapping(address => uint256)) public claimedCancelShares;
    mapping(address controller => uint256 requestId) public activeRedeemRequestId;

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId) {
        require(shares > 0, ZeroShares());
        require(activeRedeemRequestId[controller] == 0, RequestAlreadyActive());
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

    function closeEpoch() external onlyOperator returns (uint256 epochId) {
        epochId = openEpochId;
        RedeemEpoch storage e = epochs[epochId];
        require(!e.closed, EpochAlreadyClosed());
        e.closed = true;
        e.ppsCloseWad = pricePerShareWad();
        openEpochId = epochId + 1;
        emit EpochClosed(epochId, e.ppsCloseWad);
    }

    function fulfill(uint256 epochId, uint256 assetsToUse) external onlyOperator {
        RedeemEpoch storage e = epochs[epochId];
        require(e.closed, EpochNotClosed());

        uint256 available = CORE.idleAvailable(true);
        uint256 liquid = CORE.parkingLiquidity();
        if (liquid < available) available = liquid;
        uint256 cappedAssets = assetsToUse < available ? assetsToUse : available;

        uint256 priceWad = epochMath.redemptionPriceWad(e.ppsCloseWad, pricePerShareWad());
        uint256 sharesNow = epochMath.sharesFillable(e.remainingFillable, cappedAssets, priceWad);
        if (sharesNow == 0) return;
        uint256 assetsNow = epochMath.assetsForShares(sharesNow, priceWad);

        CORE.reserveFor(true, assetsNow);
        _burn(address(this), sharesNow);

        e.remainingFillable -= sharesNow;
        e.sharesFulfilled += sharesNow;
        e.assetsFulfilled += assetsNow;
        emit RedeemFulfilled(epochId, sharesNow, assetsNow, priceWad);
    }

    function _entitledSharesTotal(uint256 requestId, address controller) internal view returns (uint256) {
        RedeemEpoch storage e = epochs[requestId];
        if (e.totalSharesRequested == 0) return 0;
        return requestedShares[requestId][controller].mulDivDown(e.sharesFulfilled, e.totalSharesRequested);
    }

    function _owedAssetsTotal(uint256 requestId, address controller) internal view returns (uint256) {
        RedeemEpoch storage e = epochs[requestId];
        return epochMath.claimableAssets(
            requestedShares[requestId][controller],
            e.assetsFulfilled,
            e.totalSharesRequested,
            claimedAssets[requestId][controller]
        );
    }

    function _remainingUnfulfilled(uint256 requestId, address controller) internal view returns (uint256) {
        uint256 requested = requestedShares[requestId][controller];
        uint256 entitled = _entitledSharesTotal(requestId, controller);
        uint256 canceled = pendingCancelShares[requestId][controller] + claimedCancelShares[requestId][controller];
        return requested - entitled - canceled;
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
