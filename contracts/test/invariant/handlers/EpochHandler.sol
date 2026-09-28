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
        uint256 epochId = _pickEpoch(epochSeed, sv.nextEpochToFill(), openId);
        uint256 assets = _fillSize(assetsSeed);

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
        uint256 epochId = _pickEpoch(epochSeed, jv.nextDepositEpochToFill(), openId);
        uint256 assets = _fillSize(assetsSeed);

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
        uint256 epochId = _pickEpoch(epochSeed, jv.nextRedeemEpochToFill(), openId);
        uint256 assets = _fillSize(assetsSeed);

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

    function _fillSize(uint256 seed) internal pure returns (uint256) {
        return bound(seed, 0, seed % 2 == 0 ? 50_000e6 : 5_000_000e6);
    }

    function _pickEpoch(uint256 seed, uint256 pointer, uint256 openId) internal pure returns (uint256) {
        if (seed % 4 == 0 || pointer >= openId) return bound(seed, 1, openId - 1);
        return pointer;
    }

    function warpEpochClock(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 0, 10 days));
    }

    function strangerCloseSeniorRedeem(uint256 actorSeed) external {
        usdcSeniorVault sv = registry.seniorVault();
        uint256 id = sv.openEpochId();
        bool early = block.timestamp < sv.epochOpenedAt(id) + sv.MAX_EPOCH_DURATION();
        vm.prank(_actor(actorSeed));
        try sv.closeEpoch() {
            assertFalse(early, "a non-operator closed a senior exit batch before the max duration");
            registry.recordCall(this.strangerCloseSeniorRedeem.selector, false);
        } catch {
            registry.recordCall(this.strangerCloseSeniorRedeem.selector, true);
        }
    }

    function strangerFillSeniorRedeem(uint256 actorSeed, uint256 assetsSeed) external {
        usdcSeniorVault sv = registry.seniorVault();
        uint256 id = sv.nextEpochToFill();
        if (id >= sv.openEpochId()) return;
        bool early = block.timestamp < sv.epochClosedAt(id) + sv.FILL_GRACE();
        (, uint256 before,,,,) = sv.epochs(id);
        vm.prank(_actor(actorSeed));
        try sv.fulfill(id, _fillSize(assetsSeed)) {
            (, uint256 afterFill,,,,) = sv.epochs(id);
            assertFalse(early && afterFill != before, "a non-operator filled a senior exit batch inside the grace");
            registry.recordCall(this.strangerFillSeniorRedeem.selector, false);
        } catch {
            registry.recordCall(this.strangerFillSeniorRedeem.selector, true);
        }
    }

    function strangerCloseJuniorDeposit(uint256 actorSeed) external {
        usdcJuniorVault jv = registry.juniorVault();
        uint256 id = jv.openDepositEpochId();
        bool early = block.timestamp < jv.depositEpochOpenedAt(id) + jv.MAX_EPOCH_DURATION();
        vm.prank(_actor(actorSeed));
        try jv.closeDepositEpoch() {
            assertFalse(early, "a non-operator closed a junior entry batch before the max duration");
            registry.recordCall(this.strangerCloseJuniorDeposit.selector, false);
        } catch {
            registry.recordCall(this.strangerCloseJuniorDeposit.selector, true);
        }
    }

    function strangerFillJuniorDeposit(uint256 actorSeed, uint256 assetsSeed) external {
        usdcJuniorVault jv = registry.juniorVault();
        uint256 id = jv.nextDepositEpochToFill();
        if (id >= jv.openDepositEpochId()) return;
        bool early = block.timestamp < jv.depositEpochClosedAt(id) + jv.FILL_GRACE();
        (, uint256 before,,,,) = jv.depositEpochs(id);
        vm.prank(_actor(actorSeed));
        try jv.fulfillDeposit(id, _fillSize(assetsSeed)) {
            (, uint256 afterFill,,,,) = jv.depositEpochs(id);
            assertFalse(early && afterFill != before, "a non-operator filled a junior entry batch inside the grace");
            registry.recordCall(this.strangerFillJuniorDeposit.selector, false);
        } catch {
            registry.recordCall(this.strangerFillJuniorDeposit.selector, true);
        }
    }

    function strangerCloseJuniorRedeem(uint256 actorSeed) external {
        usdcJuniorVault jv = registry.juniorVault();
        uint256 id = jv.openRedeemEpochId();
        bool early = block.timestamp < jv.redeemEpochOpenedAt(id) + jv.MAX_EPOCH_DURATION();
        vm.prank(_actor(actorSeed));
        try jv.closeRedeemEpoch() {
            assertFalse(early, "a non-operator closed a junior exit batch before the max duration");
            registry.recordCall(this.strangerCloseJuniorRedeem.selector, false);
        } catch {
            registry.recordCall(this.strangerCloseJuniorRedeem.selector, true);
        }
    }

    function strangerFillJuniorRedeem(uint256 actorSeed, uint256 assetsSeed) external {
        usdcJuniorVault jv = registry.juniorVault();
        uint256 id = jv.nextRedeemEpochToFill();
        if (id >= jv.openRedeemEpochId()) return;
        bool early = block.timestamp < jv.redeemEpochClosedAt(id) + jv.FILL_GRACE();
        (, uint256 before,,,,) = jv.redeemEpochs(id);
        vm.prank(_actor(actorSeed));
        try jv.fulfillRedeem(id, _fillSize(assetsSeed)) {
            (, uint256 afterFill,,,,) = jv.redeemEpochs(id);
            assertFalse(early && afterFill != before, "a non-operator filled a junior exit batch inside the grace");
            registry.recordCall(this.strangerFillJuniorRedeem.selector, false);
        } catch {
            registry.recordCall(this.strangerFillJuniorRedeem.selector, true);
        }
    }
}
