// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

/// @title IMdaqBuyback
/// @notice Receives the 0.3% buyback share, snipe tax and launch fees; converts to BNB and buys-and-burns $MDAQ.
///         No function can move funds to an arbitrary address, and a keeper can only convert at a bounded price.
interface IMdaqBuyback {
    event Collected(address indexed currency, uint256 amount);
    event SwappedToBnb(address indexed token, uint256 amountIn, uint256 bnbOut);
    event BoughtAndBurned(uint256 bnbIn, uint256 mdaqBurned);
    event MdaqSet(address indexed mdaq);
    event KeeperSet(address indexed keeper, bool allowed);
    event FeedSet(address indexed token, address feed, uint16 maxSlippageBps);
    event RefPriceSet(address indexed token, uint256 priceUsdE18, uint16 maxSlippageBps);
    event RouteHopSet(address indexed token, bool allowed);

    error NotKeeper();
    error BadToken();
    error BadRoute();
    error BadAmount();
    error BadConfig();
    error MdaqNotSet();
    error MdaqAlreadySet();
    error NoBnbFeed();
    error BadPrice();
    error NoPriceBound(address token);
    error MinOutBelowOracle(uint256 minOut, uint256 floor);
    error TooLittleReceived(uint256 out, uint256 minOut);
    error ZeroAddress();

    /// @notice Pulls the buyback share of `poolIds` from the hook. Permissionless.
    function collect(bytes32[] calldata poolIds) external;

    /// @notice Converts `amountIn` of `token` to BNB. Keeper only.
    /// @dev A keeper needs a price bound for `token` (Chainlink feed or fresh owner reference price) and `minOut`
    ///      must be at least that value minus the configured slippage. Only the owner may convert a token without
    ///      a bound. WBNB itself is simply unwrapped (route ignored).
    /// @param route 1 = PCS v2 router (routeData = abi.encode(address[] path), token → allowlisted hops → WBNB);
    ///              2 = PCS v3 SwapRouter exactInputSingle token → WBNB (routeData = abi.encode(uint24 fee), fee one
    ///              of 100 / 500 / 2500 / 10000), then unwrap.
    function swapToBnb(address token, uint256 amountIn, uint256 minOut, uint8 route, bytes calldata routeData)
        external
        returns (uint256 bnbOut);

    /// @notice Buys $MDAQ with `bnbAmount` through the Flap Portal and sends all $MDAQ held to 0x…dEaD. Keeper only.
    function buyAndBurn(uint256 bnbAmount, uint256 minMdaqOut) external returns (uint256 mdaqBurned);

    /// @notice Sets $MDAQ, once. Owner only.
    function setMdaq(address mdaq_) external;

    /// @notice Adds or removes a keeper. Owner only.
    function setKeeper(address keeper, bool allowed) external;

    /// @notice Configures the Chainlink USD feed of `token` (address(0) = BNB/USD). Owner only.
    function setFeed(address token, address feed, uint16 maxSlippageBps) external;

    /// @notice Sets a USD reference price (18 decimals) for a token without a feed; valid for REF_PRICE_MAX_AGE.
    ///         priceUsdE18 = 0 removes it. Owner only.
    function setRefPrice(address token, uint128 priceUsdE18, uint16 maxSlippageBps) external;

    /// @notice Allows or disallows `token` as an intermediate hop of v2 routes. Owner only.
    function setRouteHop(address token, bool allowed) external;

    /// @notice Value of `amountIn` of `token` in BNB wei at its price bound (0 if `token` has none).
    function oracleBnbValue(address token, uint256 amountIn) external view returns (uint256);

    function totalBnbSpent() external view returns (uint256);
    function totalMdaqBurned() external view returns (uint256);
    function mdaq() external view returns (address);
    function keepers(address account) external view returns (bool);
    function routeHops(address token) external view returns (bool);
}
