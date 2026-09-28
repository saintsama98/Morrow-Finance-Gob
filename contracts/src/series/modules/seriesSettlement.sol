// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: a series after it lends: collection, settlement, write-off, recoveries, payouts and the fee.
// @author adiii.eth

pragma solidity 0.8.34;

import {Market} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {ERC20Lib} from "@morpho-org/midnight/src/periphery/libraries/ERC20Lib.sol";
import {seriesFunding} from "./seriesFunding.sol";
import {iSeriesCoreMinimal} from "../../interfaces/iSeriesCoreMinimal.sol";
import {iErc20Like} from "../../interfaces/iErc20Like.sol";
import {SeriesState} from "../../interfaces/iSeries.sol";
import {seriesMath} from "../../libraries/seriesMath.sol";

abstract contract seriesSettlement is seriesFunding {
    function startSettlement() external inState(SeriesState.LOCKED) {
        require(block.timestamp >= T, TooEarly(block.timestamp));
        state = SeriesState.SETTLING;
        emit SettlementStarted();
    }

    function collect(uint256 i) external nonReentrant returns (uint256 received) {
        require(
            state == SeriesState.LOCKED || state == SeriesState.SETTLING || state == SeriesState.SETTLED,
            WrongState(SeriesState.SETTLING, state)
        );

        bytes32 id = _marketIds[i];
        Market memory m = _markets[i];

        MIDNIGHT.updatePosition(m, address(this));
        (uint128 credit,,) = MIDNIGHT.updatePositionView(m, id, address(this));
        uint128 withdrawableNow = MIDNIGHT.withdrawable(id);
        uint256 units = uint256(credit) < uint256(withdrawableNow) ? uint256(credit) : uint256(withdrawableNow);
        if (units == 0) return 0;

        uint256 balBefore = iErc20Like(USDC).balanceOf(address(this));
        MIDNIGHT.withdraw(m, units, address(this), address(this));
        received = iErc20Like(USDC).balanceOf(address(this)) - balBefore;
        require(received == units, TransferMismatch());

        collected[i] += received;
        ERC20Lib.safeApprove(USDC, address(PARKING), received);
        PARKING.deposit(received);

        (uint128 creditAfter,,) = MIDNIGHT.updatePositionView(m, id, address(this));
        if (block.timestamp > T && creditAfter == 0) resolved[i] = true;

        emit Collected(i, received, _proceeds(), resolved[i]);

        if (state == SeriesState.SETTLED) _rerunWaterfall();
    }

    function settle() external inState(SeriesState.SETTLING) {
        uint256 length = _marketIds.length;
        for (uint256 i = 0; i < length; i++) {
            require(resolved[i], NotResolved(i));
        }
        state = SeriesState.SETTLED;
        tSettled = block.timestamp;
        _rerunWaterfall();
        emit Settled(_proceeds());
    }

    function writeOff() external inState(SeriesState.SETTLING) {
        require(block.timestamp >= T + D_WRITE_OFF, TooEarly(block.timestamp));
        uint256 length = _marketIds.length;
        for (uint256 i = 0; i < length; i++) {
            if (!resolved[i]) writtenOff[i] = true;
        }
        state = SeriesState.SETTLED;
        tSettled = block.timestamp;
        _rerunWaterfall();
        emit WrittenOff(_proceeds());
    }

    function claimFee() external nonReentrant {
        uint256 owed = feeAccounted - feeClaimed;
        uint256 parked = PARKING.totalAssets(address(this));
        if (owed > parked) owed = parked;
        if (owed == 0) return;
        feeClaimed += owed;
        PARKING.withdraw(owed, FEE_RECIPIENT);
        emit FeeClaimed(owed);
    }

    function _proceeds() internal view returns (uint256) {
        return
            iErc20Like(USDC).balanceOf(address(this)) + PARKING.totalAssets(address(this)) + paidS + paidJ + feeClaimed;
    }

    function _rerunWaterfall() internal {
        _sweepRaw();
        uint256 p = _proceeds();
        uint256 xs;
        uint256 xj;
        uint256 fee;

        if (passThrough) {
            (xs, xj) = seriesMath.waterfallPassThrough(p, seniorDeployed, totalFilled);
        } else {
            (xs, xj, fee) = seriesMath.waterfall(p, seniorClaim, juniorDeployed, THETA_WAD);
        }

        uint256 dSenior = xs > paidS ? xs - paidS : 0;
        uint256 dJunior = xj > paidJ ? xj - paidJ : 0;
        uint256 dFee = fee > feeAccounted ? fee - feeAccounted : 0;

        paidS += dSenior;
        paidJ += dJunior;
        feeAccounted += dFee;

        emit Waterfall(p, xs, xj, fee, dSenior, dJunior);

        uint256 total = dSenior + dJunior;
        if (total > 0) PARKING.transferPosition(CORE, total);
        iSeriesCoreMinimal(CORE).receivePayout(dSenior, dJunior);
    }
}
