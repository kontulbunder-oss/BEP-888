// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {IMemeDaqRouter} from "./interfaces/IMemeDaqRouter.sol";
import {IMemeDaqLaunchpad} from "./interfaces/IMemeDaqLaunchpad.sol";

/// @title MemeDaqRouter
/// @notice Stateless exact-in router for MemeDAQ pools, used by the website and the reserve vault.
///         Pays the Vault first (so a seller's balance drops before the tax is distributed), swaps with the widest
///         price limit, sends the output to `to` and refunds any unconsumed input (partial fill) to the payer.
///         Tokens never rest in this contract.
contract MemeDaqRouter is IMemeDaqRouter, ILockCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @dev keccak256("memedaq.router.payer") - 1
    bytes32 private constant PAYER_SLOT = 0x7b3d3fcdf5ed7dabcf6dd2e5739a4bbb1c624a05549366dce6fab97553988f39;

    /// @notice PancakeSwap Infinity Vault.
    IVault public immutable vault;
    /// @notice CLPoolManager.
    ICLPoolManager public immutable poolManager;
    /// @notice MemeDAQ launchpad (canonical pool keys).
    IMemeDaqLaunchpad public immutable launchpad;

    struct SwapData {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        address to;
    }

    /// @param vault_ PancakeSwap Infinity Vault.
    /// @param poolManager_ CLPoolManager.
    /// @param launchpad_ MemeDAQ launchpad.
    constructor(IVault vault_, ICLPoolManager poolManager_, IMemeDaqLaunchpad launchpad_) {
        vault = vault_;
        poolManager = poolManager_;
        launchpad = launchpad_;
    }

    /// @inheritdoc IMemeDaqRouter
    function buy(address meme, address quote, uint256 amountIn, uint256 minOut, address to, uint256 deadline)
        external
        payable
        override
        nonReentrant
        returns (uint256 out)
    {
        if (msg.value != (quote == address(0) ? amountIn : 0)) revert BadValue();
        out = _trade(meme, quote, true, amountIn, minOut, to, deadline);
    }

    /// @inheritdoc IMemeDaqRouter
    function sell(address meme, address quote, uint256 amountIn, uint256 minOut, address to, uint256 deadline)
        external
        override
        nonReentrant
        returns (uint256 out)
    {
        out = _trade(meme, quote, false, amountIn, minOut, to, deadline);
    }

    /// @notice Vault callback: pay, swap exact-in, take output, refund unconsumed input.
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(vault)) revert NotVault();
        SwapData memory s = abi.decode(data, (SwapData));
        address payer;
        assembly ("memory-safe") {
            payer := tload(PAYER_SLOT)
        }
        (Currency cin, Currency cout) =
            s.zeroForOne ? (s.key.currency0, s.key.currency1) : (s.key.currency1, s.key.currency0);

        uint256 paid;
        if (cin.isNative()) {
            paid = vault.settle{value: s.amountIn}();
        } else {
            vault.sync(cin);
            IERC20(Currency.unwrap(cin)).safeTransferFrom(payer, address(vault), s.amountIn);
            paid = vault.settle();
        }

        BalanceDelta d = poolManager.swap(
            s.key,
            ICLPoolManager.SwapParams({
                zeroForOne: s.zeroForOne,
                amountSpecified: -int256(paid),
                sqrtPriceLimitX96: s.zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            ""
        );
        (int128 dIn, int128 dOut) = s.zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());

        uint256 out = dOut > 0 ? uint256(int256(dOut)) : 0;
        if (out != 0) {
            if (cout.isNative()) vault.take(cout, s.to, out);
            else {
                IERC20 outputToken = IERC20(Currency.unwrap(cout));
                uint256 beforeBalance = outputToken.balanceOf(s.to);
                vault.take(cout, s.to, out);
                uint256 afterBalance = outputToken.balanceOf(s.to);
                out = afterBalance > beforeBalance ? afterBalance - beforeBalance : 0;
            }
        }
        uint256 used = dIn < 0 ? uint256(-int256(dIn)) : 0;
        if (paid > used) vault.take(cin, payer, paid - used);

        if (vault.currencyDelta(address(this), cin) != 0 || vault.currencyDelta(address(this), cout) != 0) {
            revert Unsettled();
        }
        return abi.encode(out);
    }

    function _trade(
        address meme,
        address quote,
        bool isBuy,
        uint256 amountIn,
        uint256 minOut,
        address to,
        uint256 deadline
    ) internal returns (uint256 out) {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0 || amountIn > uint256(uint128(type(int128).max))) revert BadAmount();
        if (to == address(0)) revert BadRecipient();
        (PoolKey memory key, bool memeIs0) = launchpad.poolKeyOf(meme, quote);
        // buy: quote in; zeroForOne when quote is currency0 (meme is currency1)
        bool zeroForOne = isBuy ? !memeIs0 : memeIs0;
        address payer = msg.sender;
        assembly ("memory-safe") {
            tstore(PAYER_SLOT, payer)
        }
        out = abi.decode(vault.lock(abi.encode(SwapData(key, zeroForOne, amountIn, to))), (uint256));
        assembly ("memory-safe") {
            tstore(PAYER_SLOT, 0)
        }
        if (out < minOut) revert TooLittleReceived(out, minOut);
        emit Trade(meme, msg.sender, quote, isBuy, amountIn, out);
    }
}
