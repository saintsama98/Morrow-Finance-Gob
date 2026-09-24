// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SeriesRegistry} from "./SeriesRegistry.sol";
import {SeniorVault} from "../../../src/vaults/SeniorVault.sol";
import {JuniorVault} from "../../../src/vaults/JuniorVault.sol";
import {SeriesCore} from "../../../src/core/SeriesCore.sol";

// Morrow Finance — invariant-suite handler for the operator side of the three epoch tracks (M8).
// @author adiii.eth

/// @notice Fuzz handler: closeEpoch / fulfill / claim for all three epoch tracks (senior redeem, junior
/// deposit, junior redeem). Pranks as CURATOR for every operator-only call, matching `onlyOperator`'s
/// `curator || allocator` check. Claims are driven per fixed actor (VaultHandler's same synthetic set) so
/// CoreVaultInvariants can sum claimed-vs-fulfilled across a known, bounded population for I17/I18.
contract EpochHandler is Test {
    SeriesRegistry public registry;
    uint256 public constant N_ACTORS = 6;

    constructor(SeriesRegistry registry_) {
        registry = registry_;
    }

    function _actor(uint256 seed) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("vault-actor", seed % N_ACTORS)))));
    }

    // --- senior redeem epoch --------------------------------------------------------------------------------

    function closeSeniorRedeemEpoch() external {
        SeniorVault sv = registry.seniorVault();
        vm.prank(registry.CURATOR());
        try sv.closeEpoch() {
            registry.recordCall(this.closeSeniorRedeemEpoch.selector, false);
        } catch {
            registry.recordCall(this.closeSeniorRedeemEpoch.selector, true);
        }
    }

    function fulfillSeniorRedeem(uint256 epochSeed, uint256 assetsSeed) external {
        SeniorVault sv = registry.seniorVault();
        uint256 openId = sv.openEpochId();
        if (openId <= 1) return; // epoch 1 is still open until closeSeniorRedeemEpoch runs at least once
        uint256 epochId = bound(epochSeed, 1, openId - 1);
        uint256 assets = bound(assetsSeed, 0, 5_000_000e6);

        vm.prank(registry.CURATOR());
        try sv.fulfill(epochId, assets) {
            registry.recordCall(this.fulfillSeniorRedeem.selector, false);
        } catch {
            registry.recordCall(this.fulfillSeniorRedeem.selector, true);
        }
    }

    function claimSeniorRedeem(uint256 actorSeed, uint256 epochSeed) external {
        SeniorVault sv = registry.seniorVault();
        uint256 openId = sv.openEpochId();
        if (openId == 0) return;
        uint256 epochId = bound(epochSeed, 1, openId);
        address who = _actor(actorSeed);

        vm.prank(who);
        try sv.claim(epochId) {
            registry.recordCall(this.claimSeniorRedeem.selector, false);
        } catch {
            registry.recordCall(this.claimSeniorRedeem.selector, true);
        }
    }

    // --- junior deposit epoch -------------------------------------------------------------------------------

    function closeJuniorDepositEpoch() external {
        JuniorVault jv = registry.juniorVault();
        vm.prank(registry.CURATOR());
        try jv.closeDepositEpoch() {
            registry.recordCall(this.closeJuniorDepositEpoch.selector, false);
        } catch {
            registry.recordCall(this.closeJuniorDepositEpoch.selector, true);
        }
    }

    function fulfillJuniorDeposit(uint256 epochSeed, uint256 assetsSeed) external {
        JuniorVault jv = registry.juniorVault();
        uint256 openId = jv.openDepositEpochId();
        if (openId <= 1) return;
        uint256 epochId = bound(epochSeed, 1, openId - 1);
        uint256 assets = bound(assetsSeed, 0, 5_000_000e6);

        vm.prank(registry.CURATOR());
        try jv.fulfillDeposit(epochId, assets) {
            registry.recordCall(this.fulfillJuniorDeposit.selector, false);
        } catch {
            registry.recordCall(this.fulfillJuniorDeposit.selector, true);
        }
    }

    function claimJuniorDeposit(uint256 actorSeed, uint256 epochSeed) external {
        JuniorVault jv = registry.juniorVault();
        uint256 openId = jv.openDepositEpochId();
        if (openId == 0) return;
        uint256 epochId = bound(epochSeed, 1, openId);
        address who = _actor(actorSeed);

        vm.prank(who);
        try jv.claimDeposit(epochId) {
            registry.recordCall(this.claimJuniorDeposit.selector, false);
        } catch {
            registry.recordCall(this.claimJuniorDeposit.selector, true);
        }
    }

    // --- junior redeem epoch ---------------------------------------------------------------------------------

    function closeJuniorRedeemEpoch() external {
        JuniorVault jv = registry.juniorVault();
        vm.prank(registry.CURATOR());
        try jv.closeRedeemEpoch() {
            registry.recordCall(this.closeJuniorRedeemEpoch.selector, false);
        } catch {
            registry.recordCall(this.closeJuniorRedeemEpoch.selector, true);
        }
    }

    function fulfillJuniorRedeem(uint256 epochSeed, uint256 assetsSeed) external {
        JuniorVault jv = registry.juniorVault();
        uint256 openId = jv.openRedeemEpochId();
        if (openId <= 1) return;
        uint256 epochId = bound(epochSeed, 1, openId - 1);
        uint256 assets = bound(assetsSeed, 0, 5_000_000e6);

        SeriesCore core = registry.realCore();
        vm.prank(registry.CURATOR());
        try jv.fulfillRedeem(epochId, assets) {
            registry.recordCall(this.fulfillJuniorRedeem.selector, false);
            // I21: checked right here against the CURRENT floor, not as a standing invariant -- covVaultMinWad
            // can be raised by the curator at any time with no re-validation against the existing book (that
            // is a curator-policy action, not a redemption, so it is out of scope for this property), which can
            // legitimately leave old coverage below a newly-raised floor without any fulfillment being at fault.
            // juniorRedeemable() bounds this call so it cannot itself breach whatever the floor is right now.
            uint256 sA = core.seniorAssets();
            uint256 jA = core.juniorAssets();
            if (sA + jA > 0) {
                (,,, uint256 covVaultMinWad,,,,,,,,,,,,,,,) = core.policy();
                assertGe(
                    jA * 1e18 / (sA + jA),
                    covVaultMinWad,
                    "junior coverage must not fall below covVaultMinWad right after a redemption fulfillment"
                );
            }
        } catch {
            registry.recordCall(this.fulfillJuniorRedeem.selector, true);
        }
    }

    function claimJuniorRedeem(uint256 actorSeed, uint256 epochSeed) external {
        JuniorVault jv = registry.juniorVault();
        uint256 openId = jv.openRedeemEpochId();
        if (openId == 0) return;
        uint256 epochId = bound(epochSeed, 1, openId);
        address who = _actor(actorSeed);

        vm.prank(who);
        try jv.claimRedeem(epochId) {
            registry.recordCall(this.claimJuniorRedeem.selector, false);
        } catch {
            registry.recordCall(this.claimJuniorRedeem.selector, true);
        }
    }
}
