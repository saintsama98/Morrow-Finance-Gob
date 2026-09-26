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

interface iSeries {
    function state() external view returns (SeriesState);
    function passThrough() external view returns (bool);
    function initialize(uint256 seniorAllocated, uint256 juniorAllocated) external;
    function cancel() external;
    function finalize() external;
}
