// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: jrUSDC, the junior first-loss USDC tranche vault: ERC-7540 batched entry and exit.
// @author adiii.eth

pragma solidity 0.8.34;

import {usdcVaultBase} from "../shared/usdcVaultBase.sol";
import {usdcJuniorRedeemCancels} from "./usdcJuniorRedeemCancels.sol";
import {seriesCore} from "../../core/seriesCore.sol";

contract usdcJuniorVault is usdcJuniorRedeemCancels {
    constructor(seriesCore core_, address usdc_) usdcVaultBase(core_, usdc_, "Morrow Junior USDC", "jrUSDC") {}

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0xce3bbe50 || interfaceId == 0x620ee8e4
            || interfaceId == 0xe3bc4e65 || interfaceId == 0x2f0a18c5 || interfaceId == 0x8bf840e3
            || interfaceId == 0xe76cffc7;
    }

    function _bookAssets() internal view override returns (uint256) {
        return CORE.juniorAssets();
    }
}
