// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";

/// @title IMemeDaqLaunchpad
/// @notice One-tx meme launch into 1-4 single-sided PancakeSwap Infinity CL pools, plus the registry the website reads.
interface IMemeDaqLaunchpad {
    enum PriceSource {
        NONE,
        CHAINLINK,
        USD_PEG,
        MANUAL
    }

    /// @notice Whitelisted quote currency configuration. Key = currency address, address(0) = BNB (the only hub).
    struct QuoteConfig {
        bool enabled;
        bool isHub;
        uint8 decimals;
        PriceSource source;
        uint16 maxWeightBps;
        uint32 maxAge; // oracle staleness bound (s)
        address feed; // CHAINLINK
        uint128 manualPriceUsdE18; // MANUAL
        uint64 manualUpdatedAt; // MANUAL
    }

    struct QuoteAlloc {
        address currency;
        uint16 weightBps;
    }

    struct LaunchParams {
        string name;
        string symbol;
        string meta;
        bytes32 salt; // user salt; real salt = keccak256(abi.encode(msg.sender, salt))
        QuoteAlloc[] quotes; // 1..4, unique, enabled; exactly one hub (BNB) >= minHubWeightBps; each <= maxWeightBps; sum 10000
        uint256 devBuyBnb; // optional; msg.value == launchFee + devBuyBnb
        uint256 devBuyMinOut;
    }

    struct MemeView {
        address meme;
        address creator; // the launcher (fee rights may since have moved: read IMemeToken.creator())
        uint64 createdAt;
        uint64 launchBlock;
        string name;
        string symbol;
        string meta;
        address[] quotes;
        uint16[] weights;
        bytes32[] poolIds;
        int24[] startTicks;
    }

    event Launched(
        address indexed meme,
        address indexed creator,
        string name,
        string symbol,
        address[] quotes,
        uint16[] weights,
        int24[] startTicks,
        bytes32[] poolIds,
        uint256 devBuyOut
    );
    event QuoteSet(address indexed currency, QuoteConfig cfg);
    event ManualPriceSet(address indexed currency, uint256 priceUsdE18);
    event PriceKeeperSet(address indexed keeper);
    event QuoteBuyPausedSet(address indexed currency, bool paused);
    event QuoteOutflowCapSet(address indexed currency, uint16 capBps, uint32 window);
    event BinPoolManagerSet(address indexed binPoolManager);
    event StartFdvUsdSet(uint256 startFdvUsd);
    event MinHubWeightBpsSet(uint16 minHubWeightBps);
    event LaunchFeeSet(uint256 launchFee);
    event BuybackSet(address indexed buyback);
    event LaunchFeesForwarded(address indexed buyback, uint256 amount);

    error BadValue();
    error SaltAlreadyUsed();
    error BadName();
    error BadQuotes();
    error DuplicateQuote(address currency);
    error QuoteNotEnabled(address currency);
    error BadWeight(address currency);
    error BadWeightSum();
    error NoHub();
    error BadConfig();
    error BadPrice(address currency);
    error StalePrice(address currency);
    error OutOfBounds();
    error NotKeeper();
    error NotMeme();
    error NotAQuote();
    error NotVault();
    error QuoteSideNotZero();
    error DevBuyPartialFill();
    error DevBuySlippage(uint256 out, uint256 minOut);
    error DevBuyTooLarge(uint256 out);
    error BuybackAlreadySet();
    error ZeroAddress();
    error TransferFailed();

    /// @notice Launches a meme with 1-4 quote pools in one tx.
    function launch(LaunchParams calldata p) external payable returns (address meme);

    /// @notice Address `launch` will deploy for `creator` and user salt `salt`.
    function predictMemeAddress(address creator, bytes32 salt) external view returns (address);

    /// @notice Start ticks `launch` would use now for `memeAddr` against `currencies`.
    function previewStartTicks(address[] calldata currencies, address memeAddr)
        external
        view
        returns (int24[] memory ticks);

    /// @notice Quote currency price in USD, 18 decimals. Reverts StalePrice / BadPrice.
    function quoteUsdE18(address currency) external view returns (uint256);

    function memeCount() external view returns (uint256);
    function memeAt(uint256 index) external view returns (address);
    function getMeme(address meme) external view returns (MemeView memory);
    function getMemes(uint256 offset, uint256 limit, bool newestFirst) external view returns (MemeView[] memory);
    function isMeme(address meme) external view returns (bool);

    /// @notice Canonical pool key of (`meme`, `quote`). Reverts if `quote` is not one of the meme's quotes.
    function poolKeyOf(address meme, address quote) external view returns (PoolKey memory key, bool memeIs0);

    function quoteCount() external view returns (uint256);
    function getQuotes() external view returns (address[] memory currencies, QuoteConfig[] memory configs);

    function hook() external view returns (address);
    function buyback() external view returns (address);

    /// @notice Second Vault app (PCS Infinity BinPoolManager) whose meme reserves new memes count as pool inventory.
    function binPoolManager() external view returns (address);
}
