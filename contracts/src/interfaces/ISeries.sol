// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {IParking} from "../parking/IParking.sol";

// Morrow Finance — shared series types: creation params and the lifecycle state machine.
// @author adiii.eth

/// @notice Parameters a series is created and frozen with, set once by the allocator and curator policy.
struct SeriesParams {
    bytes32[] marketIds; // the basket: every market's maturity must match
    uint64 tDeployEnd; // deadline for the deployment phase
    uint64 dWriteOff; // delay after maturity before unresolved credit is written off
    uint256 covWad; // minimum junior share of this series, wad
    uint256 pi0Wad; // premium curve anchor at zero utilization
    uint256 piTWad; // premium curve anchor at the kink
    uint256 pi1Wad; // premium curve anchor at full utilization
    uint256[] rateFloorWad; // per-market minimum acceptable term rate
    uint256[] marketCapAssets; // per-market cap on deployed assets
    uint256 kMinAssets; // minimum fill below which the series runs pass-through
    uint256 thetaWad; // operator fee rate on junior's profit
    address feeRecipient;
    address allocator;
    IParking parking;
    bytes32 offchainAttestationHash;
}

/// @notice A series' lifecycle. Transitions only ever move forward; no state is re-entered.
enum SeriesState {
    DEPLOYING,
    LOCKED,
    SETTLING,
    SETTLED,
    CANCELED
}

interface ISeries {
    function state() external view returns (SeriesState);
    function passThrough() external view returns (bool);
    function initialize(uint256 seniorAllocated, uint256 juniorAllocated) external;
    function cancel() external;
    function finalize() external;
}
