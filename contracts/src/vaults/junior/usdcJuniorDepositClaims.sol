// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: jrUSDC's entry claims: collecting the shares minted for a filled deposit request.
// @author adiii.eth

pragma solidity 0.8.34;

import {usdcJuniorDepositQueue} from "./usdcJuniorDepositQueue.sol";
import {wadMath} from "../../libraries/wadMath.sol";

abstract contract usdcJuniorDepositClaims is usdcJuniorDepositQueue {
    using wadMath for uint256;

    function deposit(uint256 assets, address receiver, address controller)
        external
        onlyControllerOrOperator(controller)
        returns (uint256 shares)
    {
        return _depositClaim(assets, receiver, controller);
    }

    function mint(uint256 shares, address receiver, address controller)
        external
        onlyControllerOrOperator(controller)
        returns (uint256 assets)
    {
        uint256 requestId = activeDepositRequestId[controller];
        require(requestId != 0, NoActiveRequest());

        uint256 claimable = claimableDepositRequest(requestId, controller);
        uint256 owedSharesTotal = _depositOwedSharesTotal(requestId, controller);
        require(shares > 0 && shares <= owedSharesTotal, NothingToClaim());

        assets = owedSharesTotal == shares ? claimable : claimable.mulDivUp(shares, owedSharesTotal);
        require(assets <= claimable, NothingToClaim());

        claimedAssetsOnDeposit[requestId][controller] += assets;
        claimedShares[requestId][controller] += shares;
        _clearDepositIfFullyResolved(requestId, controller);

        _transfer(address(this), receiver, shares);
        emit Deposit(controller, receiver, assets, shares);
    }

    function claimDeposit(uint256 epochId) external returns (uint256 shares) {
        epochId;
        uint256 requestId = activeDepositRequestId[msg.sender];
        require(requestId != 0, NoActiveRequest());
        uint256 claimable = claimableDepositRequest(requestId, msg.sender);
        require(claimable > 0, NothingToClaim());
        return _depositClaim(claimable, msg.sender, msg.sender);
    }

    function _depositClaim(uint256 assets, address receiver, address controller) internal returns (uint256 shares) {
        uint256 requestId = activeDepositRequestId[controller];
        require(requestId != 0, NoActiveRequest());

        uint256 claimable = claimableDepositRequest(requestId, controller);
        require(assets > 0 && assets <= claimable, NothingToClaim());

        uint256 owedSharesTotal = _depositOwedSharesTotal(requestId, controller);
        shares = assets == claimable ? owedSharesTotal : owedSharesTotal.mulDivDown(assets, claimable);
        require(shares > 0, NothingToClaim());

        claimedAssetsOnDeposit[requestId][controller] += assets;
        claimedShares[requestId][controller] += shares;
        _clearDepositIfFullyResolved(requestId, controller);

        _transfer(address(this), receiver, shares);
        emit Deposit(controller, receiver, assets, shares);
    }
}
