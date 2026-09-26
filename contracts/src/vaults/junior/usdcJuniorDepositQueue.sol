// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: jrUSDC's entry batches: queued USDC held uninvested, batch close and fills at the higher price.
// @author adiii.eth

pragma solidity 0.8.34;

import {usdcVaultBase} from "../shared/usdcVaultBase.sol";
import {iErc20Like} from "../../interfaces/iErc20Like.sol";
import {wadMath} from "../../libraries/wadMath.sol";
import {epochMath} from "../../libraries/epochMath.sol";

abstract contract usdcJuniorDepositQueue is usdcVaultBase {
    using wadMath for uint256;

    event Deposit(address indexed controller, address indexed receiver, uint256 assets, uint256 shares);
    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );
    event DepositEpochClosed(uint256 indexed epochId, uint256 ppsCloseWad);
    event DepositFulfilled(uint256 indexed epochId, uint256 assetsFulfilled, uint256 sharesFulfilled, uint256 priceWad);

    struct DepositEpoch {
        uint256 totalAssetsRequested;
        uint256 remainingFillable;
        uint256 assetsFulfilled;
        uint256 sharesFulfilled;
        uint256 ppsCloseWad;
        bool closed;
    }

    uint256 public openDepositEpochId = 1;
    mapping(uint256 => DepositEpoch) public depositEpochs;
    mapping(uint256 => mapping(address => uint256)) public requestedAssets;
    mapping(uint256 => mapping(address => uint256)) public claimedShares;
    mapping(uint256 => mapping(address => uint256)) public claimedAssetsOnDeposit;
    mapping(uint256 => mapping(address => uint256)) public pendingCancelAssets;
    mapping(uint256 => mapping(address => uint256)) public claimedCancelAssets;
    mapping(address controller => uint256 requestId) public activeDepositRequestId;

    function maxDeposit(address) external pure returns (uint256) {
        return 0;
    }

    function maxMint(address) external pure returns (uint256) {
        return 0;
    }

    function previewDeposit(uint256) external pure returns (uint256) {
        revert AsyncPreviewUnsupported();
    }

    function previewMint(uint256) external pure returns (uint256) {
        revert AsyncPreviewUnsupported();
    }

    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId) {
        require(assets > 0, ZeroAssets());
        require(!CORE.paused(), DepositsPaused());
        require(activeDepositRequestId[controller] == 0, RequestAlreadyActive());
        require(msg.sender == owner || isOperator[owner][msg.sender], NotControllerOrOperator());

        requestId = openDepositEpochId;
        require(iErc20Like(USDC).transferFrom(owner, address(CORE), assets), "transfer failed");
        CORE.addPendingJunior(assets);
        requestedAssets[requestId][controller] += assets;
        depositEpochs[requestId].totalAssetsRequested += assets;
        depositEpochs[requestId].remainingFillable += assets;
        activeDepositRequestId[controller] = requestId;
        emit DepositRequest(controller, owner, requestId, msg.sender, assets);
    }

    function pendingDepositRequest(uint256 requestId, address controller) public view returns (uint256 assets) {
        return _depositRemainingUnfulfilled(requestId, controller);
    }

    function claimableDepositRequest(uint256 requestId, address controller) public view returns (uint256 assets) {
        return _depositEntitledAssetsTotal(requestId, controller) - claimedAssetsOnDeposit[requestId][controller];
    }

    function closeDepositEpoch() external onlyOperator returns (uint256 epochId) {
        epochId = openDepositEpochId;
        DepositEpoch storage e = depositEpochs[epochId];
        require(!e.closed, EpochAlreadyClosed());
        e.closed = true;
        e.ppsCloseWad = pricePerShareWad();
        openDepositEpochId = epochId + 1;
        emit DepositEpochClosed(epochId, e.ppsCloseWad);
    }

    function fulfillDeposit(uint256 epochId, uint256 assetsToInvest) external onlyOperator {
        DepositEpoch storage e = depositEpochs[epochId];
        require(e.closed, EpochNotClosed());

        uint256 assetsNow = assetsToInvest < e.remainingFillable ? assetsToInvest : e.remainingFillable;
        if (assetsNow == 0) return;

        uint256 priceWad = epochMath.depositPriceWad(e.ppsCloseWad, pricePerShareWad());
        uint256 sharesNow = epochMath.sharesForAssets(assetsNow, priceWad);

        CORE.investPendingJunior(assetsNow);
        _mint(address(this), sharesNow);

        e.remainingFillable -= assetsNow;
        e.assetsFulfilled += assetsNow;
        e.sharesFulfilled += sharesNow;
        emit DepositFulfilled(epochId, assetsNow, sharesNow, priceWad);
    }

    function _depositEntitledAssetsTotal(uint256 requestId, address controller) internal view returns (uint256) {
        DepositEpoch storage e = depositEpochs[requestId];
        if (e.totalAssetsRequested == 0) return 0;
        return requestedAssets[requestId][controller].mulDivDown(e.assetsFulfilled, e.totalAssetsRequested);
    }

    function _depositOwedSharesTotal(uint256 requestId, address controller) internal view returns (uint256) {
        DepositEpoch storage e = depositEpochs[requestId];
        return epochMath.claimableShares(
            requestedAssets[requestId][controller],
            e.sharesFulfilled,
            e.totalAssetsRequested,
            claimedShares[requestId][controller]
        );
    }

    function _depositRemainingUnfulfilled(uint256 requestId, address controller) internal view returns (uint256) {
        uint256 requested = requestedAssets[requestId][controller];
        uint256 entitled = _depositEntitledAssetsTotal(requestId, controller);
        uint256 canceled = pendingCancelAssets[requestId][controller] + claimedCancelAssets[requestId][controller];
        return requested - entitled - canceled;
    }

    function _clearDepositIfFullyResolved(uint256 requestId, address controller) internal {
        if (
            _depositRemainingUnfulfilled(requestId, controller) == 0
                && claimableDepositRequest(requestId, controller) == 0
                && pendingCancelAssets[requestId][controller] == 0
        ) {
            activeDepositRequestId[controller] = 0;
        }
    }
}
