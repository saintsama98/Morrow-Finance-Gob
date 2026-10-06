// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: shared series types: creation params and the lifecycle state machine.
// @author adiii.eth

pragma solidity 0.8.34;

import {iParking} from "../parking/iParking.sol";

struct SeriesParams {
    bytes32[] marketIds;
    uint64 tDeployEnd;
    uint64 dWriteOff;
    uint256 covWad;
    uint256 pi0Wad;
    uint256 piTWad;
    uint256 pi1Wad;
    uint256[] rateFloorWad;
    uint256[] marketCapAssets;
    uint256 kMinAssets;
    uint256 thetaWad;
    address feeRecipient;
    address allocator;
    iParking parking;
    bytes32 offchainAttestationHash;
}

enum SeriesState {
    DEPLOYING,
    LOCKED,
    SETTLING,
    SETTLED,
    CANCELED
}

/// @notice The part of a series the core calls.
interface iSeries {
    /// @notice Lifecycle state.
    function state() external view returns (SeriesState);
    /// @notice Whether the series settles pro rata instead of through the waterfall.
    function passThrough() external view returns (bool);
    /// @notice Funds the series with its senior and junior allocations.
    function initialize(uint256 seniorAllocated, uint256 juniorAllocated) external;
    /// @notice Cancels a series with no fills and returns its cash.
    function cancel() external;
    /// @notice Prices the senior claim and returns undeployed cash.
    function finalize() external;
}
