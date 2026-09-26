// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: jrUSDC's exit batches: curator stake check, batch close and fills bounded by the coverage floor.
// @author adiii.eth

pragma solidity 0.8.34;

import {usdcJuniorDepositCancels} from "./usdcJuniorDepositCancels.sol";
import {wadMath} from "../../libraries/wadMath.sol";
import {epochMath} from "../../libraries/epochMath.sol";

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
    mapping(uint256 => RedeemEpoch) public redeemEpochs;
    mapping(uint256 => mapping(address => uint256)) public requestedShares;
    mapping(uint256 => mapping(address => uint256)) public claimedSharesOnRedeem;
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

    function pendingRedeemRequest(uint256 requestId, address controller) public view returns (uint256 shares) {
        return _redeemRemainingUnfulfilled(requestId, controller);
    }

    function claimableRedeemRequest(uint256 requestId, address controller) public view returns (uint256 shares) {
        return _redeemEntitledSharesTotal(requestId, controller) - claimedSharesOnRedeem[requestId][controller];
    }

    function maxRedeem(address controller) public view returns (uint256) {
        uint256 requestId = activeRedeemRequestId[controller];
        return requestId == 0 ? 0 : claimableRedeemRequest(requestId, controller);
    }

    function maxWithdraw(address controller) external view returns (uint256) {
        uint256 requestId = activeRedeemRequestId[controller];
        return requestId == 0 ? 0 : _redeemOwedAssetsTotal(requestId, controller);
    }

    function previewRedeem(uint256) external pure returns (uint256) {
        revert AsyncPreviewUnsupported();
    }

    function previewWithdraw(uint256) external pure returns (uint256) {
        revert AsyncPreviewUnsupported();
    }

    function closeRedeemEpoch() external onlyOperator returns (uint256 epochId) {
        epochId = openRedeemEpochId;
        RedeemEpoch storage e = redeemEpochs[epochId];
        require(!e.closed, EpochAlreadyClosed());
        e.closed = true;
        e.ppsCloseWad = pricePerShareWad();
        openRedeemEpochId = epochId + 1;
        emit RedeemEpochClosed(epochId, e.ppsCloseWad);
    }

    function fulfillRedeem(uint256 epochId, uint256 assetsToUse) external onlyOperator {
        RedeemEpoch storage e = redeemEpochs[epochId];
        require(e.closed, EpochNotClosed());

        uint256 available = CORE.juniorRedeemable();
        uint256 cappedAssets = assetsToUse < available ? assetsToUse : available;

        uint256 priceWad = epochMath.redemptionPriceWad(e.ppsCloseWad, pricePerShareWad());
        uint256 sharesNow = epochMath.sharesFillable(e.remainingFillable, cappedAssets, priceWad);
        if (sharesNow == 0) return;
        uint256 assetsNow = epochMath.assetsForShares(sharesNow, priceWad);

        CORE.reserveFor(false, assetsNow);
        _burn(address(this), sharesNow);

        e.remainingFillable -= sharesNow;
        e.sharesFulfilled += sharesNow;
        e.assetsFulfilled += assetsNow;
        emit RedeemFulfilled(epochId, sharesNow, assetsNow, priceWad);
    }

    function _redeemEntitledSharesTotal(uint256 requestId, address controller) internal view returns (uint256) {
        RedeemEpoch storage e = redeemEpochs[requestId];
        if (e.totalSharesRequested == 0) return 0;
        return requestedShares[requestId][controller].mulDivDown(e.sharesFulfilled, e.totalSharesRequested);
    }

    function _redeemOwedAssetsTotal(uint256 requestId, address controller) internal view returns (uint256) {
        RedeemEpoch storage e = redeemEpochs[requestId];
        return epochMath.claimableAssets(
            requestedShares[requestId][controller],
            e.assetsFulfilled,
            e.totalSharesRequested,
            claimedAssets[requestId][controller]
        );
    }

    function _redeemRemainingUnfulfilled(uint256 requestId, address controller) internal view returns (uint256) {
        uint256 requested = requestedShares[requestId][controller];
        uint256 entitled = _redeemEntitledSharesTotal(requestId, controller);
        uint256 canceled = pendingCancelShares[requestId][controller] + claimedCancelShares[requestId][controller];
        return requested - entitled - canceled;
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
