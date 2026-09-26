// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: jrUSDC's ERC-7887 two-step entry cancel: queued USDC is refunded untouched by the core.
// @author adiii.eth

pragma solidity 0.8.34;

import {usdcJuniorDepositClaims} from "./usdcJuniorDepositClaims.sol";

abstract contract usdcJuniorDepositCancels is usdcJuniorDepositClaims {
    event CancelDepositRequest(address indexed controller, uint256 indexed requestId, address sender);
    event CancelDepositClaimed(
        address indexed controller, address indexed receiver, uint256 indexed requestId, uint256 assets
    );

    function cancelDepositRequest(uint256 requestId, address controller) external onlyControllerOrOperator(controller) {
        require(!depositEpochs[requestId].closed, EpochAlreadyClosed());
        require(pendingCancelAssets[requestId][controller] == 0, PendingCancelation());

        uint256 remaining = _depositRemainingUnfulfilled(requestId, controller);
        require(remaining > 0, NothingToCancel());

        pendingCancelAssets[requestId][controller] = remaining;
        depositEpochs[requestId].remainingFillable -= remaining;
        emit CancelDepositRequest(controller, requestId, msg.sender);
    }

    function pendingCancelDepositRequest(uint256 requestId, address controller) external view returns (bool) {
        return pendingCancelAssets[requestId][controller] > 0;
    }

    function claimableCancelDepositRequest(uint256 requestId, address controller) external view returns (uint256) {
        return pendingCancelAssets[requestId][controller];
    }

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
