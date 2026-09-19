// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {IMemeDaqLaunchpad} from "./interfaces/IMemeDaqLaunchpad.sol";
import {IMemeDaqHook} from "./interfaces/IMemeDaqHook.sol";
import {IMemeToken} from "./interfaces/IMemeToken.sol";
import {IChainlinkFeed} from "./interfaces/IChainlinkFeed.sol";
import {StartPrice} from "./libraries/StartPrice.sol";
import {MemeDaqHook} from "./MemeDaqHook.sol";
import {MemeToken} from "./MemeToken.sol";
import {IMemeBasketIndex} from "./index/IIndexPriceSource.sol";
import {SelectableIndexRegistry} from "./index/SelectableIndexRegistry.sol";
import {DidxBasketRegistry} from "./index/DidxBasketRegistry.sol";

/// @title MemeDaqLaunchpad
/// @notice Deploys a meme (EIP-1167 clone), creates one PancakeSwap Infinity CL pool per quote currency with the
///         shared MemeDAQ tax hook and seeds each with a permanent single-sided meme position — all in one tx.
///         Also the registry the website reads.
/// @dev No code path ever calls `modifyLiquidity` with a non-positive delta: seeded liquidity is locked forever.
contract MemeDaqLaunchpad is IMemeDaqLaunchpad, ILockCallback, Ownable2Step, ReentrancyGuard {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    int24 public constant TICK_SPACING = 200;
    uint24 public constant LP_FEE = 0;
    uint16 public constant HOOK_BITMAP = 0x0CC5;
    uint256 public constant MAX_DEV_BUY_BPS = 500;
    uint256 public constant MAX_QUOTES = 4;
    uint256 public constant MAX_LAUNCH_FEE = 0.05 ether;
    uint256 public constant MIN_START_FDV_USD = 1_000e18;
    uint256 public constant MAX_START_FDV_USD = 1_000_000e18;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 internal constant POOL_PARAMETERS = bytes32(uint256(HOOK_BITMAP) | (uint256(uint24(TICK_SPACING)) << 16));
    uint256 internal constant BPS = 10_000;
    uint8 internal constant ACTION_SEED = 1;
    uint8 internal constant ACTION_DEVBUY = 2;

    /// @notice PancakeSwap Infinity Vault.
    IVault public immutable vault;
    /// @notice CLPoolManager.
    ICLPoolManager public immutable poolManager;
    /// @notice The shared tax hook, deployed by this contract.
    IMemeDaqHook internal immutable _hook;
    /// @notice MemeToken implementation the memes are cloned from.
    address public immutable memeImplementation;

    /// @inheritdoc IMemeDaqLaunchpad
    address public override buyback;
    /// @notice May update MANUAL quote prices and pause quote buys (besides the owner).
    address public priceKeeper;
    /// @notice Permanently bound redeemable basket; its single pool replaces the BNB hub for basket launches.
    address public basketQuote;
    DidxBasketRegistry public basketRegistry;
    /// @notice Optional basket benchmark, set once before the first launch. Zero preserves legacy operation.
    IMemeBasketIndex public indexOracle;
    SelectableIndexRegistry public immutable indexRegistry;
    mapping(address => address) public launchIndexOracle;
    mapping(address => bool) private _selectedIndex;
    mapping(address => uint256) public launchIndexE18;
    mapping(address => uint256) public launchFdvUsdE18;
    event IndexOracleSet(address indexed oracle);
    event LaunchBenchmark(address indexed meme, uint256 indexE18, uint256 fdvUsdE18);
    event LaunchIndexSelected(address indexed meme, address indexed oracle);
    /// @inheritdoc IMemeDaqLaunchpad
    address public override binPoolManager;
    /// @notice Target start FDV of every new meme, USD 18 decimals.
    uint256 public startFdvUsd = 6_000e18;
    /// @notice Minimum weight of the hub (BNB) pool.
    uint16 public minHubWeightBps = 5_000;
    /// @notice BNB fee per launch, forwarded to the buyback.
    uint256 public launchFee;

    /// @notice Quote whitelist.
    mapping(address => QuoteConfig) public quoteConfig;
    /// @notice Every currency ever configured, in insertion order.
    address[] public quoteList;
    mapping(address => bool) internal _listed;

    struct Record {
        address creator;
        uint40 createdAt;
        uint48 launchBlock;
        uint8 count;
        uint16[4] weights;
        int24[4] startTicks;
        address[4] quotes;
    }

    address[] internal _memes;
    mapping(address => Record) internal _records;

    struct SeedData {
        address meme;
        PoolKey[] keys;
        int24[] ticks;
        uint16[] weights;
    }

    struct DevBuyData {
        PoolKey key;
        uint256 amountIn;
        address to;
    }

    /// @param vault_ PancakeSwap Infinity Vault.
    /// @param poolManager_ CLPoolManager.
    /// @param owner_ Initial owner (two-step transferable).
    constructor(IVault vault_, ICLPoolManager poolManager_, address owner_) Ownable(owner_) {
        vault = vault_;
        poolManager = poolManager_;
        _hook = IMemeDaqHook(address(new MemeDaqHook(vault_, poolManager_, address(this))));
        memeImplementation = address(new MemeToken());
        indexRegistry = new SelectableIndexRegistry();
    }

    // ------------------------------------------------------------------
    // Launch
    // ------------------------------------------------------------------

    /// @inheritdoc IMemeDaqLaunchpad
    function launch(LaunchParams calldata p) external payable override nonReentrant returns (address meme) {
        return _launch(p, indexOracle);
    }

    /// @notice Plain meme launch: one BNB pool at the base FDV, independent of every meme index.
    function launchMeme(LaunchParams calldata p) external payable nonReentrant returns (address meme) {
        return _launch(p, indexOracle);
    }

    /// @notice Also serves as an explicit capability check for the plain launch entry point.
    function memeStartFdvUsd() external view returns (uint256) { return startFdvUsd; }

    function setBasketQuote(address basket) external onlyOwner {
        if (basketQuote != address(0) || _memes.length != 0 || basket.code.length == 0) revert BadConfig();
        basketQuote = basket;
    }

    function setBasketRegistry(DidxBasketRegistry registry) external onlyOwner {
        if (address(basketRegistry) != address(0)) revert BadConfig();
        registry.validateBinding(basketQuote);
        basketRegistry = registry;
    }

    /// @notice Creates exactly one meme/dIDX pool. Creator purchases use the basket router after launch.
    function launchBasket(LaunchParams calldata p) external payable nonReentrant returns (address meme) {
        return _launch(p, indexOracle);
    }

    /// @notice Choose an owner-approved four-component benchmark independently from the quote pools.
    function launchWithIndex(LaunchParams calldata p, address oracle) external payable nonReentrant returns (address meme) {
        return _launch(p, IMemeBasketIndex(oracle));
    }

    function _launch(LaunchParams calldata p, IMemeBasketIndex oracle) internal returns (address meme) {
        // The entry selector distinguishes the sealed selection from the legacy, rebalancing default.
        // Keeping this decision inside the shared path prevents optimizer duplication of pool initialization.
        bool selected = msg.sig == this.launchWithIndex.selector;
        bool basketMode = msg.sig == this.launchBasket.selector;
        if (basketMode || msg.sig == this.launchMeme.selector) {
            if (p.quotes.length != 1 || p.quotes[0].weightBps != BPS) revert BadConfig();
            address singleQuote = p.quotes[0].currency;
            if (basketMode ? singleQuote == address(0) || !quoteConfig[singleQuote].isHub : singleQuote != address(0)) revert BadConfig();
            oracle = IMemeBasketIndex(address(0));
        }
        if (selected) indexRegistry.verify(address(oracle), true);
        if (msg.value != launchFee + p.devBuyBnb) revert BadValue();
        _checkStrings(p.name, p.symbol, p.meta);
        (address[] memory cur, uint16[] memory w, uint256 hub) = _checkQuotes(p.quotes);
        if (p.devBuyBnb != 0 && cur[hub] != address(0)) revert BadConfig();
        uint256 n = cur.length;
        if (address(oracle) != address(0)) oracle.updatePrices();
        // Verify after maintenance too: a changed registered basket must never be used to initialize a pool.
        if (selected) indexRegistry.verify(address(oracle), true);

        bytes32 salt = keccak256(abi.encode(msg.sender, p.salt));
        // a CREATE2 collision would burn all forwarded gas: fail cheaply instead
        if (Clones.predictDeterministicAddress(memeImplementation, salt).code.length != 0) revert SaltAlreadyUsed();
        meme = Clones.cloneDeterministic(memeImplementation, salt);

        PoolKey[] memory keys = new PoolKey[](n);
        bytes32[] memory ids = new bytes32[](n);
        int24[] memory ticks = new int24[](n);
        for (uint256 i; i < n; ++i) {
            keys[i] = _key(meme, cur[i]);
            ids[i] = PoolId.unwrap(keys[i].toId());
        }

        IMemeToken(meme)
            .initialize(
                IMemeToken.InitParams({
                name: p.name,
                symbol: p.symbol,
                meta: p.meta,
                creator: msg.sender,
                launchpad: address(this),
                hook: address(_hook),
                infinityVault: address(vault),
                clPoolManager: address(poolManager),
                binPoolManager: binPoolManager,
                rewardCurrencies: cur,
                rewardPoolIds: ids
            })
            );

        (uint256 fdv, uint256 indexPoints) = _launchBenchmark(oracle);
        for (uint256 i; i < n; ++i) {
            bool memeIs0 = meme < cur[i];
            ticks[i] = StartPrice.startTick(fdv, quoteUsdE18(cur[i]), quoteConfig[cur[i]].decimals, memeIs0);
            uint160 sp = TickMath.getSqrtRatioAtTick(ticks[i]);
            _hook.register(keys[i], meme, uint8(i), !memeIs0, sp);
            poolManager.initialize(keys[i], sp);
        }

        vault.lock(abi.encode(ACTION_SEED, abi.encode(SeedData(meme, keys, ticks, w))));
        uint256 dust = IERC20(meme).balanceOf(address(this));
        if (dust != 0 && !IERC20(meme).transfer(DEAD, dust)) revert TransferFailed();

        uint256 devOut;
        if (p.devBuyBnb != 0) {
            bytes memory res =
                vault.lock(abi.encode(ACTION_DEVBUY, abi.encode(DevBuyData(keys[hub], p.devBuyBnb, msg.sender))));
            devOut = abi.decode(res, (uint256));
            if (devOut < p.devBuyMinOut) revert DevBuySlippage(devOut, p.devBuyMinOut);
            if (devOut > TOTAL_SUPPLY * MAX_DEV_BUY_BPS / BPS) revert DevBuyTooLarge(devOut);
        }

        if (launchFee != 0) _forwardLaunchFees();

        Record storage r = _records[meme];
        r.creator = msg.sender;
        r.createdAt = uint40(block.timestamp);
        r.launchBlock = uint48(block.number);
        r.count = uint8(n);
        for (uint256 i; i < n; ++i) {
            r.weights[i] = w[i];
            r.startTicks[i] = ticks[i];
            if (cur[i] != address(0)) r.quotes[i] = cur[i];
        }
        _memes.push(meme);
        launchIndexE18[meme] = indexPoints;
        launchFdvUsdE18[meme] = fdv;
        launchIndexOracle[meme] = address(oracle);
        _selectedIndex[meme] = selected;
        emit LaunchBenchmark(meme, indexPoints, fdv);
        emit LaunchIndexSelected(meme, address(oracle));

        emit Launched(meme, msg.sender, p.name, p.symbol, cur, w, ticks, ids, devOut);
    }

    /// @notice Vault callback: seeds the single-sided positions, or executes the creator's dev-buy.
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(vault)) revert NotVault();
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == ACTION_SEED) {
            _seed(abi.decode(payload, (SeedData)));
            return "";
        }
        return abi.encode(_devBuy(abi.decode(payload, (DevBuyData))));
    }

    function _seed(SeedData memory s) internal {
        uint256 n = s.keys.length;
        int24 minTick = TickMath.minUsableTick(TICK_SPACING);
        int24 maxTick = TickMath.maxUsableTick(TICK_SPACING);
        uint256 left = TOTAL_SUPPLY;
        uint256 owed;
        for (uint256 i; i < n; ++i) {
            uint256 amt = i == n - 1 ? left : TOTAL_SUPPLY * s.weights[i] / BPS;
            left -= amt;
            bool memeIs0 = Currency.unwrap(s.keys[i].currency0) == s.meme;
            (int24 lo, int24 hi) = memeIs0 ? (s.ticks[i], maxTick) : (minTick, s.ticks[i]);
            uint256 sa = TickMath.getSqrtRatioAtTick(lo);
            uint256 sb = TickMath.getSqrtRatioAtTick(hi);
            uint256 liquidity = memeIs0
                ? FullMath.mulDiv(FullMath.mulDiv(amt, sa, 1 << 96), sb, sb - sa)
                : FullMath.mulDiv(amt, 1 << 96, sb - sa);
            (BalanceDelta d,) = poolManager.modifyLiquidity(
                s.keys[i],
                ICLPoolManager.ModifyLiquidityParams({
                    tickLower: lo, tickUpper: hi, liquidityDelta: int256(liquidity), salt: bytes32(0)
                }),
                ""
            );
            (int128 dm, int128 dq) = memeIs0 ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
            if (dq != 0) revert QuoteSideNotZero();
            owed += uint256(uint128(-dm));
        }
        Currency m = Currency.wrap(s.meme);
        vault.sync(m);
        if (!IERC20(s.meme).transfer(address(vault), owed)) revert TransferFailed();
        vault.settle();
    }

    function _devBuy(DevBuyData memory b) internal returns (uint256 out) {
        // BNB (address(0)) is always currency0: a buy is zeroForOne
        BalanceDelta d = poolManager.swap(
            b.key,
            ICLPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(b.amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            ""
        );
        if (int256(d.amount0()) != -int256(b.amountIn)) revert DevBuyPartialFill();
        out = uint256(uint128(d.amount1()));
        vault.settle{value: b.amountIn}();
        vault.take(b.key.currency1, b.to, out);
    }

    // ------------------------------------------------------------------
    // Owner configuration
    // ------------------------------------------------------------------

    /// @notice Adds or updates a quote currency. BNB (address(0)) must stay the enabled CHAINLINK hub.
    function setQuote(address currency, QuoteConfig calldata cfg) external onlyOwner {
        indexRegistry.validateQuote(currency, cfg, basketQuote, basketRegistry);
        if (!_listed[currency]) {
            _listed[currency] = true;
            quoteList.push(currency);
        }
        quoteConfig[currency] = cfg;
        emit QuoteSet(currency, cfg);
    }

    /// @notice Updates the price of a MANUAL quote. Owner or price keeper.
    function setManualPrice(address currency, uint128 priceUsdE18) external {
        if (msg.sender != owner() && msg.sender != priceKeeper) revert NotKeeper();
        QuoteConfig storage cfg = quoteConfig[currency];
        if (cfg.source != PriceSource.MANUAL || priceUsdE18 == 0) revert BadConfig();
        cfg.manualPriceUsdE18 = priceUsdE18;
        cfg.manualUpdatedAt = uint64(block.timestamp);
        emit ManualPriceSet(currency, priceUsdE18);
    }

    /// @notice Sets the MANUAL price keeper.
    function setPriceKeeper(address keeper) external onlyOwner {
        priceKeeper = keeper;
        emit PriceKeeperSet(keeper);
    }

    /// @notice Bind the benchmark permanently before any token is launched; basket changes use its timelock.
    function setIndexOracle(IMemeBasketIndex oracle) external onlyOwner {
        if (address(indexOracle) != address(0) || _memes.length != 0 || address(oracle).code.length == 0) revert BadConfig();
        (uint256 points,) = oracle.latestIndex();
        if (points == 0) revert BadConfig();
        indexOracle = oracle;
        emit IndexOracleSet(address(oracle));
    }

    function _launchBenchmark() internal view returns (uint256 fdv, uint256 points) {
        return _launchBenchmark(indexOracle);
    }

    function _launchBenchmark(IMemeBasketIndex oracle) internal view returns (uint256 fdv, uint256 points) {
        points = 1000e18;
        if (address(oracle) != address(0)) (points,) = oracle.latestIndex();
        fdv = FullMath.mulDiv(startFdvUsd, points, 1000e18);
        if (fdv < MIN_START_FDV_USD || fdv > MAX_START_FDV_USD) revert OutOfBounds();
    }

    /// @notice Current starting FDV for a new launch, including the basket's price-return multiplier.
    function currentStartFdvUsd() external view returns (uint256 fdv) { (fdv,) = _launchBenchmark(); }

    function registerIndex(address oracle) external onlyOwner { indexRegistry.registerIndex(oracle); }
    function setIndexEnabled(address oracle, bool enabled) external onlyOwner { indexRegistry.setIndexEnabled(oracle, enabled); }
    function indexEnabled(address oracle) external view returns (bool) { return indexRegistry.indexEnabled(oracle); }
    function getIndexes() external view returns (address[] memory oracles, bool[] memory enabled) { return indexRegistry.getIndexes(); }

    function currentStartFdvUsdForIndex(address oracle) external view returns (uint256 fdv) {
        indexRegistry.verify(oracle, true);
        (fdv,) = _launchBenchmark(IMemeBasketIndex(oracle));
    }

    /// @notice Continuous basket reference for an existing token; pool market prices remain independently traded.
    function referenceFdvUsd(address meme) external view returns (uint256) {
        if (!isMeme(meme)) revert NotMeme();
        uint256 points = 1000e18;
        address oracle = launchIndexOracle[meme];
        if (_selectedIndex[meme]) indexRegistry.verify(oracle, false);
        if (oracle != address(0)) (points,) = IMemeBasketIndex(oracle).latestIndex();
        return FullMath.mulDiv(launchFdvUsdE18[meme], points, launchIndexE18[meme]);
    }

    /// @notice Pauses/resumes buys (quote in) in every pool quoted in `currency`. Sells stay open.
    ///         The owner may pause and resume; the price keeper may only pause (circuit breaker).
    function setQuoteBuyPaused(address currency, bool paused) external {
        if (!paused || msg.sender != priceKeeper) _checkOwner();
        _hook.setBuyPaused(Currency.wrap(currency), paused);
        emit QuoteBuyPausedSet(currency, paused);
    }

    /// @notice Caps how much meme the pools quoted in `currency` (not BNB) may sell per `window` seconds, as bps of
    ///         the meme supply (linear refill). capBps 0 removes the cap.
    function setQuoteOutflowCap(address currency, uint16 capBps, uint32 window) external onlyOwner {
        _hook.setOutflowCap(Currency.wrap(currency), capBps, window);
        emit QuoteOutflowCapSet(currency, capBps, window);
    }

    /// @notice Sets the BinPoolManager passed to future memes (0 = none).
    function setBinPoolManager(address binPoolManager_) external onlyOwner {
        binPoolManager = binPoolManager_;
        emit BinPoolManagerSet(binPoolManager_);
    }

    /// @notice Sets the start FDV for future launches, within [1_000e18, 1_000_000e18].
    function setStartFdvUsd(uint256 value) external onlyOwner {
        if (value < MIN_START_FDV_USD || value > MAX_START_FDV_USD) revert OutOfBounds();
        startFdvUsd = value;
        emit StartFdvUsdSet(value);
    }

    /// @notice Sets the minimum hub weight, within [3000, 10000].
    function setMinHubWeightBps(uint16 value) external onlyOwner {
        if (value < 3_000 || value > BPS) revert OutOfBounds();
        minHubWeightBps = value;
        emit MinHubWeightBpsSet(value);
    }

    /// @notice Sets the launch fee, at most 0.05 BNB.
    function setLaunchFee(uint256 value) external onlyOwner {
        if (value > MAX_LAUNCH_FEE) revert OutOfBounds();
        launchFee = value;
        emit LaunchFeeSet(value);
    }

    /// @notice Sets the buyback contract, once (also on the hook) and forwards any held launch fees to it.
    function setBuyback(address buyback_) external onlyOwner {
        if (buyback != address(0)) revert BuybackAlreadySet();
        if (buyback_ == address(0)) revert ZeroAddress();
        buyback = buyback_;
        _hook.setBuyback(buyback_);
        emit BuybackSet(buyback_);
        _forwardLaunchFees();
    }

    /// @notice Forwards launch fees held here (collected before the buyback was set) to the buyback. Permissionless.
    function forwardLaunchFees() external nonReentrant {
        _forwardLaunchFees();
    }

    /// @notice Excludes a contract (e.g. a third-party pair or locker) from a meme's dividends. One-way.
    function excludeFromDividends(address meme, address account) external onlyOwner {
        if (!isMeme(meme)) revert NotMeme();
        IMemeToken(meme).excludeFromDividends(account);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @inheritdoc IMemeDaqLaunchpad
    function hook() external view override returns (address) {
        return address(_hook);
    }

    /// @inheritdoc IMemeDaqLaunchpad
    function quoteUsdE18(address currency) public view override returns (uint256 price) {
        QuoteConfig storage cfg = quoteConfig[currency];
        PriceSource source = cfg.source;
        if (source == PriceSource.USD_PEG) return 1e18;
        uint256 updatedAt;
        if (source == PriceSource.CHAINLINK) {
            IChainlinkFeed feed = IChainlinkFeed(cfg.feed);
            int256 answer;
            (, answer,, updatedAt,) = feed.latestRoundData();
            if (answer <= 0) revert BadPrice(currency);
            uint256 dec = feed.decimals();
            price = dec <= 18 ? uint256(answer) * 10 ** (18 - dec) : uint256(answer) / 10 ** (dec - 18);
        } else if (source == PriceSource.MANUAL) {
            price = cfg.manualPriceUsdE18;
            updatedAt = cfg.manualUpdatedAt;
        }
        if (price == 0) revert BadPrice(currency);
        if (updatedAt + cfg.maxAge < block.timestamp) revert StalePrice(currency);
    }

    /// @inheritdoc IMemeDaqLaunchpad
    function predictMemeAddress(address creator, bytes32 salt) external view override returns (address) {
        return Clones.predictDeterministicAddress(memeImplementation, keccak256(abi.encode(creator, salt)));
    }

    /// @inheritdoc IMemeDaqLaunchpad
    function previewStartTicks(address[] calldata currencies, address memeAddr)
        external
        view
        override
        returns (int24[] memory ticks)
    {
        (uint256 fdv,) = _launchBenchmark();
        return _previewStartTicks(currencies, memeAddr, fdv);
    }

    function previewStartTicksWithIndex(address[] calldata currencies, address memeAddr, address oracle)
        external view returns (int24[] memory ticks)
    {
        // address(0) explicitly previews the plain launch base FDV, without any index read.
        uint256 fdv = startFdvUsd;
        if (oracle != address(0)) {
            indexRegistry.verify(oracle, true);
            (fdv,) = _launchBenchmark(IMemeBasketIndex(oracle));
        }
        return _previewStartTicks(currencies, memeAddr, fdv);
    }

    function _previewStartTicks(address[] calldata currencies, address memeAddr, uint256 fdv)
        internal view returns (int24[] memory ticks)
    {
        ticks = new int24[](currencies.length);
        for (uint256 i; i < currencies.length; ++i) {
            address c = currencies[i];
            ticks[i] = StartPrice.startTick(fdv, quoteUsdE18(c), quoteConfig[c].decimals, memeAddr < c);
        }
    }

    /// @inheritdoc IMemeDaqLaunchpad
    function memeCount() external view override returns (uint256) {
        return _memes.length;
    }

    /// @inheritdoc IMemeDaqLaunchpad
    function memeAt(uint256 index) external view override returns (address) {
        return _memes[index];
    }

    /// @inheritdoc IMemeDaqLaunchpad
    function isMeme(address meme) public view override returns (bool) {
        return _records[meme].creator != address(0);
    }

    /// @inheritdoc IMemeDaqLaunchpad
    function getMeme(address meme) public view override returns (MemeView memory v) {
        Record storage r = _records[meme];
        if (r.creator == address(0)) revert NotMeme();
        uint256 n = r.count;
        v.meme = meme;
        v.creator = r.creator;
        v.createdAt = r.createdAt;
        v.launchBlock = r.launchBlock;
        v.name = IMemeToken(meme).name();
        v.symbol = IMemeToken(meme).symbol();
        v.meta = IMemeToken(meme).meta();
        v.quotes = new address[](n);
        v.weights = new uint16[](n);
        v.poolIds = new bytes32[](n);
        v.startTicks = new int24[](n);
        for (uint256 i; i < n; ++i) {
            address q = r.quotes[i];
            v.quotes[i] = q;
            v.weights[i] = r.weights[i];
            v.startTicks[i] = r.startTicks[i];
            v.poolIds[i] = PoolId.unwrap(_key(meme, q).toId());
        }
    }

    /// @inheritdoc IMemeDaqLaunchpad
    function getMemes(uint256 offset, uint256 limit, bool newestFirst)
        external
        view
        override
        returns (MemeView[] memory views)
    {
        uint256 total = _memes.length;
        if (offset >= total) return views;
        uint256 k = total - offset;
        if (limit < k) k = limit;
        views = new MemeView[](k);
        for (uint256 i; i < k; ++i) {
            views[i] = getMeme(_memes[newestFirst ? total - 1 - offset - i : offset + i]);
        }
    }

    /// @inheritdoc IMemeDaqLaunchpad
    function poolKeyOf(address meme, address quote) external view override returns (PoolKey memory key, bool memeIs0) {
        Record storage r = _records[meme];
        if (r.creator == address(0)) revert NotMeme();
        uint256 n = r.count;
        uint256 i;
        while (i < n && r.quotes[i] != quote) ++i;
        if (i == n) revert NotAQuote();
        key = _key(meme, quote);
        memeIs0 = meme < quote;
    }

    /// @inheritdoc IMemeDaqLaunchpad
    function quoteCount() external view override returns (uint256) {
        return quoteList.length;
    }

    /// @inheritdoc IMemeDaqLaunchpad
    function getQuotes() external view override returns (address[] memory currencies, QuoteConfig[] memory configs) {
        currencies = quoteList;
        configs = new QuoteConfig[](currencies.length);
        for (uint256 i; i < currencies.length; ++i) {
            configs[i] = quoteConfig[currencies[i]];
        }
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _key(address meme, address quote) internal view returns (PoolKey memory) {
        (address c0, address c1) = meme < quote ? (meme, quote) : (quote, meme);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: IHooks(address(_hook)),
            poolManager: IPoolManager(address(poolManager)),
            fee: LP_FEE,
            parameters: POOL_PARAMETERS
        });
    }

    function _checkStrings(string calldata name_, string calldata symbol_, string calldata meta_) internal pure {
        uint256 a = bytes(name_).length;
        uint256 b = bytes(symbol_).length;
        if (a == 0 || a > 32 || b == 0 || b > 12 || bytes(meta_).length > 1024) revert BadName();
    }

    function _checkQuotes(QuoteAlloc[] calldata q)
        internal
        view
        returns (address[] memory cur, uint16[] memory w, uint256 hub)
    {
        uint256 n = q.length;
        if (n == 0 || n > MAX_QUOTES) revert BadQuotes();
        cur = new address[](n);
        w = new uint16[](n);
        uint256 sum;
        bool hasHub;
        for (uint256 i; i < n; ++i) {
            address c = q[i].currency;
            if (n > 1 && c != address(0) && quoteConfig[c].isHub) revert BadQuotes();
            for (uint256 j; j < i; ++j) {
                if (cur[j] == c) revert DuplicateQuote(c);
            }
            QuoteConfig storage cfg = quoteConfig[c];
            if (!cfg.enabled) revert QuoteNotEnabled(c);
            uint16 wi = q[i].weightBps;
            if (wi == 0 || wi > cfg.maxWeightBps) revert BadWeight(c);
            if (cfg.isHub) {
                if (wi < minHubWeightBps) revert BadWeight(c);
                hub = i;
                hasHub = true;
            }
            sum += wi;
            cur[i] = c;
            w[i] = wi;
        }
        if (!hasHub) revert NoHub();
        if (sum != BPS) revert BadWeightSum();
    }

    function _forwardLaunchFees() internal {
        address to = buyback;
        uint256 bal = address(this).balance;
        if (to == address(0) || bal == 0) return;
        (bool ok,) = to.call{value: bal}("");
        if (!ok) revert TransferFailed();
        emit LaunchFeesForwarded(to, bal);
    }
}
