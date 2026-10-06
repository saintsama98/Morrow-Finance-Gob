// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: srUSDC, the senior USDC tranche vault: instant ERC-4626 entry, ERC-7540 batched exit.
// @author adiii.eth

pragma solidity 0.8.34;

import {usdcVaultBase} from "../shared/usdcVaultBase.sol";
import {usdcSeniorRedeemCancels} from "./usdcSeniorRedeemCancels.sol";
import {seriesCore} from "../../core/seriesCore.sol";

/// @notice srUSDC: synchronous deposits, batched exits.
contract usdcSeniorVault is usdcSeniorRedeemCancels {
    constructor(seriesCore core_, address usdc_) usdcVaultBase(core_, usdc_, "Morrow Senior USDC", "srUSDC") {}

    /// @notice ERC-165 interface check.
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0xe3bc4e65 || interfaceId == 0x2f0a18c5
            || interfaceId == 0x620ee8e4 || interfaceId == 0xe76cffc7;
    }

    function _bookAssets() internal view override returns (uint256) {
        return CORE.seniorAssets();
    }
}
