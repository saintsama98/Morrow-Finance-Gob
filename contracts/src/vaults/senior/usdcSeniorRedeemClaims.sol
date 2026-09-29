// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: srUSDC's claim side: collecting filled exits as USDC from the core's reserved cash.
// @author adiii.eth

pragma solidity 0.8.34;

import {usdcSeniorRedeemQueue} from "./usdcSeniorRedeemQueue.sol";
import {wadMath} from "../../libraries/wadMath.sol";

abstract contract usdcSeniorRedeemClaims is usdcSeniorRedeemQueue {
    using wadMath for uint256;

    function redeem(uint256 shares, address receiver, address controller)
        external
        onlyControllerOrOperator(controller)
        returns (uint256 assets)
    {
        return _redeem(shares, receiver, controller);
    }

    function withdraw(uint256 assets, address receiver, address controller)
        external
        onlyControllerOrOperator(controller)
        returns (uint256 shares)
    {
        uint256 requestId = activeRedeemRequestId[controller];
        require(requestId != 0, NoActiveRequest());

        uint256 claimable = claimableRedeemRequest(requestId, controller);
        uint256 owedAssetsTotal = _owedAssetsTotal(requestId, controller);
        require(assets > 0 && assets <= owedAssetsTotal, NothingToClaim());

        shares = owedAssetsTotal == assets ? claimable : assets.mulDivUp(claimable, owedAssetsTotal);
        require(shares <= claimable, NothingToClaim());

        claimedShares[requestId][controller] += shares;
        claimedAssets[requestId][controller] += assets;
        _clearIfFullyResolved(requestId, controller);

        CORE.payFrom(true, receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function claim(uint256 epochId) external returns (uint256 assets) {
        epochId;
        uint256 requestId = activeRedeemRequestId[msg.sender];
        require(requestId != 0, NoActiveRequest());
        uint256 claimable = claimableRedeemRequest(requestId, msg.sender);
        require(claimable > 0, NothingToClaim());
        return _redeem(claimable, msg.sender, msg.sender);
    }

    function _redeem(uint256 shares, address receiver, address controller) internal returns (uint256 assets) {
        uint256 requestId = activeRedeemRequestId[controller];
        require(requestId != 0, NoActiveRequest());

        uint256 claimable = claimableRedeemRequest(requestId, controller);
        require(shares > 0 && shares <= claimable, NothingToClaim());

        uint256 owedAssetsTotal = _owedAssetsTotal(requestId, controller);
        assets = shares == claimable ? owedAssetsTotal : owedAssetsTotal.mulDivDown(shares, claimable);
        require(assets > 0 || shares == claimable, NothingToClaim());

        claimedShares[requestId][controller] += shares;
        claimedAssets[requestId][controller] += assets;
        _clearIfFullyResolved(requestId, controller);

        CORE.payFrom(true, receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }
}
