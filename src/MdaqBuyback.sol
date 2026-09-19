// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IMdaqBuyback} from "./interfaces/IMdaqBuyback.sol";
import {IMemeDaqHook} from "./interfaces/IMemeDaqHook.sol";
import {IChainlinkFeed} from "./interfaces/IChainlinkFeed.sol";

interface IWBNB {
    function withdraw(uint256 wad) external;
}

interface IDidxRedeemer {
    function basket() external view returns (address);
    function redeemToBnb(uint256 shares, uint256[] calldata limits, uint256 minOut, address receiver, uint256 deadline)
        external returns (uint256, uint256[] memory);
}

interface IPancakeV2Router {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPancakeV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IFlapPortalTrade {
    struct ExactInputParams {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 minOutputAmount;
        bytes permitData;
    }

    function swapExactInput(ExactInputParams calldata params) external payable returns (uint256 outputAmount);
}

/// @title MdaqBuyback
/// @notice Holds the 0.3% buyback share of every MemeDAQ swap, the snipe tax and the launch fees. Keepers convert
///         them to BNB and buy $MDAQ through the Flap Portal; every $MDAQ held is sent to 0x…dEaD. No function can
///         move funds to an arbitrary address.
/// @dev A keeper can only convert a token that has a price bound (Chainlink feed, or an owner reference price
///      younger than REF_PRICE_MAX_AGE), at no less than that value minus the token's slippage allowance
///      (at most MAX_SLIPPAGE_BPS). v2 routes may only pass through owner-allowlisted hops and v3 routes only use the
///      canonical fee tiers. Converting a token without a bound is left to the owner.
contract MdaqBuyback is IMdaqBuyback, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant FEED_MAX_AGE = 1 days;
    uint256 public constant REF_PRICE_MAX_AGE = 1 hours;
    uint16 public constant MAX_SLIPPAGE_BPS = 1_000;
    uint8 public constant ROUTE_V2 = 1;
    uint8 public constant ROUTE_V3 = 2;

    /// @notice MemeDAQ tax hook (source of the buyback claims).
    IMemeDaqHook public immutable hook;
    /// @notice WBNB.
    address public immutable wbnb;
    /// @notice PancakeSwap v2 router.
    address public immutable v2Router;
    /// @notice PancakeSwap v3 SwapRouter (exactInputSingle with deadline).
    address public immutable v3Router;
    address public basketGateway;
    mapping(address => address) public basketGateways;
    event BasketGatewaySet(address indexed gateway);

    function setBasketGateway(address gateway) external onlyOwner {
        if (gateway.code.length == 0) revert BadRoute();
        address token = IDidxRedeemer(gateway).basket();
        if (token.code.length == 0 || basketGateways[token] != address(0)) revert BadRoute();
        basketGateways[token] = gateway;
        if (basketGateway == address(0)) basketGateway = gateway;
        emit BasketGatewaySet(gateway);
    }
    /// @notice Flap Portal.
    address public immutable flapPortal;

    /// @inheritdoc IMdaqBuyback
    address public override mdaq;
    /// @inheritdoc IMdaqBuyback
    mapping(address => bool) public override keepers;
    /// @inheritdoc IMdaqBuyback
    uint256 public override totalBnbSpent;
    /// @inheritdoc IMdaqBuyback
    uint256 public override totalMdaqBurned;

    struct Feed {
        address feed;
        uint16 maxSlippageBps;
    }

    struct RefPrice {
        uint128 priceUsdE18;
        uint64 updatedAt;
        uint16 maxSlippageBps;
    }

    /// @notice Chainlink USD feed per token; address(0) holds the BNB/USD feed.
    mapping(address => Feed) public feeds;
    /// @notice Owner-set USD reference price per token (used when the token has no feed).
    mapping(address => RefPrice) public refPrices;
    /// @inheritdoc IMdaqBuyback
    mapping(address => bool) public override routeHops;

    modifier onlyKeeper() {
        if (!keepers[msg.sender] && msg.sender != owner()) revert NotKeeper();
        _;
    }

    /// @param owner_ Initial owner.
    /// @param hook_ MemeDAQ hook.
    /// @param wbnb_ WBNB.
    /// @param v2Router_ PancakeSwap v2 router.
    /// @param v3Router_ PancakeSwap v3 SwapRouter.
    /// @param flapPortal_ Flap Portal.
    constructor(
        address owner_,
        IMemeDaqHook hook_,
        address wbnb_,
        address v2Router_,
        address v3Router_,
        address flapPortal_
    ) Ownable(owner_) {
        if (address(hook_) == address(0) || wbnb_ == address(0)) revert ZeroAddress();
        hook = hook_;
        wbnb = wbnb_;
        v2Router = v2Router_;
        v3Router = v3Router_;
        flapPortal = flapPortal_;
    }

    /// @notice Accepts BNB (hook payouts, launch fees, WBNB unwraps with a 2300-gas stipend, portal refunds).
    receive() external payable {}

    /// @inheritdoc IMdaqBuyback
    function collect(bytes32[] calldata poolIds) external override nonReentrant {
        uint256 n = poolIds.length;
        PoolId[] memory ids = new PoolId[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = PoolId.wrap(poolIds[i]);
        }
        (Currency[] memory cs, uint256[] memory amounts) = hook.collectBuyback(ids);
        for (uint256 i; i < cs.length; ++i) {
            emit Collected(Currency.unwrap(cs[i]), amounts[i]);
        }
    }

    /// @inheritdoc IMdaqBuyback
    function swapToBnb(address token, uint256 amountIn, uint256 minOut, uint8 route, bytes calldata routeData)
        external
        override
        onlyKeeper
        nonReentrant
        returns (uint256 bnbOut)
    {
        if (token == address(0) || token == mdaq) revert BadToken();
        if (amountIn == 0) revert BadAmount();
        uint256 balBefore = address(this).balance;
        if (token == wbnb) {
            IWBNB(wbnb).withdraw(amountIn);
        } else {
            _checkPriceBound(token, amountIn, minOut);
            if (route == ROUTE_V2) {
                address[] memory path = abi.decode(routeData, (address[]));
                uint256 n = path.length;
                if (n < 2 || path[0] != token || path[n - 1] != wbnb) revert BadRoute();
                for (uint256 k = 1; k < n - 1; ++k) {
                    if (!routeHops[path[k]]) revert BadRoute();
                }
                IERC20(token).forceApprove(v2Router, amountIn);
                IPancakeV2Router(v2Router)
                    .swapExactTokensForETHSupportingFeeOnTransferTokens(
                        amountIn, minOut, path, address(this), block.timestamp
                    );
            } else if (route == ROUTE_V3) {
                uint24 fee = abi.decode(routeData, (uint24));
                if (fee != 100 && fee != 500 && fee != 2500 && fee != 10_000) revert BadRoute();
                IERC20(token).forceApprove(v3Router, amountIn);
                uint256 wOut = IPancakeV3SwapRouter(v3Router)
                    .exactInputSingle(
                        IPancakeV3SwapRouter.ExactInputSingleParams({
                        tokenIn: token,
                        tokenOut: wbnb,
                        fee: fee,
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountIn: amountIn,
                        amountOutMinimum: minOut,
                        sqrtPriceLimitX96: 0
                    })
                    );
                IWBNB(wbnb).withdraw(wOut);
            } else if (route == 3 && basketGateways[token] != address(0)) {
                address gateway = basketGateways[token];
                uint256[] memory limits = abi.decode(routeData, (uint256[]));
                IERC20(token).forceApprove(gateway, amountIn);
                IDidxRedeemer(gateway).redeemToBnb(amountIn, limits, minOut, address(this), block.timestamp);
                IERC20(token).forceApprove(gateway, 0);
            } else {
                revert BadRoute();
            }
        }
        bnbOut = address(this).balance - balBefore;
        if (bnbOut < minOut) revert TooLittleReceived(bnbOut, minOut);
        emit SwappedToBnb(token, amountIn, bnbOut);
    }

    /// @inheritdoc IMdaqBuyback
    function buyAndBurn(uint256 bnbAmount, uint256 minMdaqOut)
        external
        override
        onlyKeeper
        nonReentrant
        returns (uint256 mdaqBurned)
    {
        address token = mdaq;
        if (token == address(0)) revert MdaqNotSet();
        if (bnbAmount == 0 || bnbAmount > address(this).balance) revert BadAmount();
        uint256 balBefore = address(this).balance;
        IFlapPortalTrade(flapPortal).swapExactInput{value: bnbAmount}(
            IFlapPortalTrade.ExactInputParams({
                inputToken: address(0),
                outputToken: token,
                inputAmount: bnbAmount,
                minOutputAmount: minMdaqOut,
                permitData: ""
            })
        );
        uint256 spent = balBefore - address(this).balance; // portal may refund part of the input
        mdaqBurned = IERC20(token).balanceOf(address(this));
        if (mdaqBurned < minMdaqOut) revert TooLittleReceived(mdaqBurned, minMdaqOut);
        IERC20(token).safeTransfer(DEAD, mdaqBurned);
        totalBnbSpent += spent;
        totalMdaqBurned += mdaqBurned;
        emit BoughtAndBurned(spent, mdaqBurned);
    }

    /// @inheritdoc IMdaqBuyback
    function setMdaq(address mdaq_) external override onlyOwner {
        if (mdaq != address(0)) revert MdaqAlreadySet();
        if (mdaq_ == address(0)) revert ZeroAddress();
        mdaq = mdaq_;
        emit MdaqSet(mdaq_);
    }

    /// @inheritdoc IMdaqBuyback
    function setKeeper(address keeper, bool allowed) external override onlyOwner {
        keepers[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @inheritdoc IMdaqBuyback
    function setFeed(address token, address feed, uint16 maxSlippageBps) external override onlyOwner {
        if (maxSlippageBps > MAX_SLIPPAGE_BPS) revert BadConfig();
        feeds[token] = Feed(feed, maxSlippageBps);
        emit FeedSet(token, feed, maxSlippageBps);
    }

    /// @inheritdoc IMdaqBuyback
    function setRefPrice(address token, uint128 priceUsdE18, uint16 maxSlippageBps) external override onlyOwner {
        if (token == address(0) || maxSlippageBps > MAX_SLIPPAGE_BPS) revert BadConfig();
        if (priceUsdE18 == 0) delete refPrices[token];
        else refPrices[token] = RefPrice(priceUsdE18, uint64(block.timestamp), maxSlippageBps);
        emit RefPriceSet(token, priceUsdE18, maxSlippageBps);
    }

    /// @inheritdoc IMdaqBuyback
    function setRouteHop(address token, bool allowed) external override onlyOwner {
        if (token == address(0)) revert BadConfig();
        routeHops[token] = allowed;
        emit RouteHopSet(token, allowed);
    }

    /// @inheritdoc IMdaqBuyback
    function oracleBnbValue(address token, uint256 amountIn) public view override returns (uint256 value) {
        (uint256 usd,) = _priceBound(token);
        if (usd == 0) return 0;
        address bf = feeds[address(0)].feed;
        if (bf == address(0)) revert NoBnbFeed();
        value = Math.mulDiv(amountIn, usd, 10 ** IERC20Metadata(token).decimals());
        value = Math.mulDiv(value, 1e18, _price(bf));
    }

    /// @dev USD price (18 decimals) and slippage allowance of `token`: its feed if set, else its reference price
    ///      (reverts BadPrice when stale), else (0, 0).
    function _priceBound(address token) internal view returns (uint256 usd, uint16 slippageBps) {
        Feed memory f = feeds[token];
        if (f.feed != address(0)) return (_price(f.feed), f.maxSlippageBps);
        RefPrice memory r = refPrices[token];
        if (r.priceUsdE18 == 0) return (0, 0);
        if (r.updatedAt + REF_PRICE_MAX_AGE < block.timestamp) revert BadPrice();
        return (r.priceUsdE18, r.maxSlippageBps);
    }

    function _checkPriceBound(address token, uint256 amountIn, uint256 minOut) internal view {
        (uint256 usd, uint16 slippageBps) = _priceBound(token);
        if (usd == 0) {
            if (msg.sender != owner()) revert NoPriceBound(token);
            return;
        }
        uint256 floor = oracleBnbValue(token, amountIn) * (10_000 - slippageBps) / 10_000;
        if (minOut < floor) revert MinOutBelowOracle(minOut, floor);
    }

    function _price(address feed) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = IChainlinkFeed(feed).latestRoundData();
        if (answer <= 0 || updatedAt + FEED_MAX_AGE < block.timestamp) revert BadPrice();
        uint256 dec = IChainlinkFeed(feed).decimals();
        return dec <= 18 ? uint256(answer) * 10 ** (18 - dec) : uint256(answer) / 10 ** (dec - 18);
    }
}
