// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ProtocolFeeController} from "infinity-core/src/ProtocolFeeController.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {SqrtPriceMath} from "infinity-core/src/pool-cl/libraries/SqrtPriceMath.sol";
import {MemeDaqLaunchpad} from "../../../src/MemeDaqLaunchpad.sol";
import {MemeDaqHook} from "../../../src/MemeDaqHook.sol";
import {MemeToken} from "../../../src/MemeToken.sol";
import {MemeDaqRouter} from "../../../src/MemeDaqRouter.sol";
import {MdaqBuyback} from "../../../src/MdaqBuyback.sol";
import {IMemeDaqLaunchpad} from "../../../src/interfaces/IMemeDaqLaunchpad.sol";
import {MockERC20, MockFeed} from "../../mocks/Mocks.sol";
import {LRBMockWBNB, LRBMockV2Router, LRBMockV3Router, LRBMockFlapPortal} from "./LRBHelpers.sol";

/// @notice Shared fixture for LaunchpadRouterBuyback.t.sol: fresh local Vault + CLPoolManager + ProtocolFeeController,
///         the MemeDAQ launchpad/hook/router, and an MdaqBuyback wired to mock WBNB / PCS v2 / PCS v3 / Flap Portal.
/// @dev Quote currencies live at fixed digit-only addresses so the currency order is controlled. Memes are mined into
///      (USDT, BTCB): every quote below USDT is currency0 (meme c1), every quote above BTCB is currency1 (meme c0).
abstract contract LRBBase is Test {
    address internal constant BNB = address(0);
    address internal constant BTC6L = 0x1000000000000000000000000000000000000001; // 6 dec, below meme
    address internal constant DOGE8 = 0x2000000000000000000000000000000000000002; // 8 dec, below meme
    address internal constant USDT = 0x3000000000000000000000000000000000000003; // 18 dec, below meme
    address internal constant BTCB = 0x7000000000000000000000000000000000000007; // 18 dec, above meme
    address internal constant USELESS6 = 0x8000000000000000000000000000000000000008; // 6 dec MANUAL, above meme
    address internal constant ALPHA9 = 0x9000000000000000000000000000000000000009; // 9 dec, unconfigured
    address internal constant BTC6H = 0x9900000000000000000000000000000000000099; // 6 dec, above meme
    address internal constant CAKE = 0xC00000000000000000000000000000000000000C; // 18 dec, above meme
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    int24 internal constant MIN_USABLE = -887_200;
    int24 internal constant MAX_USABLE = 887_200;
    uint256 internal constant T0 = 1_800_000_000;
    uint256 internal constant B0 = 1_000;
    bytes4 internal constant OWNABLE_UNAUTHORIZED = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));

    Vault internal vault;
    CLPoolManager internal pm;
    MemeDaqLaunchpad internal lp;
    MemeDaqHook internal hook;
    MemeDaqRouter internal router;
    MdaqBuyback internal bb;
    LRBMockWBNB internal wbnb;
    LRBMockV2Router internal v2;
    LRBMockV3Router internal v3;
    LRBMockFlapPortal internal portal;
    MockERC20 internal mdaq;

    MockFeed internal bnbFeed;
    MockFeed internal usdtFeed;
    MockFeed internal cakeFeed;
    MockFeed internal btcFeed;
    MockFeed internal dogeFeed;

    address internal owner = address(this);
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal attacker = makeAddr("attacker");
    address internal keeper = makeAddr("keeper");

    receive() external payable {}

    function setUp() public virtual {
        vm.warp(T0);
        vm.roll(B0);

        vault = new Vault();
        pm = new CLPoolManager(vault);
        vault.registerApp(address(pm));
        ProtocolFeeController pfc = new ProtocolFeeController(address(pm));
        pfc.setProtocolFeeSplitRatio(330_000);
        pm.setProtocolFeeController(IProtocolFeeController(address(pfc)));

        _token(BTC6L, "Bitcoin6 Low", "BTC6L", 6);
        _token(DOGE8, "Dogecoin", "DOGE", 8);
        _token(USDT, "Tether USD", "USDT", 18);
        _token(BTCB, "BTCB Token", "BTCB", 18);
        _token(USELESS6, "Useless", "USELESS", 6);
        _token(ALPHA9, "Alpha", "ALPHA", 9);
        _token(BTC6H, "Bitcoin6 High", "BTC6H", 6);
        _token(CAKE, "PancakeSwap Token", "Cake", 18);

        bnbFeed = new MockFeed(8, 600e8);
        usdtFeed = new MockFeed(8, 1e8);
        cakeFeed = new MockFeed(8, 2.5e8);
        btcFeed = new MockFeed(8, 76_157e8);
        dogeFeed = new MockFeed(8, 0.2e8);

        lp = new MemeDaqLaunchpad(vault, pm, owner);
        hook = MemeDaqHook(lp.hook());
        router = new MemeDaqRouter(vault, pm, lp);

        wbnb = new LRBMockWBNB();
        v2 = new LRBMockV2Router();
        v3 = new LRBMockV3Router(wbnb);
        mdaq = new MockERC20("MemeDAQ", "MDAQ", 18);
        portal = new LRBMockFlapPortal(mdaq);
        vm.deal(address(v2), 1_000_000 ether);
        vm.deal(address(v3), 1_000_000 ether);
        bb = new MdaqBuyback(owner, hook, address(wbnb), address(v2), address(v3), address(portal));
        lp.setBuyback(address(bb));

        lp.setQuote(BNB, _chainlink(true, 18, 10_000, 3600, address(bnbFeed)));
        lp.setQuote(USDT, _chainlink(false, 18, 3000, 86_400, address(usdtFeed)));
        lp.setQuote(CAKE, _chainlink(false, 18, 3000, 3600, address(cakeFeed)));
        lp.setQuote(BTCB, _chainlink(false, 18, 3000, 3600, address(btcFeed)));
        lp.setQuote(DOGE8, _chainlink(false, 8, 3000, 3600, address(dogeFeed)));
        lp.setQuote(BTC6L, _chainlink(false, 6, 3000, 3600, address(btcFeed)));
        lp.setQuote(BTC6H, _chainlink(false, 6, 3000, 3600, address(btcFeed)));
        lp.setQuote(USELESS6, _manual(6, 500, 600));
        lp.setManualPrice(USELESS6, 0.3e18);

        _fund(alice);
        _fund(bob);
        _fund(carol);
        _fund(creator);
        _fund(attacker);
    }

    // ------------------------------------------------------------------
    // fixture helpers
    // ------------------------------------------------------------------

    function _token(address at, string memory n, string memory s, uint8 d) internal {
        deployCodeTo("Mocks.sol:MockERC20", abi.encode(n, s, d), at);
    }

    function _chainlink(bool hub, uint8 dec, uint16 maxW, uint32 maxAge, address feed)
        internal
        pure
        returns (IMemeDaqLaunchpad.QuoteConfig memory c)
    {
        c.enabled = true;
        c.isHub = hub;
        c.decimals = dec;
        c.source = IMemeDaqLaunchpad.PriceSource.CHAINLINK;
        c.maxWeightBps = maxW;
        c.maxAge = maxAge;
        c.feed = feed;
    }

    function _manual(uint8 dec, uint16 maxW, uint32 maxAge) internal pure returns (IMemeDaqLaunchpad.QuoteConfig memory c) {
        c.enabled = true;
        c.decimals = dec;
        c.source = IMemeDaqLaunchpad.PriceSource.MANUAL;
        c.maxWeightBps = maxW;
        c.maxAge = maxAge;
    }

    function _fund(address who) internal {
        vm.deal(who, 10_000 ether);
        address[7] memory ts = [BTC6L, DOGE8, USDT, BTCB, USELESS6, BTC6H, CAKE];
        vm.startPrank(who);
        for (uint256 i; i < ts.length; ++i) {
            MockERC20(ts[i]).mint(who, 1e30);
            MockERC20(ts[i]).approve(address(router), type(uint256).max);
        }
        vm.stopPrank();
    }

    function _approveMeme(address m, address who) internal {
        vm.prank(who);
        MemeToken(m).approve(address(router), type(uint256).max);
    }

    function _setFeeds(int256 bnbPx, int256 usdtPx, int256 cakePx, int256 btcPx) internal {
        bnbFeed.set(bnbPx, block.timestamp);
        usdtFeed.set(usdtPx, block.timestamp);
        cakeFeed.set(cakePx, block.timestamp);
        btcFeed.set(btcPx, block.timestamp);
    }

    // ------------------------------------------------------------------
    // allocations / params
    // ------------------------------------------------------------------

    function _q(address a, uint16 wa) internal pure returns (IMemeDaqLaunchpad.QuoteAlloc[] memory q) {
        q = new IMemeDaqLaunchpad.QuoteAlloc[](1);
        q[0] = IMemeDaqLaunchpad.QuoteAlloc(a, wa);
    }

    function _q(address a, uint16 wa, address b, uint16 wb)
        internal
        pure
        returns (IMemeDaqLaunchpad.QuoteAlloc[] memory q)
    {
        q = new IMemeDaqLaunchpad.QuoteAlloc[](2);
        q[0] = IMemeDaqLaunchpad.QuoteAlloc(a, wa);
        q[1] = IMemeDaqLaunchpad.QuoteAlloc(b, wb);
    }

    function _q(address a, uint16 wa, address b, uint16 wb, address c, uint16 wc)
        internal
        pure
        returns (IMemeDaqLaunchpad.QuoteAlloc[] memory q)
    {
        q = new IMemeDaqLaunchpad.QuoteAlloc[](3);
        q[0] = IMemeDaqLaunchpad.QuoteAlloc(a, wa);
        q[1] = IMemeDaqLaunchpad.QuoteAlloc(b, wb);
        q[2] = IMemeDaqLaunchpad.QuoteAlloc(c, wc);
    }

    function _q(address a, uint16 wa, address b, uint16 wb, address c, uint16 wc, address d, uint16 wd)
        internal
        pure
        returns (IMemeDaqLaunchpad.QuoteAlloc[] memory q)
    {
        q = new IMemeDaqLaunchpad.QuoteAlloc[](4);
        q[0] = IMemeDaqLaunchpad.QuoteAlloc(a, wa);
        q[1] = IMemeDaqLaunchpad.QuoteAlloc(b, wb);
        q[2] = IMemeDaqLaunchpad.QuoteAlloc(c, wc);
        q[3] = IMemeDaqLaunchpad.QuoteAlloc(d, wd);
    }

    function _std3() internal pure returns (IMemeDaqLaunchpad.QuoteAlloc[] memory) {
        return _q(BNB, 6000, USDT, 2000, CAKE, 2000);
    }

    function _mineSalt(address who, string memory tag) internal view returns (bytes32 salt) {
        for (uint256 i;; ++i) {
            salt = keccak256(abi.encode(tag, i));
            address a = lp.predictMemeAddress(who, salt);
            if (a > USDT && a < BTCB && a.code.length == 0) return salt;
        }
    }

    function _params(IMemeDaqLaunchpad.QuoteAlloc[] memory q, uint256 devBuy, bytes32 salt)
        internal
        pure
        returns (IMemeDaqLaunchpad.LaunchParams memory p)
    {
        p.name = "Meme Dog";
        p.symbol = "MDOG";
        p.meta = '{"image":"https://x/y.png"}';
        p.salt = salt;
        p.quotes = q;
        p.devBuyBnb = devBuy;
    }

    function _launch(address who, IMemeDaqLaunchpad.QuoteAlloc[] memory q, uint256 devBuy, string memory tag)
        internal
        returns (address m)
    {
        bytes32 salt = _mineSalt(who, tag);
        address predicted = lp.predictMemeAddress(who, salt);
        uint256 value = devBuy + lp.launchFee(); // read before the prank (a view call would consume it)
        vm.prank(who);
        m = lp.launch{value: value}(_params(q, devBuy, salt));
        assertEq(m, predicted, "predicted address");
    }

    function _expectLaunchRevert(address who, IMemeDaqLaunchpad.LaunchParams memory p, uint256 value, bytes memory err)
        internal
    {
        vm.prank(who);
        vm.expectRevert(err);
        lp.launch{value: value}(p);
    }

    // ------------------------------------------------------------------
    // views
    // ------------------------------------------------------------------

    function _bal(address c, address who) internal view returns (uint256) {
        return c == BNB ? who.balance : MockERC20(c).balanceOf(who);
    }

    function _claims(address c) internal view returns (uint256) {
        return vault.balanceOf(address(hook), Currency.wrap(c));
    }

    function _owed(PoolId id) internal view returns (uint256 liability, uint256 buybackOwed) {
        (,,,,, uint128 l, uint128 b) = hook.poolInfo(id);
        return (l, b);
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    /// @dev The seeded position of `m` in pool `k` (owner = launchpad, salt 0) and its meme amount (rounded up, like
    ///      the pool manager does when adding liquidity).
    function _position(address m, PoolKey memory k, int24 startTick)
        internal
        view
        returns (uint256 memeAmt, uint128 liquidity, uint160 sa, uint160 sb, bool memeIs0)
    {
        memeIs0 = Currency.unwrap(k.currency0) == m;
        (int24 lo, int24 hi) = memeIs0 ? (startTick, MAX_USABLE) : (MIN_USABLE, startTick);
        liquidity = pm.getLiquidity(k.toId(), address(lp), lo, hi, bytes32(0));
        sa = TickMath.getSqrtRatioAtTick(lo);
        sb = TickMath.getSqrtRatioAtTick(hi);
        memeAmt = memeIs0
            ? SqrtPriceMath.getAmount0Delta(sa, sb, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(sa, sb, liquidity, true);
    }

    /// @dev ERC-7751 wrapped hook revert as produced by the local infinity-core Hooks library.
    function _wrappedHookError(bytes4 hookFn, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            hookFn,
            reason,
            abi.encodePacked(Hooks.HookCallFailed.selector)
        );
    }

    function _afterSwapSel() internal pure returns (bytes4) {
        return ICLHooks.afterSwap.selector;
    }

    function _beforeSwapSel() internal pure returns (bytes4) {
        return ICLHooks.beforeSwap.selector;
    }

    function _routerEmpty(address m, address[] memory cs) internal view {
        assertEq(address(router).balance, 0, "router holds no BNB");
        assertEq(MemeToken(m).balanceOf(address(router)), 0, "router holds no meme");
        assertEq(vault.balanceOf(address(router), Currency.wrap(m)), 0, "router holds no meme claims");
        for (uint256 i; i < cs.length; ++i) {
            if (cs[i] != BNB) assertEq(MockERC20(cs[i]).balanceOf(address(router)), 0, "router holds no quote");
            assertEq(vault.balanceOf(address(router), Currency.wrap(cs[i])), 0, "router holds no quote claims");
        }
    }

    /// @dev hook claims per currency == sum of (liability + buybackOwed) of the given pools quoted in it
    function _checkInvariant(PoolId[] memory ids, address[] memory cs) internal view {
        for (uint256 k; k < cs.length; ++k) {
            uint256 sum;
            for (uint256 i; i < ids.length; ++i) {
                if (Currency.unwrap(hook.quoteOf(ids[i])) != cs[k]) continue;
                (uint256 l, uint256 b) = _owed(ids[i]);
                sum += l + b;
            }
            assertEq(_claims(cs[k]), sum, "invariant: hook claims == liabilities + buybackOwed");
        }
    }

    function _methodSignatures(string memory contractName) internal view returns (string[] memory) {
        string memory path = string.concat("out/", contractName, ".sol/", contractName, ".json");
        string memory json = vm.readFile(path);
        return vm.parseJsonKeys(json, ".methodIdentifiers");
    }

    function _contains(string[] memory list, string memory item) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (keccak256(bytes(list[i])) == keccak256(bytes(item))) return true;
        }
        return false;
    }

    function _hasSubstring(string memory s, string memory sub) internal pure returns (bool) {
        bytes memory a = bytes(_lower(s));
        bytes memory b = bytes(sub);
        if (b.length > a.length) return false;
        for (uint256 i; i + b.length <= a.length; ++i) {
            bool eq = true;
            for (uint256 j; j < b.length; ++j) {
                if (a[i + j] != b[j]) {
                    eq = false;
                    break;
                }
            }
            if (eq) return true;
        }
        return false;
    }

    /// @dev Lower-cased copy (bytes(s) aliases s, so copy before editing).
    function _lower(string memory s) internal pure returns (string memory) {
        bytes memory src = bytes(s);
        bytes memory b = new bytes(src.length);
        for (uint256 i; i < src.length; ++i) {
            bytes1 ch = src[i];
            b[i] = (ch >= 0x41 && ch <= 0x5a) ? bytes1(uint8(ch) + 32) : ch;
        }
        return string(b);
    }
}
