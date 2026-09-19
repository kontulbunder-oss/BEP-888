// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DidxBasket} from "./DidxBasket.sol";
import {IMemeDaqRouter} from "../interfaces/IMemeDaqRouter.sol";

interface IDidxAssetGateway {
    function basket() external view returns (DidxBasket);
    function memeRouter() external view returns (IMemeDaqRouter);
    function legCount() external view returns (uint256);
    function buyAssets(uint256[4] calldata, uint256[] calldata, address, uint256)
        external payable returns (uint256[4] memory, uint256[] memory);
}

/// @notice BNB buys all four reserves in one transaction. Deposit only the proportional quantities;
/// return unused native value and excess component tokens to the payer, not to another recipient.
/// The existing basket stays immutable. Tax on transfers INTO the basket fails atomically rather
/// than silently donating unmatched receipts. Taxes on DEX purchases are measured by the gateway.
contract DidxRefundGateway is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IDidxAssetGateway public immutable purchaseGateway;
    DidxBasket public immutable basket;
    IMemeDaqRouter public immutable memeRouter;
    uint256 public immutable legCount;

    error InvalidInput();
    error Slippage();
    error TransferBehavior();
    error RefundFailed();
    event MintedFromBnb(address indexed payer, address indexed receiver, uint256 bnbSpent, uint256 shares, address meme, uint256 memeOut);
    event Refunded(address indexed payer, uint256 bnb, uint256[4] tokenNetAmounts);

    constructor(IDidxAssetGateway source) {
        if (address(source).code.length == 0) revert InvalidInput();
        purchaseGateway = source; basket = source.basket(); memeRouter = source.memeRouter(); legCount = source.legCount();
        if (address(basket).code.length == 0 || address(memeRouter).code.length == 0 || legCount == 0) revert InvalidInput();
    }

    /// @notice A quote/acquisition interface with the same leading return fields as the purchase gateway.
    function buyAssets(uint256[4] calldata budgets, uint256[] calldata limits, address receiver, uint256 deadline)
        external payable nonReentrant returns (uint256[4] memory amounts, uint256[] memory legs)
    {
        _validate(receiver, deadline, limits.length);
        uint256 spent = _budget(budgets);
        address[4] memory assets = basket.assets();
        uint256[4] memory beforeAmounts = _balances(assets);
        (, legs) = purchaseGateway.buyAssets{value: spent}(budgets, limits, address(this), deadline);
        amounts = _returnAssets(assets, beforeAmounts, receiver);
        _refundNative(msg.value - spent);
    }

    /// @notice No component approvals or pre-purchases required from the user. Extra return fields
    /// expose actual refunds in eth_call previews; the first three remain ABI-compatible with V1.
    function mintFromBnb(uint256[4] calldata budgets, uint256[] calldata limits, uint256 minShares,
        uint16 maxSurplusBps, address meme, uint256 minMemeOut, address receiver, uint256 deadline)
        external payable nonReentrant returns (uint256 shares, uint256 memeOut, uint256[] memory legs,
            uint256[4] memory tokenRefunds, uint256 bnbRefund)
    {
        _validate(receiver, deadline, limits.length);
        if (minShares == 0 || maxSurplusBps > 1000) revert InvalidInput();
        uint256 spent = _budget(budgets);
        address[4] memory assets = basket.assets();
        uint256[4] memory beforeAmounts = _balances(assets);
        (, legs) = purchaseGateway.buyAssets{value: spent}(budgets, limits, address(this), deadline);
        uint256[4] memory reserves = basket.reserves();
        uint256 supply = basket.totalSupply();
        if (supply == 0) revert InvalidInput();
        uint256 target = type(uint256).max;
        for (uint256 i; i < 4; ++i) {
            if (reserves[i] == 0) revert InvalidInput();
            uint256 acquired = IERC20(assets[i]).balanceOf(address(this)) - beforeAmounts[i];
            target = Math.min(target, Math.mulDiv(acquired, supply, reserves[i]));
        }
        if (target < minShares) revert Slippage();
        uint256[4] memory depositAmounts;
        for (uint256 i; i < 4; ++i) {
            depositAmounts[i] = Math.mulDiv(target, reserves[i], supply, Math.Rounding.Ceil);
            IERC20(assets[i]).forceApprove(address(basket), depositAmounts[i]);
        }
        // Zero surplus: any incompatible transfer tax/behaviour rolls back every purchase.
        shares = basket.deposit(depositAmounts, target, 0, address(this), deadline);
        if (shares != target) revert TransferBehavior();
        for (uint256 i; i < 4; ++i) IERC20(assets[i]).forceApprove(address(basket), 0);
        if (meme == address(0)) IERC20(address(basket)).safeTransfer(receiver, shares);
        else {
            if (minMemeOut == 0) revert InvalidInput();
            IERC20(address(basket)).forceApprove(address(memeRouter), shares);
            memeOut = memeRouter.buy(meme, address(basket), shares, minMemeOut, receiver, deadline);
            IERC20(address(basket)).forceApprove(address(memeRouter), 0);
        }
        tokenRefunds = _returnAssets(assets, beforeAmounts, msg.sender);
        bnbRefund = msg.value - spent;
        _refundNative(bnbRefund);
        emit MintedFromBnb(msg.sender, receiver, spent, shares, meme, memeOut);
        emit Refunded(msg.sender, bnbRefund, tokenRefunds);
    }

    function _balances(address[4] memory assets) private view returns (uint256[4] memory amounts) {
        for (uint256 i; i < 4; ++i) amounts[i] = IERC20(assets[i]).balanceOf(address(this));
    }
    function _returnAssets(address[4] memory assets, uint256[4] memory baseline, address receiver)
        private returns (uint256[4] memory net)
    {
        for (uint256 i; i < 4; ++i) {
            IERC20 token = IERC20(assets[i]);
            uint256 extra = token.balanceOf(address(this)) - baseline[i];
            if (extra > 0) {
                uint256 beforeRecipient = token.balanceOf(receiver);
                token.safeTransfer(receiver, extra);
                net[i] = token.balanceOf(receiver) - beforeRecipient;
            }
            if (token.balanceOf(address(this)) != baseline[i]) revert TransferBehavior();
        }
    }
    function _budget(uint256[4] calldata budgets) private view returns (uint256 sum) {
        for (uint256 i; i < 4; ++i) { if (budgets[i] == 0) revert InvalidInput(); sum += budgets[i]; }
        if (sum > msg.value) revert InvalidInput();
    }
    function _refundNative(uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert RefundFailed();
    }
    function _validate(address receiver, uint256 deadline, uint256 count) private view {
        if (receiver == address(0) || receiver == address(this) || block.timestamp > deadline || count != legCount) revert InvalidInput();
    }
}
