// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {
    ICLHooks,
    HOOKS_BEFORE_INITIALIZE_OFFSET,
    HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET,
    HOOKS_BEFORE_SWAP_OFFSET,
    HOOKS_AFTER_SWAP_OFFSET,
    HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET
} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IMemeDaqHook} from "./interfaces/IMemeDaqHook.sol";
import {IMemeToken} from "./interfaces/IMemeToken.sol";

/// @title MemeDaqHook
/// @notice Shared tax hook of every MemeDAQ pool. Charges 1% (plus a decaying snipe tax right after launch) of the
///         gross quote leg in every swap mode, accrues it as Vault ERC6909 claims (`vault.mint`), and splits it into
///         creator 20% / holders 50% / buyback 30% of the base fee (snipe extra goes 100% to buyback).
/// @dev Bitmap 0x0CC5: beforeInitialize, beforeAddLiquidity, beforeSwap, afterSwap, beforeSwapReturnsDelta,
///      afterSwapReturnsDelta. Only the launchpad can initialize pools with this hook or add liquidity to them, and
///      no path ever removes liquidity. Strict guards (PastCurveEdge, ExactOutUnfilled) are always on.
///      Spoke circuit breaker: a non-native quote can carry an outflow cap that limits how much meme its pools sell
///      per time window, so a collapsed quote cannot empty a spoke in one transaction.
contract MemeDaqHook is IMemeDaqHook, ICLHooks, ILockCallback, ReentrancyGuardTransient {
    /// @inheritdoc IMemeDaqHook
    uint256 public constant override TAX_BPS = 100;
    uint256 public constant SNIPE_WINDOW_BLOCKS = 100;
    uint256 public constant SNIPE_START_BPS = 3_000;
    uint256 public constant CREATOR_SHARE_BPS = 2_000;
    uint256 public constant HOLDER_SHARE_BPS = 5_000;
    /// @notice Meme total supply (MemeToken.TOTAL_SUPPLY), the base of the outflow cap.
    uint256 public constant MEME_SUPPLY = 1_000_000_000e18;
    /// @notice Longest outflow-cap window.
    uint32 public constant MAX_OUTFLOW_WINDOW = 7 days;
    uint256 internal constant BPS = 10_000;

    struct OutflowCap {
        uint16 capBps;
        uint32 window;
    }

    struct Flow {
        uint64 updatedAt;
        uint128 used;
    }

    /// @inheritdoc IMemeDaqHook
    IVault public immutable override vault;
    /// @inheritdoc IMemeDaqHook
    ICLPoolManager public immutable override poolManager;
    /// @inheritdoc IMemeDaqHook
    address public immutable override launchpad;
    /// @inheritdoc IMemeDaqHook
    address public override buyback;

    /// @inheritdoc IMemeDaqHook
    mapping(PoolId => PoolInfo) public override poolInfo;
    /// @inheritdoc IMemeDaqHook
    mapping(PoolId => Currency) public override quoteOf;
    /// @inheritdoc IMemeDaqHook
    mapping(Currency => bool) public override buyPaused;
    /// @inheritdoc IMemeDaqHook
    mapping(Currency => OutflowCap) public override outflowCap;
    mapping(PoolId => Flow) internal _flow;

    /// @param vault_ PancakeSwap Infinity Vault.
    /// @param poolManager_ CLPoolManager.
    /// @param launchpad_ The MemeDAQ launchpad (deploys this hook in its constructor).
    constructor(IVault vault_, ICLPoolManager poolManager_, address launchpad_) {
        vault = vault_;
        poolManager = poolManager_;
        launchpad = launchpad_;
    }

    // ------------------------------------------------------------------
    // Launchpad-only configuration
    // ------------------------------------------------------------------

    /// @inheritdoc IMemeDaqHook
    function register(PoolKey calldata key, address meme, uint8 rewardIndex, bool quoteIs0, uint160 edge)
        external
        override
    {
        _onlyLaunchpad();
        if (address(key.hooks) != address(this) || meme == address(0)) revert BadKey();
        PoolId id = key.toId();
        PoolInfo storage info = poolInfo[id];
        if (info.meme != address(0)) revert AlreadyRegistered();
        info.meme = meme;
        info.rewardIndex = rewardIndex;
        info.quoteIs0 = quoteIs0;
        info.launchBlock = uint64(block.number);
        info.edgeSqrtPriceX96 = edge;
        Currency quote = quoteIs0 ? key.currency0 : key.currency1;
        if (!quote.isNative()) quoteOf[id] = quote;
        emit Registered(id, meme, quote, rewardIndex, quoteIs0, edge);
    }

    /// @inheritdoc IMemeDaqHook
    function setBuyback(address buyback_) external override {
        _onlyLaunchpad();
        if (buyback != address(0)) revert BuybackAlreadySet();
        if (buyback_ == address(0)) revert ZeroAddress();
        buyback = buyback_;
        emit BuybackSet(buyback_);
    }

    /// @inheritdoc IMemeDaqHook
    function setBuyPaused(Currency quote, bool paused) external override {
        _onlyLaunchpad();
        buyPaused[quote] = paused;
        emit BuyPausedSet(quote, paused);
    }

    /// @inheritdoc IMemeDaqHook
    function setOutflowCap(Currency quote, uint16 capBps, uint32 window) external override {
        _onlyLaunchpad();
        if (quote.isNative() || capBps > BPS || (capBps != 0 && (window == 0 || window > MAX_OUTFLOW_WINDOW))) {
            revert BadOutflowCap();
        }
        if (capBps == 0) window = 0;
        outflowCap[quote] = OutflowCap(capBps, window);
        emit OutflowCapSet(quote, capBps, window);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Hook permission bitmap (0x0CC5).
    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return uint16(
            (1 << HOOKS_BEFORE_INITIALIZE_OFFSET) | (1 << HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET)
                | (1 << HOOKS_BEFORE_SWAP_OFFSET) | (1 << HOOKS_AFTER_SWAP_OFFSET)
                | (1 << HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET) | (1 << HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET)
        );
    }

    /// @inheritdoc IMemeDaqHook
    function currentTaxBps(PoolId id, address sender) external view override returns (uint256) {
        return _taxBps(poolInfo[id].launchBlock, sender);
    }

    /// @inheritdoc IMemeDaqHook
    function outflowUsed(PoolId id) external view override returns (uint256) {
        OutflowCap memory cap = outflowCap[quoteOf[id]];
        if (cap.capBps == 0) return 0;
        return _refilled(_flow[id], cap, MEME_SUPPLY * cap.capBps / BPS);
    }

    // ------------------------------------------------------------------
    // Pool manager callbacks
    // ------------------------------------------------------------------

    /// @notice Only the launchpad may initialize a pool with this hook, and only a registered one at its edge price.
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        view
        override
        returns (bytes4)
    {
        _onlyPoolManager();
        if (sender != launchpad) revert NotLaunchpad();
        if (_registered(key.toId()).edgeSqrtPriceX96 != sqrtPriceX96) revert BadStartPrice();
        return this.beforeInitialize.selector;
    }

    /// @notice Only the launchpad may add liquidity (blocks untaxed range-order exits).
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        _onlyPoolManager();
        if (sender != launchpad) revert NotLaunchpad();
        return this.beforeAddLiquidity.selector;
    }

    /// @notice Charges the tax when the quote currency is the specified side (exact-in buy, exact-out sell).
    function beforeSwap(address sender, PoolKey calldata key, ICLPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _onlyPoolManager();
        PoolId id = key.toId();
        PoolInfo storage info = _registered(id);
        bool quoteIs0 = info.quoteIs0;
        Currency quote = quoteIs0 ? key.currency0 : key.currency1;
        // buy <=> quote is the input currency
        bool isBuy = params.zeroForOne == quoteIs0;
        if (isBuy && buyPaused[quote]) revert BuysPaused();
        bool exactIn = params.amountSpecified < 0;
        int128 specifiedDelta;
        if ((exactIn == params.zeroForOne) == quoteIs0) {
            uint256 bps = _taxBps(info.launchBlock, sender);
            uint256 abs = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 fee = _fee(abs, exactIn, bps);
            _accrue(id, info, quote, fee, bps, true, isBuy);
            specifiedDelta = int128(int256(fee));
        }
        return (this.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, 0), 0);
    }

    /// @notice Enforces the strict guards and charges the tax when the quote is the unspecified side
    ///         (exact-in sell, exact-out buy).
    function afterSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        _onlyPoolManager();
        PoolId id = key.toId();
        PoolInfo storage info = _registered(id);
        bool quoteIs0 = info.quoteIs0;
        {
            (uint160 sp,,,) = poolManager.getSlot0(id);
            uint160 edge = info.edgeSqrtPriceX96;
            // quote c0 => meme c1 => selling meme raises the price towards the edge
            if (quoteIs0 ? sp > edge : sp < edge) revert PastCurveEdge();
        }
        Currency quote = quoteIs0 ? key.currency0 : key.currency1;
        bool isBuy = params.zeroForOne == quoteIs0;
        if (isBuy && !quote.isNative()) {
            OutflowCap memory cap = outflowCap[quote];
            if (cap.capBps != 0) {
                int128 memeOut = quoteIs0 ? delta.amount1() : delta.amount0();
                _consumeOutflow(id, cap, memeOut > 0 ? uint256(uint128(memeOut)) : 0);
            }
        }
        bool exactIn = params.amountSpecified < 0;
        int128 q = quoteIs0 ? delta.amount0() : delta.amount1();
        uint256 bps = _taxBps(info.launchBlock, sender);
        if ((exactIn == params.zeroForOne) == quoteIs0) {
            // A fee on a specified quote amount is fair only if that amount was filled completely.
            // Revert the entire swap (including accrued fees/dividends) on a partial exact-in buy.
            if (exactIn) {
                uint256 abs = uint256(-params.amountSpecified);
                uint256 need = abs - _fee(abs, true, bps);
                uint256 used = q < 0 ? uint256(-int256(q)) : 0;
                if (used < need) revert ExactInUnfilled(used, need);
            } else {
                uint256 abs = uint256(params.amountSpecified);
                uint256 need = abs + _fee(abs, false, bps);
                uint256 got = q > 0 ? uint256(int256(q)) : 0;
                if (got < need) revert ExactOutUnfilled(got, need);
            }
            return (this.afterSwap.selector, 0);
        }
        uint256 a = q < 0 ? uint256(-int256(q)) : uint256(int256(q));
        uint256 fee = _fee(a, exactIn, bps);
        if (fee == 0) return (this.afterSwap.selector, 0);
        _accrue(id, info, quote, fee, bps, false, isBuy);
        return (this.afterSwap.selector, int128(int256(fee)));
    }

    // ------------------------------------------------------------------
    // Claims
    // ------------------------------------------------------------------

    /// @inheritdoc IMemeDaqHook
    function payout(PoolId id, address to, uint256 amount) external override nonReentrant {
        PoolInfo storage info = poolInfo[id];
        if (msg.sender != info.meme) revert NotMeme();
        if (amount == 0) return;
        uint256 liability = info.liability;
        if (amount > liability) revert InsufficientLiability();
        unchecked {
            info.liability = uint128(liability - amount);
        }
        Currency[] memory cs = new Currency[](1);
        uint256[] memory amounts = new uint256[](1);
        cs[0] = quoteOf[id];
        amounts[0] = amount;
        vault.lock(abi.encode(to, cs, amounts));
        emit Payout(id, to, amount);
    }

    /// @inheritdoc IMemeDaqHook
    function collectBuyback(PoolId[] calldata ids)
        external
        override
        nonReentrant
        returns (Currency[] memory currencies, uint256[] memory amounts)
    {
        address to = buyback;
        if (to == address(0)) revert BuybackNotSet();
        uint256 n = ids.length;
        currencies = new Currency[](n);
        amounts = new uint256[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            PoolInfo storage info = poolInfo[ids[i]];
            uint256 amt = info.buybackOwed;
            if (amt == 0) continue;
            info.buybackOwed = 0;
            Currency c = quoteOf[ids[i]];
            emit BuybackCollected(ids[i], c, amt);
            uint256 j;
            while (j < k && !(currencies[j] == c)) ++j;
            if (j == k) currencies[k++] = c;
            amounts[j] += amt;
        }
        assembly ("memory-safe") {
            mstore(currencies, k)
            mstore(amounts, k)
        }
        if (k != 0) vault.lock(abi.encode(to, currencies, amounts));
    }

    /// @notice Vault callback for payouts: burn own claims, take the currency to the receiver.
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(vault)) revert NotVault();
        (address to, Currency[] memory cs, uint256[] memory amounts) =
            abi.decode(data, (address, Currency[], uint256[]));
        for (uint256 i; i < cs.length; ++i) {
            vault.burn(address(this), cs[i], amounts[i]);
            vault.take(cs[i], to, amounts[i]);
        }
        return "";
    }

    // ------------------------------------------------------------------
    // Unused callbacks (not in the bitmap)
    // ------------------------------------------------------------------

    /// @notice Not used.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @notice Not used.
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @notice Not used.
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @notice Not used.
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @notice Not used.
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @notice Not used.
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _onlyPoolManager() internal view {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    function _onlyLaunchpad() internal view {
        if (msg.sender != launchpad) revert NotLaunchpad();
    }

    function _registered(PoolId id) internal view returns (PoolInfo storage info) {
        info = poolInfo[id];
        if (info.meme == address(0)) revert NotRegistered();
    }

    /// @dev tax(d) = 100 + (3000 - 100) * (W - d)^2 / W^2 for d < W; the launchpad (dev-buy) always pays 100.
    function _taxBps(uint256 launchBlock, address sender) internal view returns (uint256) {
        if (sender == launchpad) return TAX_BPS;
        uint256 d = block.number - launchBlock;
        if (d >= SNIPE_WINDOW_BLOCKS) return TAX_BPS;
        uint256 r = SNIPE_WINDOW_BLOCKS - d;
        return TAX_BPS + (SNIPE_START_BPS - TAX_BPS) * r * r / (SNIPE_WINDOW_BLOCKS * SNIPE_WINDOW_BLOCKS);
    }

    /// @dev Rounded up. exact-in: bps of the gross amount; exact-out: gross = net + fee, fee = bps of gross.
    function _fee(uint256 abs, bool exactIn, uint256 bps) internal pure returns (uint256) {
        uint256 d = exactIn ? BPS : BPS - bps;
        return (abs * bps + d - 1) / d;
    }

    /// @dev Leaky bucket: the used amount refills linearly, `limit` per `window`. Reverts past the cap.
    function _consumeOutflow(PoolId id, OutflowCap memory cap, uint256 memeOut) internal {
        uint256 limit = MEME_SUPPLY * cap.capBps / BPS;
        Flow storage f = _flow[id];
        uint256 used = _refilled(f, cap, limit) + memeOut;
        if (used > limit) revert OutflowCapExceeded(used, limit);
        f.updatedAt = uint64(block.timestamp);
        f.used = uint128(used);
    }

    function _refilled(Flow storage f, OutflowCap memory cap, uint256 limit) internal view returns (uint256) {
        uint256 used = f.used;
        if (used == 0) return 0;
        uint256 elapsed = block.timestamp - f.updatedAt;
        if (elapsed >= cap.window) return 0;
        uint256 refill = limit * elapsed / cap.window;
        return used > refill ? used - refill : 0;
    }

    function _accrue(
        PoolId id,
        PoolInfo storage info,
        Currency quote,
        uint256 fee,
        uint256 bps,
        bool inBefore,
        bool isBuy
    ) internal {
        vault.mint(address(this), quote, fee);
        uint256 base = fee * TAX_BPS / bps;
        uint256 creatorPart = base * CREATOR_SHARE_BPS / BPS;
        uint256 holderPart = base * HOLDER_SHARE_BPS / BPS;
        address meme = info.meme;
        // MemeToken.onTax is our own O(1) code; the catch is defence in depth so a swap can never be blocked.
        try IMemeToken(meme).onTax(info.rewardIndex, holderPart, creatorPart, isBuy) returns (bool distributed) {
            if (!distributed) holderPart = 0;
        } catch {
            holderPart = 0;
            creatorPart = 0;
        }
        uint256 owed = holderPart + creatorPart;
        info.liability += uint128(owed);
        info.buybackOwed += uint128(fee - owed);
        emit Tax(id, meme, quote, fee, fee - base, inBefore);
    }
}
