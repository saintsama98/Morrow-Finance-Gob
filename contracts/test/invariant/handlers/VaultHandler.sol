// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: invariant-suite handler for direct depositor/curator actions on the two vaults.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SeriesRegistry} from "./SeriesRegistry.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {seriesCore} from "../../../src/core/seriesCore.sol";
import {usdcSeniorVault} from "../../../src/vaults/senior/usdcSeniorVault.sol";
import {usdcJuniorVault} from "../../../src/vaults/junior/usdcJuniorVault.sol";

contract VaultHandler is Test {
    SeriesRegistry public registry;

    uint256 public constant N_ACTORS = 6;
    address[] public actors;

    uint256 public ghost_grossUsdcIn;
    uint256 public ghost_grossUsdcOut;

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

    function seniorDeposit(uint256 actorSeed, uint256 assetsSeed) external {
        address who = _actor(actorSeed);
        uint256 assets = bound(assetsSeed, 1e6, 3_000_000e6);

        seriesCore core = registry.realCore();
        MockUSDC usdc = registry.usdc();
        usdc.mint(who, assets);

        vm.startPrank(who);
        usdc.approve(address(registry.seniorVault()), assets);
        bool gateWasClosed = !core.stressGateOpen();
        try registry.seniorVault().deposit(assets, who) {
            vm.stopPrank();
            registry.recordCall(this.seniorDeposit.selector, false);
            ghost_grossUsdcIn += assets;
            assertFalse(gateWasClosed, "senior deposit succeeded while the stress gate was closed");
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
        usdcSeniorVault sv = registry.seniorVault();
        uint256 bal = sv.balanceOf(who);
        if (bal == 0) return;
        uint256 shares = bound(sharesSeed, 1, bal);

        vm.prank(who);
        try sv.requestRedeem(shares, who, who) {
            registry.recordCall(this.seniorRequestRedeem.selector, false);
        } catch {
            registry.recordCall(this.seniorRequestRedeem.selector, true);
        }
    }

    function seniorCancelRedeemRequest(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        usdcSeniorVault sv = registry.seniorVault();
        uint256 requestId = sv.activeRedeemRequestId(who);
        if (requestId == 0) return;

        vm.prank(who);
        try sv.cancelRedeemRequest(requestId, who) {
            registry.recordCall(this.seniorCancelRedeemRequest.selector, false);
        } catch {
            registry.recordCall(this.seniorCancelRedeemRequest.selector, true);
        }
    }

    function seniorClaimCancelRedeem(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        usdcSeniorVault sv = registry.seniorVault();
        uint256 requestId = sv.activeRedeemRequestId(who);
        if (requestId == 0) return;

        vm.prank(who);
        try sv.claimCancelRedeemRequest(requestId, who, who) {
            registry.recordCall(this.seniorClaimCancelRedeem.selector, false);
        } catch {
            registry.recordCall(this.seniorClaimCancelRedeem.selector, true);
        }
    }

    function transferSeniorShares(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        usdcSeniorVault sv = registry.seniorVault();
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

    function juniorRequestDeposit(uint256 actorSeed, uint256 assetsSeed) external {
        address who = _actor(actorSeed);
        uint256 assets = bound(assetsSeed, 1e6, 3_000_000e6);

        MockUSDC usdc = registry.usdc();
        usdc.mint(who, assets);

        vm.startPrank(who);
        usdc.approve(address(registry.juniorVault()), assets);
        try registry.juniorVault().requestDeposit(assets, who, who) {
            registry.recordCall(this.juniorRequestDeposit.selector, false);
            ghost_grossUsdcIn += assets;
        } catch {
            registry.recordCall(this.juniorRequestDeposit.selector, true);
        }
        vm.stopPrank();
    }

    function curatorJuniorRequestDeposit(uint256 assetsSeed) external {
        address curator = registry.CURATOR();
        uint256 assets = bound(assetsSeed, 1e6, 3_000_000e6);

        MockUSDC usdc = registry.usdc();
        usdc.mint(curator, assets);

        vm.startPrank(curator);
        usdc.approve(address(registry.juniorVault()), assets);
        try registry.juniorVault().requestDeposit(assets, curator, curator) {
            registry.recordCall(this.curatorJuniorRequestDeposit.selector, false);
            ghost_grossUsdcIn += assets;
        } catch {
            registry.recordCall(this.curatorJuniorRequestDeposit.selector, true);
        }
        vm.stopPrank();
    }

    function curatorJuniorRequestRedeemAttempt(uint256 sharesSeed) external {
        address curator = registry.CURATOR();
        usdcJuniorVault jv = registry.juniorVault();
        uint256 bal = jv.balanceOf(curator);
        if (bal == 0) return;
        uint256 shares = bound(sharesSeed, 1, bal);
        (,,,,,,,,,,,,,,,,,, uint256 curatorMinShareWad) = registry.realCore().policy();
        uint256 supply = jv.totalSupply();

        vm.prank(curator);
        try jv.requestRedeem(shares, curator, curator) {
            registry.recordCall(this.curatorJuniorRequestRedeemAttempt.selector, false);
            assertGe(
                jv.balanceOf(curator) * 1e18,
                curatorMinShareWad * supply,
                "curator requestRedeem succeeded but left them below curatorMinShareWad"
            );
        } catch {
            registry.recordCall(this.curatorJuniorRequestRedeemAttempt.selector, true);
        }
    }

    function juniorCancelDepositRequest(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        usdcJuniorVault jv = registry.juniorVault();
        uint256 requestId = jv.activeDepositRequestId(who);
        if (requestId == 0) return;

        vm.prank(who);
        try jv.cancelDepositRequest(requestId, who) {
            registry.recordCall(this.juniorCancelDepositRequest.selector, false);
        } catch {
            registry.recordCall(this.juniorCancelDepositRequest.selector, true);
        }
    }

    function juniorClaimCancelDeposit(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        usdcJuniorVault jv = registry.juniorVault();
        uint256 requestId = jv.activeDepositRequestId(who);
        if (requestId == 0) return;
        uint256 pending = jv.claimableCancelDepositRequest(requestId, who);

        vm.prank(who);
        try jv.claimCancelDepositRequest(requestId, who, who) {
            registry.recordCall(this.juniorClaimCancelDeposit.selector, false);
            ghost_grossUsdcOut += pending;
        } catch {
            registry.recordCall(this.juniorClaimCancelDeposit.selector, true);
        }
    }

    function juniorRequestRedeem(uint256 actorSeed, uint256 sharesSeed) external {
        address who = _actor(actorSeed);
        usdcJuniorVault jv = registry.juniorVault();
        uint256 bal = jv.balanceOf(who);
        if (bal == 0) return;
        uint256 shares = bound(sharesSeed, 1, bal);

        vm.prank(who);
        try jv.requestRedeem(shares, who, who) {
            registry.recordCall(this.juniorRequestRedeem.selector, false);
        } catch {
            registry.recordCall(this.juniorRequestRedeem.selector, true);
        }
    }

    function juniorCancelRedeemRequest(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        usdcJuniorVault jv = registry.juniorVault();
        uint256 requestId = jv.activeRedeemRequestId(who);
        if (requestId == 0) return;

        vm.prank(who);
        try jv.cancelRedeemRequest(requestId, who) {
            registry.recordCall(this.juniorCancelRedeemRequest.selector, false);
        } catch {
            registry.recordCall(this.juniorCancelRedeemRequest.selector, true);
        }
    }

    function juniorClaimCancelRedeem(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        usdcJuniorVault jv = registry.juniorVault();
        uint256 requestId = jv.activeRedeemRequestId(who);
        if (requestId == 0) return;

        vm.prank(who);
        try jv.claimCancelRedeemRequest(requestId, who, who) {
            registry.recordCall(this.juniorClaimCancelRedeem.selector, false);
        } catch {
            registry.recordCall(this.juniorClaimCancelRedeem.selector, true);
        }
    }

    function transferJuniorShares(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        usdcJuniorVault jv = registry.juniorVault();
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

    function curatorLowerAMaxWad(uint256 newSeed) external {
        seriesCore core = registry.realCore();
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
        seriesCore core = registry.realCore();
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
        seriesCore core = registry.realCore();
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
        seriesCore core = registry.realCore();
        vm.prank(registry.CURATOR());
        try core.pause() {
            registry.recordCall(this.curatorPause.selector, false);
        } catch {
            registry.recordCall(this.curatorPause.selector, true);
        }
    }

    function governanceUnpause() external {
        seriesCore core = registry.realCore();
        vm.prank(registry.GOVERNANCE());
        try core.unpause() {
            registry.recordCall(this.governanceUnpause.selector, false);
        } catch {
            registry.recordCall(this.governanceUnpause.selector, true);
        }
    }
}
