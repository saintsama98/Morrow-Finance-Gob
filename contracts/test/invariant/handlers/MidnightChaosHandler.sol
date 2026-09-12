// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Midnight} from "@morpho-org/midnight/src/Midnight.sol";
import {UtilsLib} from "@morpho-org/midnight/src/libraries/UtilsLib.sol";
import {MAX_CONTINUOUS_FEE} from "@morpho-org/midnight/src/libraries/ConstantsLib.sol";

import {SeriesRegistry} from "./SeriesRegistry.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";

/// @dev section 25.4 MidnightChaosHandler: injectBadDebt (oracle crash + liquidate), repay, setFees (within
/// caps), warp, oracle moves. Shares one oracle/collateral token across every series (set up by
/// SeriesRegistry), so a crash affects every open position at once -- deliberately, to stress cross-series
/// isolation (I25-adjacent, though I25 itself needs SeriesCore's backstop to test meaningfully).
///
/// See DeployHandler's header note on why every address/reference used after `vm.prank` must be resolved into
/// a local variable *before* the prank line, not inline in the same expression as the pranked call.
contract MidnightChaosHandler is Test {
    using UtilsLib for uint256;

    SeriesRegistry public registry;
    uint256 public initialOraclePrice;

    constructor(SeriesRegistry registry_) {
        registry = registry_;
        initialOraclePrice = registry_.oracle().price();
    }

    function crashOracle(uint256 dropBps) external {
        dropBps = bound(dropBps, 0, 9000); // up to a 90% drop
        uint256 newPrice = initialOraclePrice - initialOraclePrice.mulDivDown(dropBps, 10_000);
        registry.oracle().setPrice(newPrice);
    }

    function restoreOracle() external {
        registry.oracle().setPrice(initialOraclePrice);
    }

    /// @dev Realizes bad debt on a series' borrower if their position is currently unhealthy (a no-op,
    /// non-reverting liquidation with 0 seized/repaid still realizes bad debt per section 2.3).
    function liquidate(uint256 seriesSeed) external {
        (address seriesAddr,) = registry.pickActive(seriesSeed);
        if (seriesAddr == address(0)) return;
        (, uint256 maturity,, address borrower) = registry.info(seriesAddr);
        if (borrower == address(0)) return;

        Midnight midnight = registry.midnight();
        try midnight.liquidate(registry.marketFor(maturity), 0, 0, 0, borrower, false, address(this), address(0), "")
        {
            registry.recordCall(this.liquidate.selector, false);
        } catch {
            registry.recordCall(this.liquidate.selector, true);
        }
    }

    function repay(uint256 seriesSeed, uint256 unitsSeed) external {
        (address seriesAddr,) = registry.pickActive(seriesSeed);
        if (seriesAddr == address(0)) return;
        (bytes32 marketId, uint256 maturity,, address borrower) = registry.info(seriesAddr);
        if (borrower == address(0)) return;

        Midnight midnight = registry.midnight();
        uint128 debtOwed = midnight.debt(marketId, borrower);
        if (debtOwed == 0) return;
        uint256 units = bound(unitsSeed, 1, debtOwed);

        address usdcAddr = address(registry.usdc());
        MockUSDC(usdcAddr).mint(borrower, units);

        vm.startPrank(borrower);
        MockUSDC(usdcAddr).approve(address(midnight), units);
        try midnight.repay(registry.marketFor(maturity), units, borrower, address(0), "") {
            registry.recordCall(this.repay.selector, false);
        } catch {
            registry.recordCall(this.repay.selector, true);
        }
        vm.stopPrank();
    }

    function setContinuousFee(uint256 feeSeed) external {
        uint256 fee = bound(feeSeed, 0, MAX_CONTINUOUS_FEE);
        try registry.setDefaultContinuousFee(fee) {
            registry.recordCall(this.setContinuousFee.selector, false);
        } catch {
            registry.recordCall(this.setContinuousFee.selector, true);
        }
    }

    /// @dev Bimodal, same rationale as DeployHandler.warp: mostly small jumps to let fill sequences correlate,
    /// occasional large jumps so runs still make progress toward the 14-day MIN_TERM maturity floor.
    function warp(uint256 seed) external {
        if (seed % 5 == 0) {
            uint256 bigDelta = bound(seed, 3 days, 10 days);
            vm.warp(block.timestamp + bigDelta);
        } else {
            uint256 smallDelta = bound(seed, 10 minutes, 2 hours);
            vm.warp(block.timestamp + smallDelta);
        }
    }
}
