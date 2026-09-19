// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";

/// @title StartPrice
/// @notice Equal-USD start ticks for MemeDAQ pools.
/// @dev Pool price is raw currency1 per raw currency0.
///      meme = currency1: P = quoteUsd * TOTAL_SUPPLY / (startFdvUsd * 10^quoteDecimals)
///      meme = currency0: P = startFdvUsd * 10^quoteDecimals / (quoteUsd * TOTAL_SUPPLY)
///      The tick is aligned to TICK_SPACING so that the meme start price is never below target:
///      meme c1 rounds the tick down, meme c0 rounds it up. Start FDV is in [target, target * 1.0001^200).
///      The pool is initialized exactly at the aligned tick, so the seeded range is single-sided either way.
library StartPrice {
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;
    int24 internal constant TICK_SPACING = 200;

    error PriceOutOfRange();

    /// @notice sqrt(num / den) as a Q64.96.
    function sqrtRatioX96(uint256 num, uint256 den) internal pure returns (uint256) {
        if (num / den < (1 << 64)) return Math.sqrt(FullMath.mulDiv(num, 1 << 192, den));
        return Math.sqrt(FullMath.mulDiv(num, 1 << 96, den)) << 48;
    }

    /// @notice Aligned start tick for a pool of a meme priced at `startFdvUsdE18` (whole supply) against a quote.
    /// @param startFdvUsdE18 Target fully diluted value in USD, 18 decimals.
    /// @param quoteUsdE18 Quote currency price in USD, 18 decimals (per whole token).
    /// @param quoteDecimals Quote currency decimals (<= 18).
    /// @param memeIs0 True when the meme is currency0 of the pool.
    function startTick(uint256 startFdvUsdE18, uint256 quoteUsdE18, uint8 quoteDecimals, bool memeIs0)
        internal
        pure
        returns (int24 tick)
    {
        if (startFdvUsdE18 == 0 || quoteUsdE18 == 0) revert PriceOutOfRange();
        uint256 scale = 10 ** uint256(quoteDecimals);
        uint256 sp = memeIs0
            ? sqrtRatioX96(startFdvUsdE18 * scale, quoteUsdE18 * TOTAL_SUPPLY)
            : sqrtRatioX96(quoteUsdE18 * TOTAL_SUPPLY, startFdvUsdE18 * scale);
        if (sp < TickMath.MIN_SQRT_RATIO || sp >= TickMath.MAX_SQRT_RATIO) revert PriceOutOfRange();
        int24 t = TickMath.getTickAtSqrtRatio(uint160(sp));
        tick = (t / TICK_SPACING) * TICK_SPACING;
        if (t < 0 && tick != t) tick -= TICK_SPACING; // floor
        if (memeIs0 && TickMath.getSqrtRatioAtTick(tick) < sp) tick += TICK_SPACING; // ceil
        if (tick <= TickMath.minUsableTick(TICK_SPACING) || tick >= TickMath.maxUsableTick(TICK_SPACING)) {
            revert PriceOutOfRange();
        }
    }
}
