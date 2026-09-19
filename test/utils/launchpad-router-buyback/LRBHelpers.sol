// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {MockERC20} from "../../mocks/Mocks.sol";
import {IMemeDaqRouter} from "../../../src/interfaces/IMemeDaqRouter.sol";

/// @notice Independent start-tick references for StartPrice (test only).
/// @dev Reference A never takes a square root: it binary-searches the aligned tick grid and compares
///      getSqrtRatioAtTick(T)^2 * den with num * 2^192 exactly in 512-bit arithmetic.
///      Reference B takes its own Babylonian integer square root of the Q192 price and uses getTickAtSqrtRatio.
///      Both use the same "meme price never below target" rule as the spec: meme c1 → largest aligned tick with
///      price(T) <= P, meme c0 → smallest aligned tick with price(T) >= P. P = raw currency1 per raw currency0.
library LRBRefTick {
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;
    int256 internal constant SPACING = 200;
    int256 internal constant MIN_IDX = -4436; // minUsableTick(200) / 200
    int256 internal constant MAX_IDX = 4436; // maxUsableTick(200) / 200
    int24 internal constant MIN_USABLE = -887_200;
    int24 internal constant MAX_USABLE = 887_200;

    /// @notice num / den of the raw pool price (currency1 per currency0).
    function ratio(uint256 fdv, uint256 px, uint8 dec, bool memeIs0) internal pure returns (uint256 num, uint256 den) {
        uint256 scale = 10 ** uint256(dec);
        (num, den) = memeIs0 ? (fdv * scale, px * TOTAL_SUPPLY) : (px * TOTAL_SUPPLY, fdv * scale);
    }

    function _mul512(uint256 a, uint256 b) private pure returns (uint256 hi, uint256 lo) {
        unchecked {
            lo = a * b;
            uint256 mm = mulmod(a, b, type(uint256).max);
            hi = mm - lo - (mm < lo ? 1 : 0);
        }
    }

    /// @notice sign(sqrtRatio(tick)^2 * den - num * 2^192), exact.
    function cmp(int24 tick, uint256 num, uint256 den) internal pure returns (int256) {
        uint256 s = TickMath.getSqrtRatioAtTick(tick);
        (uint256 h1, uint256 l1) = _mul512(s, s); // < 2^320
        (uint256 h2, uint256 l2) = _mul512(l1, den);
        uint256 hi = h1 * den + h2; // checked: requires den < 2^191
        uint256 rhi = num >> 64;
        uint256 rlo = num << 192;
        if (hi != rhi) return hi < rhi ? -1 : int256(1);
        if (l2 != rlo) return l2 < rlo ? -1 : int256(1);
        return 0;
    }

    /// @notice Reference A. `ok == false` means StartPrice must revert (price outside the usable range).
    function tickA(uint256 fdv, uint256 px, uint8 dec, bool memeIs0) internal pure returns (int24 tick, bool ok) {
        if (fdv == 0 || px == 0) return (0, false);
        (uint256 num, uint256 den) = ratio(fdv, px, dec, memeIs0);
        int256 lo = MIN_IDX;
        int256 hi = MAX_IDX;
        if (!memeIs0) {
            if (cmp(int24(lo * SPACING), num, den) > 0) return (0, false);
            while (lo < hi) {
                int256 mid = lo + (hi - lo + 1) / 2;
                if (cmp(int24(mid * SPACING), num, den) <= 0) lo = mid;
                else hi = mid - 1;
            }
        } else {
            if (cmp(int24(hi * SPACING), num, den) < 0) return (0, false);
            while (lo < hi) {
                int256 mid = lo + (hi - lo) / 2;
                if (cmp(int24(mid * SPACING), num, den) >= 0) hi = mid;
                else lo = mid + 1;
            }
        }
        tick = int24(lo * SPACING);
        ok = tick > MIN_USABLE && tick < MAX_USABLE;
    }

    /// @notice Babylonian integer square root (floor).
    function isqrt(uint256 x) internal pure returns (uint256 z) {
        if (x < 4) return x == 0 ? 0 : 1;
        z = x;
        uint256 y = x / 2 + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }

    /// @notice Reference B (only defined for num / den < 2^64). `applicable == false` otherwise.
    function tickB(uint256 fdv, uint256 px, uint8 dec, bool memeIs0)
        internal
        pure
        returns (int24 tick, bool ok, bool applicable)
    {
        if (fdv == 0 || px == 0) return (0, false, true);
        (uint256 num, uint256 den) = ratio(fdv, px, dec, memeIs0);
        if (num / den >= (1 << 64)) return (0, false, false);
        applicable = true;
        uint256 s = isqrt(FullMath.mulDiv(num, 1 << 192, den));
        if (s < TickMath.MIN_SQRT_RATIO || s >= TickMath.MAX_SQRT_RATIO) return (0, false, true);
        int256 t = TickMath.getTickAtSqrtRatio(uint160(s));
        // floor division towards -inf, written differently from the library
        int256 idx = t >= 0 ? t / SPACING : -((-t + SPACING - 1) / SPACING);
        int256 aligned = idx * SPACING;
        if (memeIs0 && uint256(TickMath.getSqrtRatioAtTick(int24(aligned))) < s) aligned += SPACING;
        tick = int24(aligned);
        ok = tick > MIN_USABLE && tick < MAX_USABLE;
    }
}

/// @notice EVM bytecode walker (test only).
library LRBCode {
    /// @notice Counts DELEGATECALL / CALLCODE / SELFDESTRUCT opcodes in runtime code (PUSH data and CBOR metadata skipped).
    function dangerousOpcodes(bytes memory code)
        internal
        pure
        returns (uint256 delegatecalls, uint256 callcodes, uint256 selfdestructs)
    {
        uint256 n = code.length;
        if (n >= 2) {
            uint256 metaLen = (uint256(uint8(code[n - 2])) << 8) | uint256(uint8(code[n - 1]));
            if (metaLen + 2 <= n) n -= metaLen + 2;
        }
        // solc via-IR may append the Ownable event topic as CODECOPY data after INVALID.
        // Match this exact constant, rather than interpreting its hash bytes as executable opcodes.
        if (n >= 33 && code[n - 33] == bytes1(0xfe)) {
            bytes32 tail;
            assembly ("memory-safe") { tail := mload(add(code, n)) }
            if (tail == keccak256("OwnershipTransferred(address,address)")) n -= 33;
        }
        for (uint256 i; i < n; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else if (op == 0xf4) {
                ++delegatecalls;
            } else if (op == 0xf2) {
                ++callcodes;
            } else if (op == 0xff) {
                ++selfdestructs;
            }
        }
    }
}

/// @notice Minimal WBNB (withdraw pays with a 2300-gas `transfer`, like the real WBNB).
contract LRBMockWBNB {
    string public name = "Wrapped BNB";
    string public symbol = "WBNB";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 wad) external {
        require(balanceOf[msg.sender] >= wad, "WBNB: balance");
        balanceOf[msg.sender] -= wad;
        payable(msg.sender).transfer(wad);
    }

    function totalSupply() external view returns (uint256) {
        return address(this).balance;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return transferFrom(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(balanceOf[from] >= amount, "WBNB: balance");
        if (from != msg.sender && allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "WBNB: allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice PancakeSwap v2 router stand-in: fixed BNB-per-token rate, pays native BNB.
contract LRBMockV2Router {
    mapping(address => uint256) public rate; // BNB wei per raw token unit, 1e18-scaled
    bool public ignoreMin;
    address public lastTo;
    uint256 public lastDeadline;
    uint256 public lastPathLength;
    uint256 public calls;

    receive() external payable {}

    function setRate(address token, uint256 r) external {
        rate[token] = r;
    }

    function setIgnoreMin(bool v) external {
        ignoreMin = v;
    }

    function quote(address token, uint256 amountIn) public view returns (uint256) {
        return amountIn * rate[token] / 1e18;
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        require(deadline >= block.timestamp, "PancakeRouter: EXPIRED");
        MockERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = quote(path[0], amountIn);
        require(ignoreMin || out >= amountOutMin, "PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        lastTo = to;
        lastDeadline = deadline;
        lastPathLength = path.length;
        ++calls;
        (bool ok,) = to.call{value: out}("");
        require(ok, "PancakeRouter: ETH_TRANSFER_FAILED");
    }
}

/// @notice PancakeSwap v3 SwapRouter stand-in: exactInputSingle token -> WBNB at a fixed rate.
contract LRBMockV3Router {
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

    LRBMockWBNB public immutable wbnb;
    mapping(address => uint256) public rate;
    bool public ignoreMin;
    uint24 public lastFee;
    address public lastRecipient;
    uint256 public lastDeadline;
    uint160 public lastLimit;
    uint256 public calls;

    constructor(LRBMockWBNB wbnb_) {
        wbnb = wbnb_;
    }

    receive() external payable {}

    function setRate(address token, uint256 r) external {
        rate[token] = r;
    }

    function setIgnoreMin(bool v) external {
        ignoreMin = v;
    }

    function quote(address token, uint256 amountIn) public view returns (uint256) {
        return amountIn * rate[token] / 1e18;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        require(p.deadline >= block.timestamp, "Transaction too old");
        require(p.tokenOut == address(wbnb), "tokenOut");
        MockERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        out = quote(p.tokenIn, p.amountIn);
        require(ignoreMin || out >= p.amountOutMinimum, "Too little received");
        lastFee = p.fee;
        lastRecipient = p.recipient;
        lastDeadline = p.deadline;
        lastLimit = p.sqrtPriceLimitX96;
        ++calls;
        wbnb.deposit{value: out}();
        wbnb.transfer(p.recipient, out);
    }
}

/// @notice Flap Portal stand-in: swapExactInput BNB -> token at a fixed rate, optional partial refund.
contract LRBMockFlapPortal {
    struct ExactInputParams {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 minOutputAmount;
        bytes permitData;
    }

    MockERC20 public immutable token;
    uint256 public rate = 1_000_000e18; // tokens per BNB, 1e18-scaled
    uint256 public refundBps;
    uint256 public lastPermitLength;
    address public lastCaller;

    constructor(MockERC20 token_) {
        token = token_;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function setRefundBps(uint256 bps) external {
        refundBps = bps;
    }

    function swapExactInput(ExactInputParams calldata p) external payable returns (uint256 out) {
        require(p.inputToken == address(0), "portal: input");
        require(p.outputToken == address(token), "portal: output");
        require(msg.value == p.inputAmount, "portal: value");
        uint256 refund = msg.value * refundBps / 10_000;
        out = (msg.value - refund) * rate / 1e18;
        require(out >= p.minOutputAmount, "portal: slippage");
        lastPermitLength = p.permitData.length;
        lastCaller = msg.sender;
        token.mint(msg.sender, out);
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "portal: refund");
        }
    }
}

/// @notice Receives BNB from a router sell and tries to re-enter the router; records the revert data.
contract LRBReentrantReceiver {
    IMemeDaqRouter public immutable router;
    address public meme;
    bytes public lastError;
    bool public tried;

    constructor(IMemeDaqRouter router_) {
        router = router_;
    }

    function setMeme(address m) external {
        meme = m;
    }

    receive() external payable {
        if (tried) return;
        tried = true;
        try router.buy{value: 1e9}(meme, address(0), 1e9, 0, address(this), block.timestamp) {}
        catch (bytes memory err) {
            lastError = err;
        }
    }
}

/// @notice Contract without receive/fallback: rejects native BNB.
contract LRBRejecter {
    function ping() external pure returns (bool) {
        return true;
    }
}
