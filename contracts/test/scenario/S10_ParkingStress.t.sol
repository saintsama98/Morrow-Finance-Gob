// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: S10: a real parking loss while deploying, split pro rata by a.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test, Vm} from "forge-std/Test.sol";
import {iParking} from "../../src/parking/iParking.sol";
import {SeriesRegistry} from "../invariant/handlers/SeriesRegistry.sol";
import {LossyParking} from "../mocks/LossyParking.sol";
import {ScenarioBase} from "./ScenarioBase.t.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {wadMath} from "../../src/libraries/wadMath.sol";

contract SeriesRegistryLossyParking is SeriesRegistry {
    function _deployParking() internal override returns (iParking) {
        return new LossyParking(address(usdc));
    }
}

contract S10_ParkingStressTest is ScenarioBase {
    using wadMath for uint256;

    address borrower = makeAddr("borrower");
    address seniorDepositor = makeAddr("seniorDepositor");
    address juniorDepositor = makeAddr("juniorDepositor");

    function setUp() public override {
        registry = new SeriesRegistryLossyParking();
        core = registry.realCore();
        seniorVault = registry.seniorVault();
        juniorVault = registry.juniorVault();
        usdc = registry.usdc();
    }

    function test_S10_parkingLossWhileDeploying_shortfallSplitByA_juniorTakesRounding() public {
        _juniorDeposit(juniorDepositor, 1_000_000e6);
        _seniorDeposit(seniorDepositor, 1_000_000e6);

        uint256 maturity = block.timestamp + 90 days;
        (address seriesAddr,) = _openSeries(700_000e6, 150_000e6, maturity);
        _registerAndFill(seriesAddr, maturity, 150_000e6, borrower);
        creditSeries series = creditSeries(seriesAddr);

        LossyParking lossyParking = LossyParking(address(registry.parking()));
        uint256 parkedBeforeLoss = lossyParking.totalAssets(seriesAddr);
        assertGt(parkedBeforeLoss, 0, "sanity: most of the allocation must still be parked, unfilled");

        uint256 loss = lossyParking.applyLoss(seriesAddr, 200);
        assertEq(loss, parkedBeforeLoss * 200 / 10_000, "sanity: the mock must realize exactly a 2% loss");
        uint256 balanceAtFinalize = lossyParking.totalAssets(seriesAddr);

        vm.recordLogs();
        _finalize(seriesAddr);
        (uint256 toSenior, uint256 toJunior) = _decodeReturnReceived();

        uint256 aWad = uint256(150_000e6).wDivDown(uint256(850_000e6));
        uint256 returnS = 700_000e6 - series.seniorDeployed();
        uint256 returnJ = 150_000e6 - series.juniorDeployed();
        uint256 undeployed = returnS + returnJ;

        assertLt(
            balanceAtFinalize,
            undeployed,
            "sanity: the realized loss must actually leave parking short of what's owed back"
        );

        uint256 shortfall = undeployed - balanceAtFinalize;
        assertEq(shortfall, loss, "the shortfall finalize sees must be exactly the loss just realized");

        uint256 shortfallS = shortfall.mulDivDown(1e18 - aWad, 1e18);
        uint256 shortfallJ = shortfall - shortfallS;
        uint256 expectedReturnS = returnS - shortfallS;
        uint256 expectedReturnJ = returnJ - shortfallJ;

        assertEq(
            toSenior,
            expectedReturnS,
            "senior's credited return must be reduced by exactly its (1-a) pro-rata share of the parking loss"
        );
        assertEq(
            toJunior,
            expectedReturnJ,
            "junior's credited return must be reduced by exactly its a pro-rata share of the parking loss, plus the rounding"
        );

        assertLt(toSenior, returnS, "senior must receive strictly less than the loss-free return");
        assertLt(toJunior, returnJ, "junior must receive strictly less than the loss-free return");
    }

    function _decodeReturnReceived() internal view returns (uint256 toSenior, uint256 toJunior) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 returnReceivedTopic = keccak256("ReturnReceived(address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == returnReceivedTopic) {
                (toSenior, toJunior) = abi.decode(logs[i].data, (uint256, uint256));
                return (toSenior, toJunior);
            }
        }
        revert("ReturnReceived not found");
    }
}
