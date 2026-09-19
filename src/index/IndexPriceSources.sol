// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {IChainlinkFeed} from "../interfaces/IChainlinkFeed.sol";
import {IIndexPriceSource} from "./IIndexPriceSource.sol";

interface IIndexV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}
interface IIndexV2Factory { function getPair(address, address) external view returns (address); }
interface IIndexV3Factory { function getPool(address, address, uint24) external view returns (address); }
interface IIndexV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function observe(uint32[] calldata) external view returns (int56[] memory, uint160[] memory);
}

contract ChainlinkIndexSource is IIndexPriceSource {
    address public immutable baseToken;
    IChainlinkFeed public immutable feed;
    uint256 public immutable maxAge;
    uint256 private immutable scale;
    error InvalidPrice();

    constructor(address token, address feed_, uint256 maxAge_) {
        require(token.code.length != 0 && feed_.code.length != 0 && maxAge_ > 0 && maxAge_ <= 2 days, "bad source");
        baseToken = token;
        feed = IChainlinkFeed(feed_);
        uint8 d = feed.decimals();
        require(d <= 18, "feed decimals");
        scale = 10 ** (18 - d);
        maxAge = maxAge_;
    }

    function priceUsd() external view returns (uint256, uint256) {
        (uint80 round, int256 answer,, uint256 time, uint80 answered) = feed.latestRoundData();
        if (answer <= 0 || time == 0 || time > block.timestamp || block.timestamp - time > maxAge || answered < round) revert InvalidPrice();
        return (uint256(answer) * scale, time);
    }
    function update() external pure {}
}

/// @notice Immutable V3 TWAP path. Both current and harmonic mean liquidity must meet the deployment threshold.
contract V3IndexSource is IIndexPriceSource {
    address public immutable baseToken;
    IIndexV3Pool public immutable pool;
    IIndexPriceSource public immutable quoteSource;
    uint32 public immutable period;
    uint128 public immutable minLiquidity;
    uint256 private immutable baseScale;
    uint256 private immutable quoteScale;
    bool private immutable baseIs0;
    error InsufficientLiquidity();
    error InvalidPrice();

    constructor(address token, address pool_, address factory, IIndexPriceSource quoteSource_, uint32 period_, uint128 minLiquidity_) {
        pool = IIndexV3Pool(pool_);
        address t0 = pool.token0();
        address t1 = pool.token1();
        require((token == t0 || token == t1) && IIndexV3Factory(factory).getPool(t0, t1, pool.fee()) == pool_, "untrusted pool");
        address quote = token == t0 ? t1 : t0;
        require(quoteSource_.baseToken() == quote && period_ >= 30 minutes && period_ <= 1 days && minLiquidity_ > 0, "bad source");
        uint8 bd = IERC20Metadata(token).decimals();
        uint8 qd = IERC20Metadata(quote).decimals();
        require(bd <= 18 && qd <= 18, "token decimals");
        baseToken = token;
        baseIs0 = token == t0;
        baseScale = 10 ** bd;
        quoteScale = 10 ** qd;
        quoteSource = quoteSource_;
        period = period_;
        minLiquidity = minLiquidity_;
    }

    function priceUsd() external view returns (uint256 value, uint256 updatedAt) {
        if (pool.liquidity() < minLiquidity) revert InsufficientLiquidity();
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = period;
        (int56[] memory ticks, uint160[] memory spl) = pool.observe(secondsAgo);
        int56 delta;
        uint160 liquidityDelta;
        unchecked { delta = ticks[1] - ticks[0]; liquidityDelta = spl[1] - spl[0]; }
        if (liquidityDelta == 0 || FullMath.mulDiv(period, 1 << 128, liquidityDelta) < minLiquidity) revert InsufficientLiquidity();
        int56 mean = delta / int56(uint56(period));
        if (delta < 0 && delta % int56(uint56(period)) != 0) --mean;
        if (mean < TickMath.MIN_TICK || mean > TickMath.MAX_TICK) revert InvalidPrice();
        uint160 sqrt = TickMath.getSqrtRatioAtTick(int24(mean));
        uint256 rawQuote;
        if (sqrt <= type(uint128).max) {
            uint256 ratio = uint256(sqrt) * sqrt;
            rawQuote = baseIs0 ? FullMath.mulDiv(ratio, baseScale, 1 << 192) : FullMath.mulDiv(1 << 192, baseScale, ratio);
        } else {
            uint256 ratio = FullMath.mulDiv(sqrt, sqrt, 1 << 64);
            rawQuote = baseIs0 ? FullMath.mulDiv(ratio, baseScale, 1 << 128) : FullMath.mulDiv(1 << 128, baseScale, ratio);
        }
        (uint256 quoteUsd, uint256 time) = quoteSource.priceUsd();
        value = FullMath.mulDiv(rawQuote, quoteUsd, quoteScale);
        if (value == 0) revert InvalidPrice();
        return (value, time);
    }
    function update() external { quoteSource.update(); }
}

/// @notice V2 cumulative-price TWAP with two alternating observations. Anyone can checkpoint at most once per
///         period. A new source requires a full period of real chain time. Reads fail after maxWindow without
///         maintenance; they never fall back to spot prices. update() is permissionless and holds no funds.
contract V2IndexSource is IIndexPriceSource {
    struct Observation { uint256 cumulative; uint64 time; }
    address public immutable baseToken;
    IIndexV2Pair public immutable pair;
    IIndexPriceSource public immutable quoteSource;
    uint32 public immutable period;
    uint32 public immutable maxWindow;
    uint112 public immutable minQuoteReserve;
    bool private immutable baseIs0;
    uint256 private immutable baseScale;
    uint256 private immutable quoteScale;
    Observation[2] public observations;
    uint8 public newest;
    error ObservationUnavailable();
    error InsufficientLiquidity();
    error PriceDivergence();
    event ObservationWritten(uint256 cumulative, uint256 timestamp);

    constructor(address token, address pair_, address factory, IIndexPriceSource quoteSource_, uint32 period_, uint32 maxWindow_, uint112 minQuoteReserve_) {
        pair = IIndexV2Pair(pair_);
        address t0 = pair.token0();
        address t1 = pair.token1();
        require((token == t0 || token == t1) && IIndexV2Factory(factory).getPair(t0, t1) == pair_, "untrusted pair");
        address quote = token == t0 ? t1 : t0;
        require(quoteSource_.baseToken() == quote && period_ >= 30 minutes && maxWindow_ >= 2 * period_ && maxWindow_ <= 1 days && minQuoteReserve_ > 0, "bad source");
        uint8 bd = IERC20Metadata(token).decimals();
        uint8 qd = IERC20Metadata(quote).decimals();
        require(bd <= 18 && qd <= 18, "token decimals");
        baseToken = token;
        baseIs0 = token == t0;
        baseScale = 10 ** bd;
        quoteScale = 10 ** qd;
        quoteSource = quoteSource_;
        period = period_;
        maxWindow = maxWindow_;
        minQuoteReserve = minQuoteReserve_;
        (uint256 cumulative,) = _current();
        observations[0] = Observation(cumulative, uint64(block.timestamp));
    }

    function _current() internal view returns (uint256 cumulative, uint256 spotX112) {
        (uint112 r0, uint112 r1, uint32 time) = pair.getReserves();
        (uint112 base, uint112 quote) = baseIs0 ? (r0, r1) : (r1, r0);
        if (base == 0 || quote < minQuoteReserve) revert InsufficientLiquidity();
        spotX112 = (uint256(quote) << 112) / base;
        cumulative = baseIs0 ? pair.price0CumulativeLast() : pair.price1CumulativeLast();
        unchecked { cumulative += spotX112 * (uint32(block.timestamp) - time); }
    }

    function update() external {
        quoteSource.update();
        if (block.timestamp - observations[newest].time < period) return;
        (uint256 cumulative,) = _current();
        newest = 1 - newest;
        observations[newest] = Observation(cumulative, uint64(block.timestamp));
        emit ObservationWritten(cumulative, block.timestamp);
    }

    function priceUsd() external view returns (uint256 value, uint256 updatedAt) {
        Observation memory obs = observations[newest];
        if (block.timestamp - obs.time < period) obs = observations[1 - newest];
        if (obs.time == 0 || block.timestamp - obs.time < period || block.timestamp - obs.time > maxWindow) revert ObservationUnavailable();
        (uint256 cumulative, uint256 spot) = _current();
        uint256 delta;
        unchecked { delta = cumulative - obs.cumulative; }
        uint256 avg = delta / (block.timestamp - obs.time);
        // Reject a recently collapsed/depegged leg while its TWAP is still lagging. This can halt new launches.
        if (avg == 0 || spot < FullMath.mulDiv(avg, 8000, 10000) || spot > FullMath.mulDiv(avg, 12000, 10000)) revert PriceDivergence();
        uint256 rawQuote = FullMath.mulDiv(avg, baseScale, 1 << 112);
        (uint256 quoteUsd, uint256 time) = quoteSource.priceUsd();
        value = FullMath.mulDiv(rawQuote, quoteUsd, quoteScale);
        if (value == 0) revert ObservationUnavailable();
        return (value, time);
    }
}
