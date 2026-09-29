// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: jrUSDC's entry batches: queued USDC held uninvested, oldest-first fills at the higher price.
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
    uint256 public nextDepositEpochToFill = 1;
    mapping(uint256 => DepositEpoch) public depositEpochs;
    mapping(uint256 => uint256) public depositEpochOpenedAt;
    mapping(uint256 => uint256) public depositEpochClosedAt;
    mapping(uint256 => mapping(address => uint256)) public requestedAssets;
    mapping(uint256 => mapping(address => uint256)) public frozenDepositAssets;
    mapping(uint256 => mapping(address => uint256)) public frozenDepositShares;
    mapping(uint256 => mapping(address => uint256)) public claimedShares;
    mapping(uint256 => mapping(address => uint256)) public claimedAssetsOnDeposit;
    mapping(uint256 => mapping(address => uint256)) public pendingCancelAssets;
    mapping(uint256 => mapping(address => uint256)) public claimedCancelAssets;
    mapping(address controller => uint256 requestId) public activeDepositRequestId;

    constructor() {
        depositEpochOpenedAt[1] = block.timestamp;
    }

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
        require(msg.sender == controller || isOperator[controller][msg.sender], NotControllerOrOperator());

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

    function owedDepositShares(uint256 requestId, address controller) public view returns (uint256) {
        return _depositOwedSharesTotal(requestId, controller);
    }

    function closeDepositEpoch() external returns (uint256 epochId) {
        epochId = openDepositEpochId;
        _requireOperatorOrAfter(depositEpochOpenedAt[epochId] + MAX_EPOCH_DURATION);
        DepositEpoch storage e = depositEpochs[epochId];
        require(!e.closed, EpochAlreadyClosed());
        e.closed = true;
        e.ppsCloseWad = pricePerShareWad();
        depositEpochClosedAt[epochId] = block.timestamp;
        openDepositEpochId = epochId + 1;
        depositEpochOpenedAt[epochId + 1] = block.timestamp;
        emit DepositEpochClosed(epochId, e.ppsCloseWad);
    }

    function fulfillDeposit(uint256 epochId, uint256 assetsToInvest) external {
        DepositEpoch storage e = depositEpochs[epochId];
        require(e.closed, EpochNotClosed());
        _requireOperatorOrAfter(depositEpochClosedAt[epochId] + FILL_GRACE);
        uint256 oldest = _advanceDepositFillPointer();
        if (epochId < oldest) return;
        require(epochId == oldest, NotOldestBatch(oldest));

        uint256 assetsNow = assetsToInvest < e.remainingFillable ? assetsToInvest : e.remainingFillable;
        if (assetsNow == 0) return;

        uint256 priceWad = epochMath.depositPriceWad(e.ppsCloseWad, pricePerShareWad());
        uint256 sharesNow = epochMath.sharesForAssets(assetsNow, priceWad);

        e.remainingFillable -= assetsNow;
        e.assetsFulfilled += assetsNow;
        e.sharesFulfilled += sharesNow;
        _advanceDepositFillPointer();

        CORE.investPendingJunior(assetsNow);
        _mint(address(this), sharesNow);
        emit DepositFulfilled(epochId, assetsNow, sharesNow, priceWad);
    }

    function _advanceDepositFillPointer() internal returns (uint256 pointer) {
        pointer = nextDepositEpochToFill;
        while (pointer < openDepositEpochId && depositEpochs[pointer].remainingFillable == 0) {
            pointer++;
        }
        nextDepositEpochToFill = pointer;
    }

    function _detachDeposit(uint256 requestId, address controller) internal returns (uint256 unfilled) {
        DepositEpoch storage e = depositEpochs[requestId];
        uint256 requested = requestedAssets[requestId][controller];
        uint256 liveAssets = requested.mulDivDown(e.assetsFulfilled, e.totalAssetsRequested);
        uint256 liveShares = requested.mulDivDown(e.sharesFulfilled, e.totalAssetsRequested);
        unfilled = requested - liveAssets;

        frozenDepositAssets[requestId][controller] += liveAssets;
        frozenDepositShares[requestId][controller] += liveShares;
        requestedAssets[requestId][controller] = 0;

        e.totalAssetsRequested -= requested;
        e.assetsFulfilled -= liveAssets;
        e.sharesFulfilled -= liveShares;
        e.remainingFillable -= unfilled;
    }

    function _liveDepositAssets(uint256 requestId, address controller) internal view returns (uint256) {
        DepositEpoch storage e = depositEpochs[requestId];
        if (e.totalAssetsRequested == 0) return 0;
        return requestedAssets[requestId][controller].mulDivDown(e.assetsFulfilled, e.totalAssetsRequested);
    }

    function _depositEntitledAssetsTotal(uint256 requestId, address controller) internal view returns (uint256) {
        return frozenDepositAssets[requestId][controller] + _liveDepositAssets(requestId, controller);
    }

    function _depositOwedSharesTotal(uint256 requestId, address controller) internal view returns (uint256) {
        DepositEpoch storage e = depositEpochs[requestId];
        uint256 live = e.totalAssetsRequested == 0
            ? 0
            : requestedAssets[requestId][controller].mulDivDown(e.sharesFulfilled, e.totalAssetsRequested);
        uint256 entitled = frozenDepositShares[requestId][controller] + live;
        uint256 claimed = claimedShares[requestId][controller];
        return entitled > claimed ? entitled - claimed : 0;
    }

    function _depositRemainingUnfulfilled(uint256 requestId, address controller) internal view returns (uint256) {
        return requestedAssets[requestId][controller] - _liveDepositAssets(requestId, controller);
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
