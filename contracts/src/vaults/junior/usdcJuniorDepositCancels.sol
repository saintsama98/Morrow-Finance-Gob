// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: jrUSDC's ERC-7887 two-step entry cancel: while the batch is open, or once a closed batch has sat
// unfilled past the cancel timeout; queued USDC is refunded untouched by the core.
// @author adiii.eth

pragma solidity 0.8.34;

import {usdcJuniorDepositClaims} from "./usdcJuniorDepositClaims.sol";

/// @notice Cancelling junior deposit requests.
abstract contract usdcJuniorDepositCancels is usdcJuniorDepositClaims {
    event CancelDepositRequest(address indexed controller, uint256 indexed requestId, address sender);
    event CancelDepositClaimed(
        address indexed controller, address indexed receiver, uint256 indexed requestId, uint256 assets
    );

    /// @notice Cancels the unfilled part of a deposit request.
    function cancelDepositRequest(uint256 requestId, address controller) external onlyControllerOrOperator(controller) {
        require(
            !depositEpochs[requestId].closed || block.timestamp >= depositEpochClosedAt[requestId] + CANCEL_AFTER_CLOSE,
            EpochAlreadyClosed()
        );
        require(pendingCancelAssets[requestId][controller] == 0, PendingCancelation());
        require(_depositRemainingUnfulfilled(requestId, controller) > 0, NothingToCancel());

        pendingCancelAssets[requestId][controller] = _detachDeposit(requestId, controller);
        emit CancelDepositRequest(controller, requestId, msg.sender);
    }

    /// @notice Whether a cancel is waiting to be claimed.
    function pendingCancelDepositRequest(uint256 requestId, address controller) external view returns (bool) {
        return pendingCancelAssets[requestId][controller] > 0;
    }

    /// @notice Assets returnable from a cancel.
    function claimableCancelDepositRequest(uint256 requestId, address controller) external view returns (uint256) {
        return pendingCancelAssets[requestId][controller];
    }

    /// @notice Returns cancelled assets.
    function claimCancelDepositRequest(uint256 requestId, address receiver, address controller)
        external
        onlyControllerOrOperator(controller)
    {
        uint256 assets = pendingCancelAssets[requestId][controller];
        require(assets > 0, NothingToCancel());

        pendingCancelAssets[requestId][controller] = 0;
        claimedCancelAssets[requestId][controller] += assets;
        _clearDepositIfFullyResolved(requestId, controller);

        CORE.removePendingJunior(assets, receiver);
        emit CancelDepositClaimed(controller, receiver, requestId, assets);
    }
}
