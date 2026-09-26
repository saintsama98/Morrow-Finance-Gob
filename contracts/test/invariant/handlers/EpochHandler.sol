// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: invariant-suite handler for the operator side of the three epoch tracks.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SeriesRegistry} from "./SeriesRegistry.sol";
import {usdcSeniorVault} from "../../../src/vaults/senior/usdcSeniorVault.sol";
import {usdcJuniorVault} from "../../../src/vaults/junior/usdcJuniorVault.sol";
import {seriesCore} from "../../../src/core/seriesCore.sol";

contract EpochHandler is Test {
    SeriesRegistry public registry;
    uint256 public constant N_ACTORS = 6;

    uint256 public ghost_grossUsdcOut;

    constructor(SeriesRegistry registry_) {
        registry = registry_;
    }

    function _actor(uint256 seed) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("vault-actor", seed % N_ACTORS)))));
    }

    function closeSeniorRedeemEpoch() external {
        usdcSeniorVault sv = registry.seniorVault();
        vm.prank(registry.CURATOR());
        try sv.closeEpoch() {
            registry.recordCall(this.closeSeniorRedeemEpoch.selector, false);
        } catch {
            registry.recordCall(this.closeSeniorRedeemEpoch.selector, true);
        }
    }

    function fulfillSeniorRedeem(uint256 epochSeed, uint256 assetsSeed) external {
        usdcSeniorVault sv = registry.seniorVault();
        uint256 openId = sv.openEpochId();
        if (openId <= 1) return;
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
        usdcSeniorVault sv = registry.seniorVault();
        uint256 openId = sv.openEpochId();
        if (openId == 0) return;
        uint256 epochId = bound(epochSeed, 1, openId);
        address who = _actor(actorSeed);

        vm.prank(who);
        try sv.claim(epochId) returns (uint256 assets) {
            registry.recordCall(this.claimSeniorRedeem.selector, false);
            ghost_grossUsdcOut += assets;
        } catch {
            registry.recordCall(this.claimSeniorRedeem.selector, true);
        }
    }

    function closeJuniorDepositEpoch() external {
        usdcJuniorVault jv = registry.juniorVault();
        vm.prank(registry.CURATOR());
        try jv.closeDepositEpoch() {
            registry.recordCall(this.closeJuniorDepositEpoch.selector, false);
        } catch {
            registry.recordCall(this.closeJuniorDepositEpoch.selector, true);
        }
    }

    function fulfillJuniorDeposit(uint256 epochSeed, uint256 assetsSeed) external {
        usdcJuniorVault jv = registry.juniorVault();
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
        usdcJuniorVault jv = registry.juniorVault();
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

    function closeJuniorRedeemEpoch() external {
        usdcJuniorVault jv = registry.juniorVault();
        vm.prank(registry.CURATOR());
        try jv.closeRedeemEpoch() {
            registry.recordCall(this.closeJuniorRedeemEpoch.selector, false);
        } catch {
            registry.recordCall(this.closeJuniorRedeemEpoch.selector, true);
        }
    }

    function fulfillJuniorRedeem(uint256 epochSeed, uint256 assetsSeed) external {
        usdcJuniorVault jv = registry.juniorVault();
        uint256 openId = jv.openRedeemEpochId();
        if (openId <= 1) return;
        uint256 epochId = bound(epochSeed, 1, openId - 1);
        uint256 assets = bound(assetsSeed, 0, 5_000_000e6);

        seriesCore core = registry.realCore();
        vm.prank(registry.CURATOR());
        try jv.fulfillRedeem(epochId, assets) {
            registry.recordCall(this.fulfillJuniorRedeem.selector, false);
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
        usdcJuniorVault jv = registry.juniorVault();
        uint256 openId = jv.openRedeemEpochId();
        if (openId == 0) return;
        uint256 epochId = bound(epochSeed, 1, openId);
        address who = _actor(actorSeed);

        vm.prank(who);
        try jv.claimRedeem(epochId) returns (uint256 assets) {
            registry.recordCall(this.claimJuniorRedeem.selector, false);
            ghost_grossUsdcOut += assets;
        } catch {
            registry.recordCall(this.claimJuniorRedeem.selector, true);
        }
    }
}
