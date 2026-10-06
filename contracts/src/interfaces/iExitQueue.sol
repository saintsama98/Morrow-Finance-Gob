// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: what the core reads from each vault's exit queue: USDC already promised to closed exit batches.
// @author adiii.eth

pragma solidity 0.8.34;

/// @notice Exit demand a vault has queued.
interface iExitQueue {
    /// @notice Assets waiting in closed exit batches.
    function queuedExitAssets() external view returns (uint256);
}
