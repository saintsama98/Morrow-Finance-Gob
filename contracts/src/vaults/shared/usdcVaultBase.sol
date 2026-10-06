// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: what both USDC tranche vaults share: the share token, operators, pricing and common errors.
// @author adiii.eth

pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {seriesCore} from "../../core/seriesCore.sol";
import {wadMath} from "../../libraries/wadMath.sol";

/// @notice Share token and pricing shared by both vaults; assets live in the core.
abstract contract usdcVaultBase is ERC20, IERC165 {
    using wadMath for uint256;

    uint256 internal constant WAD = 1e18;
    uint8 internal constant DECIMALS_OFFSET = 12;
    uint256 public constant MAX_EPOCH_DURATION = 7 days;
    uint256 public constant FILL_GRACE = 3 days;
    uint256 public constant CANCEL_AFTER_CLOSE = 14 days;

    error ZeroAssets();
    error ZeroShares();
    error DepositsPaused();
    error NotOperator();
    error EpochAlreadyClosed();
    error EpochNotClosed();
    error NothingToClaim();
    error NothingToCancel();
    error NotControllerOrOperator();
    error AsyncPreviewUnsupported();
    error RequestAlreadyActive();
    error NoActiveRequest();
    error PendingCancelation();
    error NotOldestBatch(uint256 oldest);

    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event OperatorSet(address indexed controller, address indexed operator, bool approved);
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );
    event RedeemFulfilled(uint256 indexed epochId, uint256 sharesFulfilled, uint256 assetsFulfilled, uint256 priceWad);
    event CancelRedeemRequest(address indexed controller, uint256 indexed requestId, address sender);
    event CancelRedeemClaimed(
        address indexed controller, address indexed receiver, uint256 indexed requestId, uint256 shares
    );

    seriesCore public immutable CORE;
    address public immutable USDC;

    mapping(address controller => mapping(address operator => bool)) public isOperator;

    modifier onlyControllerOrOperator(address controller) {
        require(msg.sender == controller || isOperator[controller][msg.sender], NotControllerOrOperator());
        _;
    }

    constructor(seriesCore core_, address usdc_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        CORE = core_;
        USDC = usdc_;
    }

    /// @notice Share token, which is this contract.
    function share() external view returns (address) {
        return address(this);
    }

    /// @notice Underlying asset, USDC.
    function asset() external view returns (address) {
        return USDC;
    }

    /// @notice Lets an operator act for the caller's requests.
    function setOperator(address operator, bool approved) external returns (bool success) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    /// @notice Shares for assets at the current price.
    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets.mulDivDown(totalSupply() + 10 ** DECIMALS_OFFSET, _bookAssets() + 1);
    }

    /// @notice Assets for shares at the current price.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares.mulDivDown(_bookAssets() + 1, totalSupply() + 10 ** DECIMALS_OFFSET);
    }

    /// @notice Current price of one share in assets.
    function pricePerShareWad() public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? 1e6 : _bookAssets().mulDivDown(WAD, supply);
    }

    /// @notice This vault's book in the core.
    function totalAssets() external view returns (uint256) {
        return _bookAssets();
    }

    function _convertToAssetsUp(uint256 shares) internal view returns (uint256) {
        return shares.mulDivUp(_bookAssets() + 1, totalSupply() + 10 ** DECIMALS_OFFSET);
    }

    function _isOperator() internal view returns (bool) {
        return msg.sender == CORE.curator() || msg.sender == CORE.allocator();
    }

    function _requireOperatorOrAfter(uint256 deadline) internal view {
        require(_isOperator() || block.timestamp >= deadline, NotOperator());
    }

    function _bookAssets() internal view virtual returns (uint256);
}
