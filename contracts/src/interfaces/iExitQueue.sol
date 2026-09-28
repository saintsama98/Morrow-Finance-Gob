// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: what the core reads from each vault's exit queue: USDC already promised to closed exit batches.
// @author adiii.eth

pragma solidity 0.8.34;

interface iExitQueue {
    function queuedExitAssets() external view returns (uint256);
}
