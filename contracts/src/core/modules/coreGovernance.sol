// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: role wiring, the curator's timelocked policy and the instant risk-reducing levers.
// @author adiii.eth

pragma solidity 0.8.34;

import {coreValuation} from "./coreValuation.sol";

abstract contract coreGovernance is coreValuation {
    function setVaults(address seniorVault_, address juniorVault_) external onlyGovernance {
        require(!vaultsSet, VaultsAlreadySet());
        seniorVault = seniorVault_;
        juniorVault = juniorVault_;
        vaultsSet = true;
        emit VaultsSet(seniorVault_, juniorVault_);
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        governance = newGovernance;
    }

    function setAllocator(address newAllocator) external onlyGovernance {
        allocator = newAllocator;
    }

    function setCurator(address newCurator) external onlyGovernance {
        curator = newCurator;
    }

    function setSentinel(address newSentinel) external onlyGovernance {
        sentinel = newSentinel;
    }

    function setFeeRecipient(address newFeeRecipient) external onlyGovernance {
        require(newFeeRecipient != address(0), ZeroAddress());
        feeRecipient = newFeeRecipient;
        emit FeeRecipientSet(newFeeRecipient);
    }

    function proposePolicyChange(bytes32 key, uint256 value) external returns (uint256 executableAt) {
        require(msg.sender == curator, NotCuratorOrSentinel());
        executableAt = block.timestamp + CURATOR_TIMELOCK;
        pendingPolicyChanges[key] = PendingPolicyChange(true, value, executableAt);
        emit PolicySubmitted(key, value, executableAt);
    }

    function executePolicyChange(bytes32 key) external {
        PendingPolicyChange memory change = pendingPolicyChanges[key];
        require(change.active && block.timestamp >= change.executableAt, TimelockNotElapsed());
        delete pendingPolicyChanges[key];
        _writePolicy(key, change.value);
        emit PolicyExecuted(key, change.value);
    }

    function pause() external onlyCuratorOrSentinel {
        paused = true;
        emit Paused_(true);
    }

    function unpause() external onlyGovernance {
        paused = false;
        emit Paused_(false);
    }

    function lowerMaxSeries(uint256 newMax) external onlyCuratorOrSentinel {
        require(newMax <= policy.maxSeries, TimelockIsRiskDecreasing());
        policy.maxSeries = newMax;
        emit PolicyExecuted(keccak256("maxSeries"), newMax);
    }

    function lowerMaxPerSeriesAssets(uint256 newMax) external onlyCuratorOrSentinel {
        require(newMax <= policy.maxPerSeriesAssets, TimelockIsRiskDecreasing());
        policy.maxPerSeriesAssets = newMax;
        emit PolicyExecuted(keccak256("maxPerSeriesAssets"), newMax);
    }

    function lowerAMaxWad(uint256 newAMax) external onlyCuratorOrSentinel {
        require(newAMax <= policy.aMaxWad && newAMax >= policy.covWad, TimelockIsRiskDecreasing());
        policy.aMaxWad = newAMax;
        emit PolicyExecuted(keccak256("aMaxWad"), newAMax);
    }

    function raiseMinIdleSeniorWad(uint256 newFloor) external onlyCuratorOrSentinel {
        require(newFloor >= policy.minIdleSeniorWad && newFloor <= WAD, TimelockIsRiskDecreasing());
        policy.minIdleSeniorWad = newFloor;
        emit PolicyExecuted(keccak256("minIdleSeniorWad"), newFloor);
    }

    function raiseMinIdleJuniorWad(uint256 newFloor) external onlyCuratorOrSentinel {
        require(newFloor >= policy.minIdleJuniorWad && newFloor <= WAD, TimelockIsRiskDecreasing());
        policy.minIdleJuniorWad = newFloor;
        emit PolicyExecuted(keccak256("minIdleJuniorWad"), newFloor);
    }

    function raiseStressJuniorFloorWad(uint256 newFloor) external onlyCuratorOrSentinel {
        require(newFloor >= policy.stressJuniorFloorWad && newFloor <= WAD, TimelockIsRiskDecreasing());
        policy.stressJuniorFloorWad = newFloor;
        emit PolicyExecuted(keccak256("stressJuniorFloorWad"), newFloor);
    }

    function raiseCovVaultMinWad(uint256 newFloor) external onlyCuratorOrSentinel {
        require(newFloor >= policy.covVaultMinWad && newFloor < WAD, TimelockIsRiskDecreasing());
        policy.covVaultMinWad = newFloor;
        emit PolicyExecuted(keccak256("covVaultMinWad"), newFloor);
    }

    function disableBackstop() external onlyCuratorOrSentinel {
        policy.backstopEnabled = false;
        emit PolicyExecuted(keccak256("backstopEnabled"), 0);
    }

    function _writePolicy(bytes32 key, uint256 value) internal {
        if (key == keccak256("covWad")) policy.covWad = value;
        else if (key == keccak256("aMaxWad")) policy.aMaxWad = value;
        else if (key == keccak256("covVaultWad")) policy.covVaultWad = value;
        else if (key == keccak256("covVaultMinWad")) policy.covVaultMinWad = value;
        else if (key == keccak256("pi0Wad")) policy.pi0Wad = value;
        else if (key == keccak256("piTWad")) policy.piTWad = value;
        else if (key == keccak256("pi1Wad")) policy.pi1Wad = value;
        else if (key == keccak256("thetaWad")) policy.thetaWad = value;
        else if (key == keccak256("minRateFloorWad")) policy.minRateFloorWad = value;
        else if (key == keccak256("maxSeries")) policy.maxSeries = value;
        else if (key == keccak256("maxRecovering")) policy.maxRecovering = value;
        else if (key == keccak256("maxPerSeriesAssets")) policy.maxPerSeriesAssets = value;
        else if (key == keccak256("maxPerMaturityWindowWad")) policy.maxPerMaturityWindowWad = value;
        else if (key == keccak256("minIdleSeniorWad")) policy.minIdleSeniorWad = value;
        else if (key == keccak256("minIdleJuniorWad")) policy.minIdleJuniorWad = value;
        else if (key == keccak256("stressJuniorFloorWad")) policy.stressJuniorFloorWad = value;
        else if (key == keccak256("backstopEnabled")) policy.backstopEnabled = value != 0;
        else if (key == keccak256("backstopWad")) policy.backstopWad = value;
        else if (key == keccak256("curatorMinShareWad")) policy.curatorMinShareWad = value;
        else if (key == keccak256("maxKMinAssets")) maxKMinAssets = value;
    }
}
