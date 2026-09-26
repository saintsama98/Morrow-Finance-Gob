// SPDX-License-Identifier: BUSL-1.1
// Morrow Finance: what both USDC tranche vaults share: the share token, operators, pricing and common errors.
// @author adiii.eth

pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {seriesCore} from "../../core/seriesCore.sol";
import {wadMath} from "../../libraries/wadMath.sol";

abstract contract usdcVaultBase is ERC20, IERC165 {
    using wadMath for uint256;

    uint256 internal constant WAD = 1e18;
    uint8 internal constant DECIMALS_OFFSET = 12;

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

    modifier onlyOperator() {
        require(msg.sender == CORE.curator() || msg.sender == CORE.allocator(), NotOperator());
        _;
    }

    modifier onlyControllerOrOperator(address controller) {
        require(msg.sender == controller || isOperator[controller][msg.sender], NotControllerOrOperator());
        _;
    }

    constructor(seriesCore core_, address usdc_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        CORE = core_;
        USDC = usdc_;
    }

    function share() external view returns (address) {
        return address(this);
    }

    function asset() external view returns (address) {
        return USDC;
    }

    function setOperator(address operator, bool approved) external returns (bool success) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets.mulDivDown(totalSupply() + 10 ** DECIMALS_OFFSET, _bookAssets() + 1);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares.mulDivDown(_bookAssets() + 1, totalSupply() + 10 ** DECIMALS_OFFSET);
    }

    function pricePerShareWad() public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? 1e6 : _bookAssets().mulDivDown(WAD, supply);
    }

    function totalAssets() external view returns (uint256) {
        return _bookAssets();
    }

    function _convertToAssetsUp(uint256 shares) internal view returns (uint256) {
        return shares.mulDivUp(_bookAssets() + 1, totalSupply() + 10 ** DECIMALS_OFFSET);
    }

    function _bookAssets() internal view virtual returns (uint256);
}
