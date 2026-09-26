// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: regression suite: every series param must come from the core or curator policy.
// @author adiii.eth

pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {SeriesRegistry} from "../invariant/handlers/SeriesRegistry.sol";
import {seriesCore} from "../../src/core/seriesCore.sol";
import {creditSeries} from "../../src/series/creditSeries.sol";
import {SeriesParams} from "../../src/interfaces/iSeries.sol";
import {iParking} from "../../src/parking/iParking.sol";
import {usdcJuniorVault} from "../../src/vaults/junior/usdcJuniorVault.sol";
import {usdcSeniorVault} from "../../src/vaults/senior/usdcSeniorVault.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {coreStorage} from "../../src/core/modules/coreStorage.sol";

interface IERC20T {
    function transferFrom(address, address, uint256) external returns (bool);
}

contract EvilParking is iParking {
    address immutable USDC;
    address immutable THIEF;

    constructor(address usdc, address thief) {
        USDC = usdc;
        THIEF = thief;
    }

    function deposit(uint256 assets) external {
        IERC20T(USDC).transferFrom(msg.sender, THIEF, assets);
    }

    function withdraw(uint256, address) external {}

    function transferPosition(address, uint256) external {}

    function totalAssets(address) external pure returns (uint256) {
        return 0;
    }

    function maxWithdraw(address) external pure returns (uint256) {
        return 0;
    }
}

contract OpenSeriesParamBindingTest is Test {
    SeriesRegistry registry;
    seriesCore core;
    MockUSDC usdc;
    address allocator;
    address curator;
    address governance;
    uint256 maturityNonce;

    uint256 constant S = 700_000e6;
    uint256 constant J = 150_000e6;

    function setUp() public {
        registry = new SeriesRegistry();
        core = registry.realCore();
        usdc = registry.usdc();
        allocator = registry.ALLOCATOR();
        curator = registry.CURATOR();
        governance = registry.GOVERNANCE();

        usdc.mint(address(this), 2_000_000e6);
        usdcJuniorVault jv = registry.juniorVault();
        usdc.approve(address(jv), type(uint256).max);
        uint256 id = jv.requestDeposit(1_000_000e6, address(this), address(this));
        vm.prank(curator);
        jv.closeDepositEpoch();
        vm.prank(curator);
        jv.fulfillDeposit(id, 1_000_000e6);
        usdcSeniorVault sv = registry.seniorVault();
        usdc.approve(address(sv), type(uint256).max);
        sv.deposit(1_000_000e6, address(this));
    }

    function _valid() internal returns (SeriesParams memory p) {
        maturityNonce++;
        Market memory market = registry.marketFor(block.timestamp + 90 days + maturityNonce);
        registry.midnight().touchMarket(market);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = registry.idOf(market);
        uint256[] memory floors = new uint256[](1);
        floors[0] = 0.005e18;
        uint256[] memory caps = new uint256[](1);
        caps[0] = S + J;
        p = SeriesParams({
            marketIds: ids,
            tDeployEnd: uint64(block.timestamp + 2 days),
            dWriteOff: uint64(7 days),
            covWad: 0.15e18,
            pi0Wad: 0.1e18,
            piTWad: 0.2e18,
            pi1Wad: 0.35e18,
            rateFloorWad: floors,
            marketCapAssets: caps,
            kMinAssets: 50_000e6,
            thetaWad: 0.1e18,
            feeRecipient: registry.FEE_RECIPIENT(),
            allocator: allocator,
            parking: iParking(address(registry.parking())),
            offchainAttestationHash: bytes32(0)
        });
    }

    function _open(SeriesParams memory p) internal returns (address) {
        vm.prank(allocator);
        return core.openSeries(p, S, J);
    }

    function _expectOpenReverts(SeriesParams memory p, bytes4 selector) internal {
        vm.prank(allocator);
        vm.expectRevert(selector);
        core.openSeries(p, S, J);
    }

    function test_validParams_open_andSeriesCarriesCoreValues() public {
        creditSeries series = creditSeries(_open(_valid()));
        assertEq(address(series.PARKING()), address(core.PARKING()));
        assertEq(series.ALLOCATOR(), core.allocator());
        assertEq(series.FEE_RECIPIENT(), core.feeRecipient());
    }

    function test_attackerParking_reverts_andNothingMoves() public {
        address thief = makeAddr("thief");
        SeriesParams memory p = _valid();
        p.parking = iParking(address(new EvilParking(address(usdc), thief)));
        uint256 seniorBefore = core.seniorAssets();
        uint256 juniorBefore = core.juniorAssets();

        _expectOpenReverts(p, coreStorage.WrongParking.selector);

        assertEq(usdc.balanceOf(thief), 0, "no allocation may reach an allocator-chosen parking contract");
        assertEq(core.seniorAssets(), seniorBefore);
        assertEq(core.juniorAssets(), juniorBefore);
    }

    function test_wrongAllocator_reverts() public {
        SeriesParams memory p = _valid();
        p.allocator = makeAddr("otherAllocator");
        _expectOpenReverts(p, coreStorage.WrongAllocator.selector);
    }

    function test_wrongFeeRecipient_reverts() public {
        SeriesParams memory p = _valid();
        p.feeRecipient = makeAddr("otherFeeRecipient");
        _expectOpenReverts(p, coreStorage.WrongFeeRecipient.selector);
    }

    function test_pricingParamsOffPolicy_revert() public {
        SeriesParams memory p = _valid();
        p.covWad = 0.16e18;
        _expectOpenReverts(p, coreStorage.PolicyMismatch.selector);

        p = _valid();
        p.pi0Wad = 0.05e18;
        _expectOpenReverts(p, coreStorage.PolicyMismatch.selector);

        p = _valid();
        p.piTWad = 0.1e18;
        _expectOpenReverts(p, coreStorage.PolicyMismatch.selector);

        p = _valid();
        p.pi1Wad = 0.2e18;
        _expectOpenReverts(p, coreStorage.PolicyMismatch.selector);

        p = _valid();
        p.thetaWad = 0.2e18;
        _expectOpenReverts(p, coreStorage.PolicyMismatch.selector);
    }

    function test_rateFloorBelowCuratorMinimum_reverts() public {
        SeriesParams memory p = _valid();
        p.rateFloorWad[0] = 0.004e18;
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(coreStorage.RateFloorBelowMin.selector, 0));
        core.openSeries(p, S, J);
    }

    function test_kMinAboveCap_reverts() public {
        SeriesParams memory p = _valid();
        p.kMinAssets = S + J;
        _expectOpenReverts(p, coreStorage.KMinAboveCap.selector);
    }

    function test_writeOffDelay_bounds() public {
        SeriesParams memory p = _valid();
        p.dWriteOff = 0;
        _expectOpenReverts(p, coreStorage.WriteOffDelayOutOfRange.selector);

        p = _valid();
        p.dWriteOff = uint64(30 days) + 1;
        _expectOpenReverts(p, coreStorage.WriteOffDelayOutOfRange.selector);

        p = _valid();
        p.dWriteOff = uint64(1 days);
        _open(p);
    }

    function test_writeOffDelay_upperBoundInclusive() public {
        SeriesParams memory p = _valid();
        p.dWriteOff = uint64(30 days);
        _open(p);
    }

    function test_setFeeRecipient_onlyGovernance_nonZero() public {
        vm.expectRevert(coreStorage.NotGovernance.selector);
        core.setFeeRecipient(address(1));

        vm.prank(governance);
        vm.expectRevert(coreStorage.ZeroAddress.selector);
        core.setFeeRecipient(address(0));

        address next = makeAddr("nextFeeRecipient");
        vm.prank(governance);
        core.setFeeRecipient(next);
        assertEq(core.feeRecipient(), next);

        SeriesParams memory p = _valid();
        _expectOpenReverts(p, coreStorage.WrongFeeRecipient.selector);
        p.feeRecipient = next;
        _open(p);
    }

    function test_policyChange_movesTheBinding() public {
        vm.prank(curator);
        core.proposePolicyChange(keccak256("thetaWad"), 0.15e18);
        vm.warp(block.timestamp + core.CURATOR_TIMELOCK());
        core.executePolicyChange(keccak256("thetaWad"));

        SeriesParams memory p = _valid();
        _expectOpenReverts(p, coreStorage.PolicyMismatch.selector);
        p.thetaWad = 0.15e18;
        assertEq(creditSeries(_open(p)).THETA_WAD(), 0.15e18);
    }

    function test_maxKMinAssets_isATimelockedPolicyKey() public {
        vm.prank(curator);
        core.proposePolicyChange(keccak256("maxKMinAssets"), 10_000e6);
        vm.expectRevert(coreStorage.TimelockNotElapsed.selector);
        core.executePolicyChange(keccak256("maxKMinAssets"));

        vm.warp(block.timestamp + core.CURATOR_TIMELOCK());
        core.executePolicyChange(keccak256("maxKMinAssets"));
        assertEq(core.maxKMinAssets(), 10_000e6);

        SeriesParams memory p = _valid();
        _expectOpenReverts(p, coreStorage.KMinAboveCap.selector);
        p.kMinAssets = 10_000e6;
        _open(p);
    }
}
