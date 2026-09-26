// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: jrUSDC's exit claims: collecting filled exits as USDC from the core's reserved cash.
// @author adiii.eth

pragma solidity 0.8.34;

import {usdcJuniorRedeemQueue} from "./usdcJuniorRedeemQueue.sol";
import {wadMath} from "../../libraries/wadMath.sol";

abstract contract usdcJuniorRedeemClaims is usdcJuniorRedeemQueue {
    using wadMath for uint256;

    function redeem(uint256 shares, address receiver, address controller)
        external
        onlyControllerOrOperator(controller)
        returns (uint256 assets)
    {
        return _redeemClaim(shares, receiver, controller);
    }

    function withdraw(uint256 assets, address receiver, address controller)
        external
        onlyControllerOrOperator(controller)
        returns (uint256 shares)
    {
        uint256 requestId = activeRedeemRequestId[controller];
        require(requestId != 0, NoActiveRequest());

        uint256 claimable = claimableRedeemRequest(requestId, controller);
        uint256 owedAssetsTotal = _redeemOwedAssetsTotal(requestId, controller);
        require(assets > 0 && assets <= owedAssetsTotal, NothingToClaim());

        shares = owedAssetsTotal == assets ? claimable : assets.mulDivUp(claimable, owedAssetsTotal);
        require(shares <= claimable, NothingToClaim());

        claimedSharesOnRedeem[requestId][controller] += shares;
        claimedAssets[requestId][controller] += assets;
        _clearRedeemIfFullyResolved(requestId, controller);

        CORE.payFrom(false, receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function claimRedeem(uint256 epochId) external returns (uint256 assets) {
        epochId;
        uint256 requestId = activeRedeemRequestId[msg.sender];
        require(requestId != 0, NoActiveRequest());
        uint256 claimable = claimableRedeemRequest(requestId, msg.sender);
        require(claimable > 0, NothingToClaim());
        return _redeemClaim(claimable, msg.sender, msg.sender);
    }

    function _redeemClaim(uint256 shares, address receiver, address controller) internal returns (uint256 assets) {
        uint256 requestId = activeRedeemRequestId[controller];
        require(requestId != 0, NoActiveRequest());

        uint256 claimable = claimableRedeemRequest(requestId, controller);
        require(shares > 0 && shares <= claimable, NothingToClaim());

        uint256 owedAssetsTotal = _redeemOwedAssetsTotal(requestId, controller);
        assets = shares == claimable ? owedAssetsTotal : owedAssetsTotal.mulDivDown(shares, claimable);
        require(assets > 0, NothingToClaim());

        claimedSharesOnRedeem[requestId][controller] += shares;
        claimedAssets[requestId][controller] += assets;
        _clearRedeemIfFullyResolved(requestId, controller);

        CORE.payFrom(false, receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }
}
