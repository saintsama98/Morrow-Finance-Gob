// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SeriesRegistry} from "./SeriesRegistry.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {SeriesCore} from "../../../src/core/SeriesCore.sol";
import {SeniorVault} from "../../../src/vaults/SeniorVault.sol";
import {JuniorVault} from "../../../src/vaults/JuniorVault.sol";

// Morrow Finance — invariant-suite handler for direct depositor/curator actions on the two vaults (M8).
// @author adiii.eth

/// @notice Fuzz handler: senior deposit, junior requestDeposit, senior/junior requestRedeem, cancels, share
/// transfers between depositors, and curator risk-policy actions. Runs against a small fixed set of synthetic
/// depositor addresses (so later redeem/cancel/transfer calls can target cash/shares an earlier call actually
/// created) plus the registry's fixed CURATOR/GOVERNANCE addresses.
///
/// I22 ("senior deposits revert whenever the stress gate is closed") is asserted actively inside seniorDeposit
/// itself, since it is a transition property (something must revert), not a state readable at rest between
/// calls -- everything else this handler feeds is checked by CoreVaultInvariants' invariant_ functions instead.
contract VaultHandler is Test {
    SeriesRegistry public registry;

    uint256 public constant N_ACTORS = 6;
    address[] public actors;

    constructor(SeriesRegistry registry_) {
        registry = registry_;
        for (uint256 i = 0; i < N_ACTORS; i++) {
            actors.push(address(uint160(uint256(keccak256(abi.encode("vault-actor", i))))));
        }
    }

    function actorsCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % N_ACTORS];
    }

    // --- senior: synchronous deposit, async redeem -------------------------------------------------------------

    function seniorDeposit(uint256 actorSeed, uint256 assetsSeed) external {
        address who = _actor(actorSeed);
        uint256 assets = bound(assetsSeed, 1e6, 3_000_000e6);

        SeriesCore core = registry.realCore();
        MockUSDC usdc = registry.usdc();
        usdc.mint(who, assets);

        vm.startPrank(who);
        usdc.approve(address(registry.seniorVault()), assets);
        bool gateWasClosed = !core.stressGateOpen();
        try registry.seniorVault().deposit(assets, who) {
            vm.stopPrank();
            registry.recordCall(this.seniorDeposit.selector, false);
            // I22: a deposit must never succeed while the gate reads closed at the moment it was attempted.
            assertFalse(gateWasClosed, "senior deposit succeeded while the stress gate was closed");
            // I20: checked right here, not as a standing invariant -- capacity is an entry-time gate on THIS
            // deposit (SeniorVault.deposit checks it before minting); it is not maintained afterward, so a
            // later junior redemption can legitimately shrink capacity below an already-admitted senior book
            // without that being a violation of this property.
            assertLe(
                core.seniorAssets(),
                core.seniorCapacity(),
                "senior assets must not exceed capacity right after a deposit"
            );
        } catch {
            vm.stopPrank();
            registry.recordCall(this.seniorDeposit.selector, true);
        }
    }

    function seniorRequestRedeem(uint256 actorSeed, uint256 sharesSeed) external {
        address who = _actor(actorSeed);
        SeniorVault sv = registry.seniorVault();
        uint256 bal = sv.balanceOf(who);
        if (bal == 0) return;
        uint256 shares = bound(sharesSeed, 1, bal);

        vm.prank(who);
        try sv.requestRedeem(shares) {
            registry.recordCall(this.seniorRequestRedeem.selector, false);
        } catch {
            registry.recordCall(this.seniorRequestRedeem.selector, true);
        }
    }

    function seniorCancelRedeem(uint256 actorSeed, uint256 epochSeed) external {
        address who = _actor(actorSeed);
        SeniorVault sv = registry.seniorVault();
        uint256 openId = sv.openEpochId();
        if (openId == 0) return;
        uint256 epochId = bound(epochSeed, 1, openId);

        vm.prank(who);
        try sv.cancelRedeem(epochId) {
            registry.recordCall(this.seniorCancelRedeem.selector, false);
        } catch {
            registry.recordCall(this.seniorCancelRedeem.selector, true);
        }
    }

    function transferSeniorShares(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        SeniorVault sv = registry.seniorVault();
        uint256 bal = sv.balanceOf(from);
        if (bal == 0) return;
        uint256 amount = bound(amountSeed, 1, bal);

        vm.prank(from);
        try sv.transfer(to, amount) {
            registry.recordCall(this.transferSeniorShares.selector, false);
        } catch {
            registry.recordCall(this.transferSeniorShares.selector, true);
        }
    }

    // --- junior: async deposit and redeem, both epoch-based -----------------------------------------------------

    function juniorRequestDeposit(uint256 actorSeed, uint256 assetsSeed) external {
        address who = _actor(actorSeed);
        uint256 assets = bound(assetsSeed, 1e6, 3_000_000e6);

        MockUSDC usdc = registry.usdc();
        usdc.mint(who, assets);

        vm.startPrank(who);
        usdc.approve(address(registry.juniorVault()), assets);
        try registry.juniorVault().requestDeposit(assets) {
            registry.recordCall(this.juniorRequestDeposit.selector, false);
        } catch {
            registry.recordCall(this.juniorRequestDeposit.selector, true);
        }
        vm.stopPrank();
    }

    /// @dev I23: the curator making a NEW deposit widens their own cushion above curatorMinShareWad. Fuzzing
    /// this alongside curatorJuniorRequestRedeemAttempt lets a run explore both directions of the floor.
    function curatorJuniorRequestDeposit(uint256 assetsSeed) external {
        address curator = registry.CURATOR();
        uint256 assets = bound(assetsSeed, 1e6, 3_000_000e6);

        MockUSDC usdc = registry.usdc();
        usdc.mint(curator, assets);

        vm.startPrank(curator);
        usdc.approve(address(registry.juniorVault()), assets);
        try registry.juniorVault().requestDeposit(assets) {
            registry.recordCall(this.curatorJuniorRequestDeposit.selector, false);
        } catch {
            registry.recordCall(this.curatorJuniorRequestDeposit.selector, true);
        }
        vm.stopPrank();
    }

    /// @dev I23's actual guard: JuniorVault.requestRedeem reverts if it would take the curator below
    /// curatorMinShareWad. Only requestRedeem is restricted (matches build spec section 20.8's exact wording);
    /// a plain ERC20 transfer of the curator's own jrUSDC is NOT guarded by this check -- that is the spec's
    /// stated design, not an oversight here, and is worth remembering as a real limit of what I23 covers.
    function curatorJuniorRequestRedeemAttempt(uint256 sharesSeed) external {
        address curator = registry.CURATOR();
        JuniorVault jv = registry.juniorVault();
        uint256 bal = jv.balanceOf(curator);
        if (bal == 0) return;
        uint256 shares = bound(sharesSeed, 1, bal);
        (,,,,,,,,,,,,,,,,,, uint256 curatorMinShareWad) = registry.realCore().policy();
        uint256 supply = jv.totalSupply();

        vm.prank(curator);
        try jv.requestRedeem(shares) {
            registry.recordCall(this.curatorJuniorRequestRedeemAttempt.selector, false);
            // Active check, not just trusting the require() in the vault: confirm the post-state genuinely
            // respects the floor, using the pre-call supply (requestRedeem does not change totalSupply()).
            assertGe(
                jv.balanceOf(curator) * 1e18,
                curatorMinShareWad * supply,
                "curator requestRedeem succeeded but left them below curatorMinShareWad"
            );
        } catch {
            registry.recordCall(this.curatorJuniorRequestRedeemAttempt.selector, true);
        }
    }

    function juniorCancelDeposit(uint256 actorSeed, uint256 epochSeed) external {
        address who = _actor(actorSeed);
        JuniorVault jv = registry.juniorVault();
        uint256 openId = jv.openDepositEpochId();
        if (openId == 0) return;
        uint256 epochId = bound(epochSeed, 1, openId);

        vm.prank(who);
        try jv.cancelDeposit(epochId) {
            registry.recordCall(this.juniorCancelDeposit.selector, false);
        } catch {
            registry.recordCall(this.juniorCancelDeposit.selector, true);
        }
    }

    function juniorRequestRedeem(uint256 actorSeed, uint256 sharesSeed) external {
        address who = _actor(actorSeed);
        JuniorVault jv = registry.juniorVault();
        uint256 bal = jv.balanceOf(who);
        if (bal == 0) return;
        uint256 shares = bound(sharesSeed, 1, bal);

        vm.prank(who);
        try jv.requestRedeem(shares) {
            registry.recordCall(this.juniorRequestRedeem.selector, false);
        } catch {
            registry.recordCall(this.juniorRequestRedeem.selector, true);
        }
    }

    function juniorCancelRedeem(uint256 actorSeed, uint256 epochSeed) external {
        address who = _actor(actorSeed);
        JuniorVault jv = registry.juniorVault();
        uint256 openId = jv.openRedeemEpochId();
        if (openId == 0) return;
        uint256 epochId = bound(epochSeed, 1, openId);

        vm.prank(who);
        try jv.cancelRedeem(epochId) {
            registry.recordCall(this.juniorCancelRedeem.selector, false);
        } catch {
            registry.recordCall(this.juniorCancelRedeem.selector, true);
        }
    }

    function transferJuniorShares(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        JuniorVault jv = registry.juniorVault();
        uint256 bal = jv.balanceOf(from);
        if (bal == 0) return;
        uint256 amount = bound(amountSeed, 1, bal);

        vm.prank(from);
        try jv.transfer(to, amount) {
            registry.recordCall(this.transferJuniorShares.selector, false);
        } catch {
            registry.recordCall(this.transferJuniorShares.selector, true);
        }
    }

    // --- curator policy: immediate risk-decreasing setters + the timelocked path for two anchor keys ------------

    function curatorLowerAMaxWad(uint256 newSeed) external {
        SeriesCore core = registry.realCore();
        (, uint256 aMaxWad,,,,,,,,,,,,,,,,,) = core.policy();
        if (aMaxWad == 0) return;
        uint256 newAMax = bound(newSeed, 0, aMaxWad);

        vm.prank(registry.CURATOR());
        try core.lowerAMaxWad(newAMax) {
            registry.recordCall(this.curatorLowerAMaxWad.selector, false);
        } catch {
            registry.recordCall(this.curatorLowerAMaxWad.selector, true);
        }
    }

    function curatorRaiseMinIdleSeniorWad(uint256 deltaSeed) external {
        SeriesCore core = registry.realCore();
        (,,,,,,,,,,,,, uint256 minIdleSeniorWad,,,,,) = core.policy();
        uint256 newFloor = minIdleSeniorWad + bound(deltaSeed, 0, 0.1e18);
        if (newFloor > 1e18) newFloor = 1e18;

        vm.prank(registry.CURATOR());
        try core.raiseMinIdleSeniorWad(newFloor) {
            registry.recordCall(this.curatorRaiseMinIdleSeniorWad.selector, false);
        } catch {
            registry.recordCall(this.curatorRaiseMinIdleSeniorWad.selector, true);
        }
    }

    function curatorRaiseCovVaultMinWad(uint256 deltaSeed) external {
        SeriesCore core = registry.realCore();
        (,,, uint256 covVaultMinWad,,,,,,,,,,,,,,,) = core.policy();
        uint256 newFloor = covVaultMinWad + bound(deltaSeed, 0, 0.05e18);
        if (newFloor >= 1e18) newFloor = 0.99e18;

        vm.prank(registry.CURATOR());
        try core.raiseCovVaultMinWad(newFloor) {
            registry.recordCall(this.curatorRaiseCovVaultMinWad.selector, false);
        } catch {
            registry.recordCall(this.curatorRaiseCovVaultMinWad.selector, true);
        }
    }

    function curatorPause() external {
        SeriesCore core = registry.realCore();
        vm.prank(registry.CURATOR());
        try core.pause() {
            registry.recordCall(this.curatorPause.selector, false);
        } catch {
            registry.recordCall(this.curatorPause.selector, true);
        }
    }

    function governanceUnpause() external {
        SeriesCore core = registry.realCore();
        vm.prank(registry.GOVERNANCE());
        try core.unpause() {
            registry.recordCall(this.governanceUnpause.selector, false);
        } catch {
            registry.recordCall(this.governanceUnpause.selector, true);
        }
    }
}
