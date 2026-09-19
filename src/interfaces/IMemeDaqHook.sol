// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

/// @title IMemeDaqHook
/// @notice Shared 1% quote-currency tax hook for every MemeDAQ PancakeSwap Infinity CL pool.
interface IMemeDaqHook {
    /// @notice Per-pool registration data. Storage layout: 3 slots.
    struct PoolInfo {
        address meme; // 0 = not registered
        uint8 rewardIndex; // index of this quote in the meme's reward list
        bool quoteIs0; // quote is currency0 (always true for native BNB)
        uint64 launchBlock; // block of registration (= launch block)
        uint160 edgeSqrtPriceX96; // start price = curve edge
        uint128 liability; // claims owed to the meme contract (holder dividends + creator fees)
        uint128 buybackOwed; // claims owed to the buyback contract
    }

    /// @notice Emitted on every taxed swap leg.
    /// @param id Pool id.
    /// @param meme Meme token of the pool.
    /// @param quote Taxed (quote) currency.
    /// @param fee Total tax charged, in quote wei.
    /// @param extra Part of `fee` above the base 1% (snipe tax, 100% buyback).
    /// @param inBefore True when charged in beforeSwap (quote is the specified side).
    event Tax(PoolId indexed id, address indexed meme, Currency quote, uint256 fee, uint256 extra, bool inBefore);
    /// @notice Emitted when the launchpad registers a pool.
    event Registered(
        PoolId indexed id, address indexed meme, Currency quote, uint8 rewardIndex, bool quoteIs0, uint160 edge
    );
    /// @notice Emitted when buys against a quote currency are paused or resumed.
    event BuyPausedSet(Currency indexed quote, bool paused);
    /// @notice Emitted when a meme pays dividends / creator fees out of the hook's claims.
    event Payout(PoolId indexed id, address indexed to, uint256 amount);
    /// @notice Emitted per pool when its buyback share is sent to the buyback contract.
    event BuybackCollected(PoolId indexed id, Currency indexed quote, uint256 amount);
    /// @notice Emitted once, when the buyback receiver is set.
    event BuybackSet(address indexed buyback);
    /// @notice Emitted when the spoke outflow cap of a quote currency changes.
    event OutflowCapSet(Currency indexed quote, uint16 capBps, uint32 window);

    error NotPoolManager();
    error NotLaunchpad();
    error NotVault();
    error NotMeme();
    error NotRegistered();
    error AlreadyRegistered();
    error BadKey();
    error BadStartPrice();
    error BuysPaused();
    error PastCurveEdge();
    error ExactOutUnfilled(uint256 got, uint256 need);
    error ExactInUnfilled(uint256 used, uint256 need);
    error InsufficientLiability();
    error BuybackNotSet();
    error BuybackAlreadySet();
    error ZeroAddress();
    error HookNotImplemented();
    error BadOutflowCap();
    error OutflowCapExceeded(uint256 used, uint256 cap);

    /// @notice Base tax in bps (1%).
    function TAX_BPS() external view returns (uint256);

    /// @notice The PancakeSwap Infinity Vault.
    function vault() external view returns (IVault);

    /// @notice The CLPoolManager.
    function poolManager() external view returns (ICLPoolManager);

    /// @notice The MemeDAQ launchpad (deployer of this hook).
    function launchpad() external view returns (address);

    /// @notice Receiver of buyback claims (set once).
    function buyback() external view returns (address);

    /// @notice Pool registration and accounting data.
    function poolInfo(PoolId id)
        external
        view
        returns (
            address meme,
            uint8 rewardIndex,
            bool quoteIs0,
            uint64 launchBlock,
            uint160 edgeSqrtPriceX96,
            uint128 liability,
            uint128 buybackOwed
        );

    /// @notice Taxed (quote) currency of a registered pool.
    function quoteOf(PoolId id) external view returns (Currency);

    /// @notice Whether buys (quote in) are paused for a quote currency.
    function buyPaused(Currency quote) external view returns (bool);

    /// @notice Spoke outflow cap of a quote currency: buys in each pool quoted in `quote` may take at most
    ///         `capBps` of the meme supply per `window` seconds (linear refill). capBps 0 = no cap.
    function outflowCap(Currency quote) external view returns (uint16 capBps, uint32 window);

    /// @notice Meme amount counted against pool `id`'s outflow cap right now (after refill).
    function outflowUsed(PoolId id) external view returns (uint256);

    /// @notice Tax rate that a swap from `sender` pays right now in pool `id` (snipe schedule included).
    function currentTaxBps(PoolId id, address sender) external view returns (uint256);

    /// @notice Registers a pool before the launchpad initializes it. Only launchpad.
    function register(PoolKey calldata key, address meme, uint8 rewardIndex, bool quoteIs0, uint160 edge) external;

    /// @notice Sets the buyback receiver, once. Only launchpad.
    function setBuyback(address buyback_) external;

    /// @notice Pauses/resumes buys against `quote` (sells always allowed). Only launchpad.
    function setBuyPaused(Currency quote, bool paused) external;

    /// @notice Sets the spoke outflow cap of a non-native quote currency (capBps 0 removes it). Only launchpad.
    function setOutflowCap(Currency quote, uint16 capBps, uint32 window) external;

    /// @notice Pays `amount` of pool `id`'s quote currency to `to`. Only the pool's meme token.
    function payout(PoolId id, address to, uint256 amount) external;

    /// @notice Sends the accrued buyback share of `ids` to the buyback contract. Permissionless.
    /// @return currencies Distinct currencies paid.
    /// @return amounts Amount paid per currency.
    function collectBuyback(PoolId[] calldata ids)
        external
        returns (Currency[] memory currencies, uint256[] memory amounts);
}
