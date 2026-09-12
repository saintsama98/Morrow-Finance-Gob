// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {IParking} from "../parking/IParking.sol";

/// @dev section 7.4. Frozen at series creation by the factory, from the allocator's call plus curator policy.
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
    IParking parking;
    bytes32 offchainAttestationHash;
}

/// @dev section 6.1.
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
