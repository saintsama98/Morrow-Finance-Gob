// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: each book's proportional claim on the core's single parking account: mint, burn, value, deposit.
// @author adiii.eth

pragma solidity 0.8.34;

import {coreStorage} from "./coreStorage.sol";
import {iErc20Like} from "../../interfaces/iErc20Like.sol";
import {wadMath} from "../../libraries/wadMath.sol";

abstract contract coreParkingBooks is coreStorage {
    using wadMath for uint256;

    function idle(bool isSenior) public view returns (uint256) {
        return _claimValue(isSenior ? senior.parkingClaims : junior.parkingClaims, _parked());
    }

    function parkingLiquidity() public view returns (uint256) {
        return PARKING.maxWithdraw(address(this));
    }

    function _parked() internal view returns (uint256) {
        return PARKING.totalAssets(address(this));
    }

    function _claimsFor(uint256 assets, uint256 parkedBefore) internal view returns (uint256) {
        return assets.mulDivDown(totalParkingClaims + VIRTUAL_CLAIMS, parkedBefore + 1);
    }

    function _claimValue(uint256 claims, uint256 parked) internal view returns (uint256) {
        return claims.mulDivDown(parked + 1, totalParkingClaims + VIRTUAL_CLAIMS);
    }

    function _addToBook(bool isSenior, uint256 assets, uint256 parkedBefore) internal {
        uint256 claims = _claimsFor(assets, parkedBefore);
        if (isSenior) senior.parkingClaims += claims;
        else junior.parkingClaims += claims;
        totalParkingClaims += claims;
    }

    function _removeFromBooks(uint256 fromSenior, uint256 fromJunior) internal {
        uint256 parked = _parked();
        uint256 claimsSenior = fromSenior.mulDivUp(totalParkingClaims + VIRTUAL_CLAIMS, parked + 1);
        uint256 claimsJunior = fromJunior.mulDivUp(totalParkingClaims + VIRTUAL_CLAIMS, parked + 1);
        require(
            claimsSenior <= senior.parkingClaims,
            IdleInsufficient(true, fromSenior, _claimValue(senior.parkingClaims, parked))
        );
        require(
            claimsJunior <= junior.parkingClaims,
            IdleInsufficient(false, fromJunior, _claimValue(junior.parkingClaims, parked))
        );
        senior.parkingClaims -= claimsSenior;
        junior.parkingClaims -= claimsJunior;
        totalParkingClaims -= claimsSenior + claimsJunior;
    }

    function _depositToBook(bool isSenior, uint256 assets) internal {
        uint256 before = _parked();
        require(iErc20Like(USDC).approve(address(PARKING), assets), "approve failed");
        PARKING.deposit(assets);
        uint256 afterDeposit = _parked();
        _addToBook(isSenior, afterDeposit > before ? afterDeposit - before : 0, before);
    }

    function _creditBooks(uint256 toSenior, uint256 toJunior) internal {
        uint256 total = toSenior + toJunior;
        if (total == 0) return;
        uint256 parkedAfter = _parked();
        uint256 parkedBefore = parkedAfter > total ? parkedAfter - total : 0;
        uint256 claimsSenior = _claimsFor(toSenior, parkedBefore);
        uint256 claimsJunior = _claimsFor(toJunior, parkedBefore);
        senior.parkingClaims += claimsSenior;
        junior.parkingClaims += claimsJunior;
        totalParkingClaims += claimsSenior + claimsJunior;
    }
}
