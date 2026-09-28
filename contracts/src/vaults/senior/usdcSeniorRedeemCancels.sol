// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: srUSDC's ERC-7887 two-step exit cancel: while the batch is open, or once a closed batch has
// sat unfilled past the cancel timeout.
// @author adiii.eth

pragma solidity 0.8.34;

import {usdcSeniorRedeemClaims} from "./usdcSeniorRedeemClaims.sol";

abstract contract usdcSeniorRedeemCancels is usdcSeniorRedeemClaims {
    function cancelRedeemRequest(uint256 requestId, address controller) external onlyControllerOrOperator(controller) {
        bool closed = epochs[requestId].closed;
        require(!closed || block.timestamp >= epochClosedAt[requestId] + CANCEL_AFTER_CLOSE, EpochAlreadyClosed());
        require(pendingCancelShares[requestId][controller] == 0, PendingCancelation());
        require(_remainingUnfulfilled(requestId, controller) > 0, NothingToCancel());

        uint256 unfilled = _detach(requestId, controller);
        pendingCancelShares[requestId][controller] = unfilled;
        if (closed) _syncDemand(requestId);
        emit CancelRedeemRequest(controller, requestId, msg.sender);
    }

    function pendingCancelRedeemRequest(uint256 requestId, address controller) external view returns (bool isPending) {
        return pendingCancelShares[requestId][controller] > 0;
    }

    function claimableCancelRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 shares)
    {
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
        _clearIfFullyResolved(requestId, controller);

        _transfer(address(this), receiver, shares);
        emit CancelRedeemClaimed(controller, receiver, requestId, shares);
    }
}
