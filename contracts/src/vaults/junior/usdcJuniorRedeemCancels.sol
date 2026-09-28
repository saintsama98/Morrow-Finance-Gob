// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: jrUSDC's ERC-7887 two-step exit cancel: while the batch is open, or once a closed batch has sat
// unfilled past the cancel timeout.
// @author adiii.eth

pragma solidity 0.8.34;

import {usdcJuniorRedeemClaims} from "./usdcJuniorRedeemClaims.sol";

abstract contract usdcJuniorRedeemCancels is usdcJuniorRedeemClaims {
    function cancelRedeemRequest(uint256 requestId, address controller) external onlyControllerOrOperator(controller) {
        bool closed = redeemEpochs[requestId].closed;
        require(!closed || block.timestamp >= redeemEpochClosedAt[requestId] + CANCEL_AFTER_CLOSE, EpochAlreadyClosed());
        require(pendingCancelShares[requestId][controller] == 0, PendingCancelation());
        require(_redeemRemainingUnfulfilled(requestId, controller) > 0, NothingToCancel());

        pendingCancelShares[requestId][controller] = _detachRedeem(requestId, controller);
        if (closed) _syncRedeemDemand(requestId);
        emit CancelRedeemRequest(controller, requestId, msg.sender);
    }

    function pendingCancelRedeemRequest(uint256 requestId, address controller) external view returns (bool) {
        return pendingCancelShares[requestId][controller] > 0;
    }

    function claimableCancelRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        return pendingCancelShares[requestId][controller];
    }

    function claimCancelRedeemRequest(uint256 requestId, address receiver, address controller)
        external
        onlyControllerOrOperator(controller)
    {
        uint256 shares = pendingCancelShares[requestId][controller];
        require(shares > 0, NothingToCancel());

        pendingCancelShares[requestId][controller] = 0;
        claimedCancelShares[requestId][controller] += shares;
        _clearRedeemIfFullyResolved(requestId, controller);

        _transfer(address(this), receiver, shares);
        emit CancelRedeemClaimed(controller, receiver, requestId, shares);
    }
}
