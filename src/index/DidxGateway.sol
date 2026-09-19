// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DidxBasket} from "./DidxBasket.sol";
import {IMemeDaqRouter} from "../interfaces/IMemeDaqRouter.sol";
import {IPancakeV3SwapRouter} from "../MdaqBuyback.sol";

interface IDidxWbnb is IERC20 { function deposit() external payable; function withdraw(uint256) external; }
interface IDidxV2Router {
    function factory() external view returns (address);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[] calldata,address,uint256) external;
}
interface IDidxV3Router { function factory() external view returns (address); }
interface IDidxFactory {
    function getPair(address,address) external view returns (address);
    function getPool(address,address,uint24) external view returns (address);
}

/// @notice Immutable, factory-checked routes. No arbitrary calls, recipient overrides or owner approvals.
/// Each leg has its own minimum net output; all input must be consumed or the transaction reverts.
contract DidxGateway is ReentrancyGuard {
    using SafeERC20 for IERC20;
    struct Hop { address tokenOut; uint24 fee; } // fee zero: V2, otherwise V3
    DidxBasket public immutable basket;
    IMemeDaqRouter public immutable memeRouter;
    IDidxWbnb public immutable wbnb;
    address public immutable v2Router;
    address public immutable v3Router;
    uint256 public immutable legCount;
    Hop[][4] private _routes;
    error InvalidInput();
    error Slippage();
    event MintedFromBnb(address indexed payer, address indexed receiver, uint256 bnbIn, uint256 shares, address meme, uint256 memeOut);
    event RedeemedToBnb(address indexed payer, address indexed receiver, uint256 shares, uint256 bnbOut);

    constructor(DidxBasket basket_, IMemeDaqRouter memeRouter_, IDidxWbnb wbnb_, address v2_, address v3_, Hop[][4] memory routes) {
        basket = basket_; memeRouter = memeRouter_; wbnb = wbnb_; v2Router = v2_; v3Router = v3_;
        address[4] memory assets = basket_.assets();
        address f2 = IDidxV2Router(v2_).factory();
        address f3 = IDidxV3Router(v3_).factory();
        uint256 count;
        for (uint256 i; i < 4; ++i) {
            address input = address(wbnb_);
            if (routes[i].length == 0 || routes[i].length > 4) revert InvalidInput();
            for (uint256 j; j < routes[i].length; ++j) {
                Hop memory h = routes[i][j];
                if (h.tokenOut == input || h.tokenOut == address(basket_) || h.tokenOut == address(wbnb_)) revert InvalidInput();
                address pool = h.fee == 0 ? IDidxFactory(f2).getPair(input,h.tokenOut) : IDidxFactory(f3).getPool(input,h.tokenOut,h.fee);
                if (pool.code.length == 0) revert InvalidInput();
                _routes[i].push(h); input = h.tokenOut; ++count;
            }
            if (input != assets[i]) revert InvalidInput();
        }
        legCount = count;
    }
    receive() external payable { if (msg.sender != address(wbnb)) revert InvalidInput(); }
    function route(uint256 i) external view returns (Hop[] memory) { return _routes[i]; }

    /// @notice Also used to acquire bootstrap assets. Caller keeps all four tokens; no share claim is implied.
    function buyAssets(uint256[4] calldata bnbAmounts, uint256[] calldata minLegOut, address receiver, uint256 deadline)
        external payable nonReentrant returns (uint256[4] memory amounts, uint256[] memory legAmounts)
    {
        _validate(receiver, deadline, minLegOut.length);
        (amounts,legAmounts) = _acquire(bnbAmounts,minLegOut,deadline);
        address[4] memory assets = basket.assets();
        for (uint256 i; i < 4; ++i) IERC20(assets[i]).safeTransfer(receiver,amounts[i]);
    }

    /// @notice BNB -> four real memes -> dIDX -> optional meme/dIDX trade, atomically.
    function mintFromBnb(uint256[4] calldata bnbAmounts, uint256[] calldata minLegOut, uint256 minShares,
        uint16 maxSurplusBps, address meme, uint256 minMemeOut, address receiver, uint256 deadline)
        external payable nonReentrant returns (uint256 shares, uint256 memeOut, uint256[] memory legAmounts)
    {
        _validate(receiver, deadline, minLegOut.length);
        uint256[4] memory amounts;
        (amounts,legAmounts) = _acquire(bnbAmounts,minLegOut,deadline);
        address[4] memory assets = basket.assets();
        for (uint256 i; i < 4; ++i) IERC20(assets[i]).forceApprove(address(basket),amounts[i]);
        shares = basket.deposit(amounts,minShares,maxSurplusBps,address(this),deadline);
        for (uint256 i; i < 4; ++i) IERC20(assets[i]).forceApprove(address(basket),0);
        if (meme == address(0)) IERC20(address(basket)).safeTransfer(receiver,shares);
        else {
            if (minMemeOut == 0) revert InvalidInput();
            IERC20(address(basket)).forceApprove(address(memeRouter),shares);
            memeOut = memeRouter.buy(meme,address(basket),shares,minMemeOut,receiver,deadline);
            IERC20(address(basket)).forceApprove(address(memeRouter),0);
        }
        emit MintedFromBnb(msg.sender,receiver,msg.value,shares,meme,memeOut);
    }

    /// @notice dIDX -> proportional net asset receipts -> BNB. All four routes must be executable.
    function redeemToBnb(uint256 shares, uint256[] calldata minLegOut, uint256 minBnbOut, address receiver, uint256 deadline)
        external nonReentrant returns (uint256 out, uint256[] memory legAmounts)
    {
        _validate(receiver,deadline,minLegOut.length);
        if (minBnbOut == 0) revert InvalidInput();
        IERC20(address(basket)).safeTransferFrom(msg.sender,address(this),shares);
        uint256[4] memory zeros;
        uint256[4] memory amounts = basket.redeem(shares,zeros,address(this),deadline);
        uint256 cursor;
        legAmounts = new uint256[](legCount);
        for (uint256 i; i < 4; ++i) {
            Hop[] storage path = _routes[i];
            uint256 amount = amounts[i];
            for (uint256 j = path.length; j > 0; --j) {
                address target = j == 1 ? address(wbnb) : path[j-2].tokenOut;
                amount = _swap(path[j-1].tokenOut,target,path[j-1].fee,amount,minLegOut[cursor],deadline);
                legAmounts[cursor++] = amount;
            }
            out += amount;
        }
        if (out < minBnbOut) revert Slippage();
        wbnb.withdraw(out);
        (bool ok,) = receiver.call{value:out}("");
        if (!ok) revert InvalidInput();
        emit RedeemedToBnb(msg.sender,receiver,shares,out);
    }

    function _acquire(uint256[4] calldata bnbAmounts, uint256[] calldata limits, uint256 deadline)
        private returns (uint256[4] memory amounts, uint256[] memory legAmounts)
    {
        uint256 sum;
        for (uint256 i; i < 4; ++i) { if (bnbAmounts[i] == 0) revert InvalidInput(); sum += bnbAmounts[i]; }
        if (sum != msg.value) revert InvalidInput();
        wbnb.deposit{value:sum}();
        uint256 cursor;
        legAmounts = new uint256[](legCount);
        for (uint256 i; i < 4; ++i) {
            address input = address(wbnb);
            uint256 amount = bnbAmounts[i];
            for (uint256 j; j < _routes[i].length; ++j) {
                Hop memory h = _routes[i][j];
                amount = _swap(input,h.tokenOut,h.fee,amount,limits[cursor],deadline);
                legAmounts[cursor++] = amount;
                input = h.tokenOut;
            }
            amounts[i] = amount;
        }
    }
    function _swap(address input,address output,uint24 fee,uint256 amount,uint256 minimum,uint256 deadline)
        private returns(uint256 received)
    {
        if (amount == 0 || minimum == 0) revert InvalidInput();
        IERC20 tin = IERC20(input); IERC20 tout = IERC20(output);
        uint256 beforeIn = tin.balanceOf(address(this));
        uint256 beforeOut = tout.balanceOf(address(this));
        address router = fee == 0 ? v2Router : v3Router;
        tin.forceApprove(router,amount);
        if (fee == 0) {
            address[] memory path = new address[](2); path[0] = input; path[1] = output;
            IDidxV2Router(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(amount,minimum,path,address(this),deadline);
        } else {
            IPancakeV3SwapRouter(router).exactInputSingle(IPancakeV3SwapRouter.ExactInputSingleParams(
                input,output,fee,address(this),deadline,amount,minimum,0));
        }
        tin.forceApprove(router,0);
        if (tin.balanceOf(address(this)) != beforeIn - amount) revert Slippage();
        received = tout.balanceOf(address(this)) - beforeOut;
        if (received < minimum) revert Slippage();
    }
    function _validate(address receiver,uint256 deadline,uint256 count) private view {
        if (receiver == address(0) || receiver == address(this) || block.timestamp > deadline || count != legCount) revert InvalidInput();
    }
}
