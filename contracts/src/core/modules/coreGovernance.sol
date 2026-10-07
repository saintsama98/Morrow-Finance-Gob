// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: role wiring, the curator's timelocked policy and the instant risk-reducing levers.
// @author adiii.eth

pragma solidity 0.8.34;

import {coreValuation} from "./coreValuation.sol";

/// @notice Role wiring, the timelocked policy path and the instant risk-reducing moves.
abstract contract coreGovernance is coreValuation {
    /// @notice Wires the senior and junior vaults; callable once.
    function setVaults(address seniorVault_, address juniorVault_) external onlyGovernance {
        require(!vaultsSet, VaultsAlreadySet());
        seniorVault = seniorVault_;
        juniorVault = juniorVault_;
        vaultsSet = true;
        emit VaultsSet(seniorVault_, juniorVault_);
    }

    /// @notice Hands governance to a new address.
    function transferGovernance(address newGovernance) external onlyGovernance {
        governance = newGovernance;
    }

    /// @notice Sets the allocator that opens series and runs batches.
    function setAllocator(address newAllocator) external onlyGovernance {
        allocator = newAllocator;
    }

    /// @notice Sets the curator that sets risk policy.
    function setCurator(address newCurator) external onlyGovernance {
        curator = newCurator;
    }

    /// @notice Sets the sentinel that may only reduce risk.
    function setSentinel(address newSentinel) external onlyGovernance {
        sentinel = newSentinel;
    }

    /// @notice Sets the recipient of the fee on junior profit.
    function setFeeRecipient(address newFeeRecipient) external onlyGovernance {
        require(newFeeRecipient != address(0), ZeroAddress());
        feeRecipient = newFeeRecipient;
        emit FeeRecipientSet(newFeeRecipient);
    }

    /// @notice Queues a policy change behind the 3-day curator timelock.
    function proposePolicyChange(bytes32 key, uint256 value) external returns (uint256 executableAt) {
        require(msg.sender == curator, NotCuratorOrSentinel());
        executableAt = block.timestamp + CURATOR_TIMELOCK;
        pendingPolicyChanges[key] = PendingPolicyChange(true, value, executableAt);
        emit PolicySubmitted(key, value, executableAt);
    }

    /// @notice Applies a queued policy change once its timelock has passed.
    function executePolicyChange(bytes32 key) external {
        PendingPolicyChange memory change = pendingPolicyChanges[key];
        require(change.active && block.timestamp >= change.executableAt, TimelockNotElapsed());
        delete pendingPolicyChanges[key];
        _writePolicy(key, change.value);
        emit PolicyExecuted(key, change.value);
    }

    /// @notice Pauses new series and deposits.
    function pause() external onlyCuratorOrSentinel {
        paused = true;
        emit Paused_(true);
    }

    /// @notice Lifts the pause.
    function unpause() external onlyGovernance {
        paused = false;
        emit Paused_(false);
    }

    /// @notice Lowers the number of live series allowed.
    function lowerMaxSeries(uint256 newMax) external onlyCuratorOrSentinel {
        require(newMax <= policy.maxSeries, TimelockIsRiskDecreasing());
        policy.maxSeries = newMax;
        emit PolicyExecuted(keccak256("maxSeries"), newMax);
    }

    /// @notice Lowers the size cap of a single series.
    function lowerMaxPerSeriesAssets(uint256 newMax) external onlyCuratorOrSentinel {
        require(newMax <= policy.maxPerSeriesAssets, TimelockIsRiskDecreasing());
        policy.maxPerSeriesAssets = newMax;
        emit PolicyExecuted(keccak256("maxPerSeriesAssets"), newMax);
    }

    /// @notice Lowers the maximum junior share of a series.
    function lowerAMaxWad(uint256 newAMax) external onlyCuratorOrSentinel {
        require(newAMax <= policy.aMaxWad && newAMax >= policy.covWad, TimelockIsRiskDecreasing());
        policy.aMaxWad = newAMax;
        emit PolicyExecuted(keccak256("aMaxWad"), newAMax);
    }

    /// @notice Raises the senior idle floor kept out of new series.
    function raiseMinIdleSeniorWad(uint256 newFloor) external onlyCuratorOrSentinel {
        require(newFloor >= policy.minIdleSeniorWad && newFloor <= WAD, TimelockIsRiskDecreasing());
        policy.minIdleSeniorWad = newFloor;
        emit PolicyExecuted(keccak256("minIdleSeniorWad"), newFloor);
    }

    /// @notice Raises the junior idle floor kept out of new series.
    function raiseMinIdleJuniorWad(uint256 newFloor) external onlyCuratorOrSentinel {
        require(newFloor >= policy.minIdleJuniorWad && newFloor <= WAD, TimelockIsRiskDecreasing());
        policy.minIdleJuniorWad = newFloor;
        emit PolicyExecuted(keccak256("minIdleJuniorWad"), newFloor);
    }

    /// @notice Raises the junior value floor that closes senior deposits.
    function raiseStressJuniorFloorWad(uint256 newFloor) external onlyCuratorOrSentinel {
        require(newFloor >= policy.stressJuniorFloorWad && newFloor <= WAD, TimelockIsRiskDecreasing());
        policy.stressJuniorFloorWad = newFloor;
        emit PolicyExecuted(keccak256("stressJuniorFloorWad"), newFloor);
    }

    /// @notice Raises the coverage floor that limits junior exits.
    function raiseCovVaultMinWad(uint256 newFloor) external onlyCuratorOrSentinel {
        require(newFloor >= policy.covVaultMinWad && newFloor < WAD, TimelockIsRiskDecreasing());
        policy.covVaultMinWad = newFloor;
        emit PolicyExecuted(keccak256("covVaultMinWad"), newFloor);
    }

    /// @notice Turns off the cross-series backstop from junior idle.
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
