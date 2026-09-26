// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: srUSDC's ERC-7887 two-step exit cancel, allowed only while the request's batch is open.
// @author adiii.eth

pragma solidity 0.8.34;

import {usdcSeniorRedeemClaims} from "./usdcSeniorRedeemClaims.sol";

abstract contract usdcSeniorRedeemCancels is usdcSeniorRedeemClaims {
    function cancelRedeemRequest(uint256 requestId, address controller) external onlyControllerOrOperator(controller) {
        require(!epochs[requestId].closed, EpochAlreadyClosed());
        require(pendingCancelShares[requestId][controller] == 0, PendingCancelation());

        uint256 remaining = _remainingUnfulfilled(requestId, controller);
        require(remaining > 0, NothingToCancel());

        pendingCancelShares[requestId][controller] = remaining;
        epochs[requestId].remainingFillable -= remaining;
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
