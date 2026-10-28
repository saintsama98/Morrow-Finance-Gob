// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: jrUSDC, the junior first-loss USDC tranche vault: ERC-7540 batched entry and exit.
// @author adiii.eth

pragma solidity 0.8.34;

import {USDCVaultBase} from "../shared/USDCVaultBase.sol";
import {USDCJuniorRedeemCancels} from "./USDCJuniorRedeemCancels.sol";
import {SeriesCore} from "../../core/SeriesCore.sol";

/// @notice jrUSDC: batched deposits and exits.
contract USDCJuniorVault is USDCJuniorRedeemCancels {
    constructor(SeriesCore core_, address usdc_) USDCVaultBase(core_, usdc_, "Morrow Junior USDC", "jrUSDC") {}

    /// @notice ERC-165 interface check.
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0xce3bbe50 || interfaceId == 0x620ee8e4
            || interfaceId == 0xe3bc4e65 || interfaceId == 0x2f0a18c5 || interfaceId == 0x8bf840e3
            || interfaceId == 0xe76cffc7;
    }

    function _bookAssets() internal view override returns (uint256) {
        return CORE.juniorAssets();
    }
}
