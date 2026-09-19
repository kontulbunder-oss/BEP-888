// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Immutable four-asset, proportional reserve shares. No owner withdrawal, upgrade or rebalance.
/// Incoming transfer fees are measured, never credited as collateral. Extra deposits benefit all shares;
/// callers explicitly bound this surplus. Unsolicited donations are not included in the share price.
/// Losses are socialized before every operation; a zero reserve blocks deposits, not healthy-asset exits.
contract DidxBasket is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable initializer;
    address public constant LOCK = address(0xdead);
    uint256 public constant LOCKED_SHARES = 1e6;
    address[4] private _assets;
    uint256[4] private _reserves;
    error InvalidInput();
    error Slippage();
    error TransferBehavior();
    event Initialized(uint256[4] received, address indexed receiver);
    event Deposited(address indexed payer, address indexed receiver, uint256 shares, uint256[4] received);
    event Redeemed(address indexed payer, address indexed receiver, uint256 shares, uint256[4] received);

    constructor(address[4] memory assets_, address initializer_) ERC20("MemeDAQ Four Meme Basket", "dIDX") {
        if (initializer_ == address(0)) revert InvalidInput();
        initializer = initializer_;
        for (uint256 i; i < 4; ++i) {
            if (assets_[i].code.length == 0) revert InvalidInput();
            for (uint256 j; j < i; ++j) if (assets_[i] == assets_[j]) revert InvalidInput();
        }
        _assets = assets_;
    }

    function assets() external view returns (address[4] memory) { return _assets; }
    function accountedReserves() external view returns (uint256[4] memory) { return _reserves; }
    function reserves() public view returns (uint256[4] memory r) {
        for (uint256 i; i < 4; ++i) r[i] = Math.min(_reserves[i], IERC20(_assets[i]).balanceOf(address(this)));
    }

    function initialize(uint256[4] calldata amounts, address receiver, uint256 deadline) external nonReentrant {
        _validate(receiver, deadline);
        if (msg.sender != initializer || totalSupply() != 0) revert InvalidInput();
        uint256[4] memory received = _pull(amounts);
        for (uint256 i; i < 4; ++i) if (received[i] < 1e6) revert InvalidInput();
        _reserves = received;
        _mint(LOCK, LOCKED_SHARES);
        _mint(receiver, 1e18 - LOCKED_SHARES);
        emit Initialized(received, receiver);
    }

    /// @notice Required NET receipts, rounded up. Transfer-tax assets require larger gross inputs.
    function previewMint(uint256 shares) external view returns (uint256[4] memory amounts) {
        uint256 supply = totalSupply();
        if (supply == 0) revert InvalidInput();
        uint256[4] memory r = reserves();
        for (uint256 i; i < 4; ++i) amounts[i] = Math.mulDiv(shares, r[i], supply, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view returns (uint256[4] memory amounts) {
        uint256 supply = totalSupply();
        if (supply == 0 || shares > supply) revert InvalidInput();
        uint256[4] memory r = reserves();
        for (uint256 i; i < 4; ++i) amounts[i] = Math.mulDiv(shares, r[i], supply);
    }

    /// @param maxSurplusBps Maximum part of EACH receipt left as surplus for existing shares, <= 10%.
    function deposit(uint256[4] calldata amounts, uint256 minShares, uint16 maxSurplusBps, address receiver, uint256 deadline)
        external nonReentrant returns (uint256 shares)
    {
        _validate(receiver, deadline);
        uint256 supply = totalSupply();
        if (supply == 0 || maxSurplusBps > 1000 || minShares == 0) revert InvalidInput();
        uint256[4] memory r = reserves();
        for (uint256 i; i < 4; ++i) if (r[i] == 0) revert InvalidInput();
        uint256[4] memory received = _pull(amounts);
        shares = type(uint256).max;
        for (uint256 i; i < 4; ++i) shares = Math.min(shares, Math.mulDiv(received[i], supply, r[i]));
        if (shares < minShares) revert Slippage();
        for (uint256 i; i < 4; ++i) {
            uint256 required = Math.mulDiv(shares, r[i], supply, Math.Rounding.Ceil);
            if (received[i] - required > Math.mulDiv(received[i], maxSurplusBps, 10000)) revert Slippage();
            _reserves[i] = r[i] + received[i];
        }
        _mint(receiver, shares);
        emit Deposited(msg.sender, receiver, shares, received);
    }

    /// @notice Burns caller's shares. Limits apply to receiver's measured NET amounts after transfer tax.
    /// No oracle involved. A frozen token can revert the whole exit; no administrator can seize reserves.
    function redeem(uint256 shares, uint256[4] calldata minAmounts, address receiver, uint256 deadline)
        external nonReentrant returns (uint256[4] memory received)
    {
        _validate(receiver, deadline);
        if (shares == 0) revert InvalidInput();
        uint256[4] memory r = reserves();
        uint256 supply = totalSupply();
        _burn(msg.sender, shares);
        for (uint256 i; i < 4; ++i) {
            uint256 amount = Math.mulDiv(shares, r[i], supply);
            _reserves[i] = r[i] - amount;
            IERC20 token = IERC20(_assets[i]);
            uint256 beforeRecipient = token.balanceOf(receiver);
            uint256 beforeVault = token.balanceOf(address(this));
            if (amount != 0) token.safeTransfer(receiver, amount);
            if (token.balanceOf(address(this)) < beforeVault - amount) revert TransferBehavior();
            received[i] = token.balanceOf(receiver) - beforeRecipient;
            if (received[i] < minAmounts[i]) revert Slippage();
        }
        emit Redeemed(msg.sender, receiver, shares, received);
    }

    function _pull(uint256[4] calldata amounts) private returns (uint256[4] memory received) {
        for (uint256 i; i < 4; ++i) {
            if (amounts[i] == 0) revert InvalidInput();
            IERC20 token = IERC20(_assets[i]);
            uint256 beforeBalance = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), amounts[i]);
            received[i] = token.balanceOf(address(this)) - beforeBalance;
            if (received[i] == 0 || received[i] > amounts[i]) revert TransferBehavior();
        }
    }
    function _validate(address receiver, uint256 deadline) private view {
        if (receiver == address(0) || receiver == address(this) || block.timestamp > deadline) revert InvalidInput();
    }
}
