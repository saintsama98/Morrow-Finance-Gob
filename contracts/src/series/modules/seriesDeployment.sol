// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: how a series lends: bid registration, Midnight's fill callback, direct takes and fill bounds.
// @author adiii.eth

pragma solidity 0.8.34;

import {Market, Offer} from "@morpho-org/midnight/src/interfaces/IMidnight.sol";
import {IdLib} from "@morpho-org/midnight/src/libraries/IdLib.sol";
import {HashLib} from "@morpho-org/midnight/src/ratifiers/libraries/HashLib.sol";
import {TickLib} from "@morpho-org/midnight/src/libraries/TickLib.sol";
import {ERC20Lib} from "@morpho-org/midnight/src/periphery/libraries/ERC20Lib.sol";
import {seriesMarks} from "./seriesMarks.sol";
import {iBuyCallback} from "../../interfaces/iBuyCallback.sol";
import {SeriesState} from "../../interfaces/iSeries.sol";
import {wadMath} from "../../libraries/wadMath.sol";

/// @notice Offers and fills on Midnight while the series is deploying.
abstract contract seriesDeployment is seriesMarks, iBuyCallback {
    using wadMath for uint256;

    /// @notice Highest tick the series will buy at in one market.
    function tickMaxFor(uint256 i) external view returns (uint256) {
        return _tickMax(i);
    }

    /// @notice Highest price the series will pay in one market.
    function priceMaxFor(uint256 i) external view returns (uint256) {
        return _priceMax(i);
    }

    /// @notice Ratifies a tree of buy offers for the deployment window.
    function registerOffers(bytes32 root, Offer[] calldata leaves)
        external
        onlyAllocator
        inState(SeriesState.DEPLOYING)
    {
        require(block.timestamp <= T_DEPLOY_END, TooLate(block.timestamp));

        bytes32 computedRoot = _computeRoot(leaves);
        require(computedRoot == root, InvalidTree());

        uint256 length = leaves.length;
        for (uint256 idx = 0; idx < length; idx++) {
            Offer calldata offer = leaves[idx];
            if (offer.maker != address(this)) continue;
            _validateSelfOffer(offer, idx);
        }

        rootRegistered[root] = true;
        SETTER_RATIFIER.setIsRootRatified(address(this), root, true);

        emit OffersRegistered(root, uint64(block.timestamp), length);
    }

    /// @notice Withdraws the ratification of an offer tree.
    function revokeOffers(bytes32 root) external onlyAllocator {
        SETTER_RATIFIER.setIsRootRatified(address(this), root, false);
        emit OffersRevoked(root);
    }

    /// @notice Marks an offer group as fully consumed so it cannot fill.
    function cancelGroup(bytes32 group) external onlyAllocator {
        MIDNIGHT.setConsumed(group, type(uint128).max, address(this));
    }

    /// @notice Midnight buy callback: checks price, caps and window, then funds the fill from parking.
    function onBuy(
        bytes32 id,
        Market memory,
        uint256 buyerAssets,
        uint256 units,
        uint256 pendingFeeIncrease,
        address buyer,
        bytes memory data
    ) external nonReentrant returns (bytes32) {
        require(msg.sender == address(MIDNIGHT), NotMidnight());
        require(buyer == address(this), NotSelfBuyer());

        if (units == 0 && buyerAssets == 0) return bytes32(keccak256("morpho.midnight.callbackSuccess"));

        require(
            state == SeriesState.DEPLOYING && block.timestamp <= T_DEPLOY_END, WrongState(SeriesState.DEPLOYING, state)
        );
        require(units > 0, ZeroUnits());

        uint256 i = abi.decode(data, (uint256));
        require(id == _marketIds[i], MarketMismatch(_marketIds[i], id));

        uint256 priceWad = buyerAssets.mulDivUp(wadMath.WAD, units);
        require(priceWad <= _priceMax(i), PriceFloorBreached(i, priceWad, _priceMax(i)));

        uint256 kAlloc = seniorAllocated + juniorAllocated;
        require(filled[i] + buyerAssets <= _marketCapAssets[i], CapExceeded(i));
        require(totalFilled + buyerAssets <= kAlloc, CapExceeded(i));

        PARKING.withdraw(buyerAssets, address(this));
        ERC20Lib.safeApprove(USDC, address(MIDNIGHT), buyerAssets);

        filled[i] += buyerAssets;
        unitsBought[i] += units;
        feeCrystallized[i] += pendingFeeIncrease;
        totalFilled += buyerAssets;

        emit Filled(i, buyerAssets, units, priceWad, true);
        return bytes32(keccak256("morpho.midnight.callbackSuccess"));
    }

    /// @notice Takes a borrower's sell offer within the series' price and caps.
    function deployTake(uint256 i, Offer calldata offer, bytes calldata ratifierData, uint256 units)
        external
        onlyAllocator
        nonReentrant
        inState(SeriesState.DEPLOYING)
    {
        require(block.timestamp <= T_DEPLOY_END, TooLate(block.timestamp));
        bytes32 id = _marketIds[i];
        require(IdLib.toId(offer.market) == id && !offer.buy, MarketMismatch(id, IdLib.toId(offer.market)));

        uint256 ttm = T > block.timestamp ? T - block.timestamp : 0;
        uint256 fee = MIDNIGHT.settlementFee(id, ttm);
        uint256 price = TickLib.tickToPrice(offer.tick);
        uint256 maxAssets = units.mulDivUp(price + fee, wadMath.WAD);

        uint256 kAlloc = seniorAllocated + juniorAllocated;
        require(filled[i] + maxAssets <= _marketCapAssets[i], CapExceeded(i));
        require(totalFilled + maxAssets <= kAlloc, CapExceeded(i));

        PARKING.withdraw(maxAssets, address(this));
        ERC20Lib.safeApprove(USDC, address(MIDNIGHT), maxAssets);

        (uint128 creditBefore, uint128 pendingFeeBefore,) = MIDNIGHT.updatePositionView(offer.market, id, address(this));
        (uint256 buyerAssets,) = MIDNIGHT.take(offer, ratifierData, units, address(this), address(0), address(0), "");
        (uint128 creditAfter, uint128 pendingFeeAfter,) = MIDNIGHT.updatePositionView(offer.market, id, address(this));

        require(uint256(creditAfter) - uint256(creditBefore) == units, UnitsMismatch());

        uint256 priceWad = buyerAssets.mulDivUp(wadMath.WAD, units);
        require(priceWad <= _priceMax(i), PriceFloorBreached(i, priceWad, _priceMax(i)));

        if (maxAssets > buyerAssets) {
            uint256 leftover = maxAssets - buyerAssets;
            ERC20Lib.safeApprove(USDC, address(PARKING), leftover);
            PARKING.deposit(leftover);
        }
        ERC20Lib.safeApprove(USDC, address(MIDNIGHT), 0);

        filled[i] += buyerAssets;
        unitsBought[i] += units;
        feeCrystallized[i] += uint256(pendingFeeAfter) - uint256(pendingFeeBefore);
        totalFilled += buyerAssets;

        emit Filled(i, buyerAssets, units, priceWad, false);
    }

    /// @notice Most the series can still pay into a market now.
    function buyerAssetsBound(bytes32, Market memory, address, bytes memory data) external view returns (uint256) {
        if (state != SeriesState.DEPLOYING || block.timestamp > T_DEPLOY_END) return 0;
        uint256 i = abi.decode(data, (uint256));
        if (i >= _marketIds.length) return 0;
        uint256 kAlloc = seniorAllocated + juniorAllocated;
        uint256 capLeft = _marketCapAssets[i] > filled[i] ? _marketCapAssets[i] - filled[i] : 0;
        uint256 allocLeft = kAlloc > totalFilled ? kAlloc - totalFilled : 0;
        uint256 liquid = PARKING.maxWithdraw(address(this));
        uint256 bound = capLeft < allocLeft ? capLeft : allocLeft;
        return bound < liquid ? bound : liquid;
    }

    function _priceMax(uint256 i) internal view returns (uint256) {
        return wadMath.WAD.mulDivDown(wadMath.WAD, wadMath.WAD + _rateFloorWad[i]);
    }

    function _tickMax(uint256 i) internal view returns (uint256 tickMax) {
        bytes32 id = _marketIds[i];
        (,,,,,,,,,,,, uint8 tickSpacing) = MIDNIGHT.marketState(id);
        uint256 pMax = _priceMax(i);
        uint256 candidate = TickLib.priceToTick(pMax, tickSpacing);
        if (candidate == 0) return 0;
        if (TickLib.tickToPrice(candidate) == pMax) return candidate;
        return candidate - tickSpacing;
    }

    function _validateSelfOffer(Offer calldata offer, uint256 leafIndex) internal view {
        uint256 i = _marketIndexOf(offer);
        require(offer.buy, InvalidLeaf(leafIndex));
        require(offer.expiry <= T_DEPLOY_END, InvalidLeaf(leafIndex));
        require(offer.callback == address(this), InvalidLeaf(leafIndex));
        require(offer.ratifier == address(SETTER_RATIFIER), InvalidLeaf(leafIndex));
        require(!offer.reduceOnly, InvalidLeaf(leafIndex));
        require(abi.decode(offer.callbackData, (uint256)) == i, InvalidLeaf(leafIndex));
        require(offer.tick <= _tickMax(i), PriceFloorBreached(i, offer.tick, _tickMax(i)));
    }

    function _marketIndexOf(Offer calldata offer) internal view returns (uint256) {
        bytes32 id = IdLib.toId(offer.market);
        uint256 length = _marketIds.length;
        for (uint256 i = 0; i < length; i++) {
            if (_marketIds[i] == id) return i;
        }
        revert MarketMismatch(bytes32(0), id);
    }

    function _computeRoot(Offer[] calldata leaves) internal pure returns (bytes32) {
        uint256 n = leaves.length;
        require(n > 0 && (n & (n - 1)) == 0 && n <= 64, InvalidTree());

        bytes32[] memory level = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            level[i] = HashLib.hashOffer(leaves[i]);
        }
        while (n > 1) {
            uint256 half = n / 2;
            for (uint256 i = 0; i < half; i++) {
                level[i] = HashLib.hashNode(level[2 * i], level[2 * i + 1]);
            }
            n = half;
        }
        return level[0];
    }
}
