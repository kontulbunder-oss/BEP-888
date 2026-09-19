// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {MemeBasketIndex} from "../src/index/MemeBasketIndex.sol";
import {IIndexPriceSource} from "../src/index/IIndexPriceSource.sol";
import {V2IndexSource, V3IndexSource, ChainlinkIndexSource} from "../src/index/IndexPriceSources.sol";

contract IndexTestToken { uint8 public immutable decimals; constructor(uint8 d) { decimals = d; } }
contract IndexTestSource is IIndexPriceSource {
    address public baseToken;
    uint256 public value = 1e18;
    bool public invalid;
    uint256 public updates;
    constructor(address token) { baseToken = token; }
    function set(uint256 v) external { value = v; }
    function fail(bool v) external { invalid = v; }
    function priceUsd() external view returns (uint256, uint256) { require(!invalid, "source unavailable"); return (value, block.timestamp); }
    function update() external { ++updates; }
}
contract IndexTestPair {
    address public token0;
    address public token1;
    uint112 internal r0 = 100e18;
    uint112 internal r1 = 200e18;
    uint32 internal time;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    constructor(address a, address b) { token0 = a; token1 = b; time = uint32(block.timestamp); }
    function getPair(address, address) external view returns (address) { return address(this); }
    function getReserves() external view returns (uint112, uint112, uint32) { return (r0, r1, time); }
    function setReserves(uint112 a, uint112 b) external {
        unchecked {
            uint32 elapsed = uint32(block.timestamp) - time;
            price0CumulativeLast += (uint256(r1) << 112) / r0 * elapsed;
            price1CumulativeLast += (uint256(r0) << 112) / r1 * elapsed;
        }
        r0 = a; r1 = b; time = uint32(block.timestamp);
    }
    function cumulative(uint256 a, uint256 b) external { price0CumulativeLast = a; price1CumulativeLast = b; }
}

contract BasketIndexTest is Test {
    MemeBasketIndex index;
    IndexTestSource[5] sources;
    address[5] tokens;
    function setUp() public {
        vm.warp(1_000_000);
        index = new MemeBasketIndex(address(this));
        for (uint256 i; i < 5; ++i) {
            tokens[i] = address(new IndexTestToken(18));
            sources[i] = new IndexTestSource(tokens[i]);
            sources[i].set((i + 1) * 1e18);
        }
    }
    function _basket(uint256 n) internal view returns (MemeBasketIndex.ComponentInput[] memory b) {
        b = new MemeBasketIndex.ComponentInput[](n);
        for (uint256 i; i < n; ++i) b[i] = MemeBasketIndex.ComponentInput(tokens[i], sources[i], uint16(10000 / n));
    }
    function test_equalWeight_normalizesDifferentPrices() public {
        index.initialize(_basket(4));
        (uint256 p,) = index.latestIndex(); assertEq(p, 1000e18);
        sources[3].set(8e18);
        (p,) = index.latestIndex(); assertEq(p, 1250e18);
        sources[0].set(5e17);
        (p,) = index.latestIndex(); assertEq(p, 1125e18);
    }
    function testFuzz_uniformReturn(uint128 price) public {
        uint256 x = bound(price, 1e9, 1e30);
        index.initialize(_basket(4));
        for (uint256 i; i < 4; ++i) sources[i].set(x * (i + 1));
        (uint256 p,) = index.latestIndex(); assertApproxEqAbs(p, x * 1000, 1000);
    }
    function test_addFifth_preservesLevel_afterDelay() public {
        index.initialize(_basket(4));
        sources[0].set(2e18);
        (uint256 beforeLevel,) = index.latestIndex();
        MemeBasketIndex.ComponentInput[] memory next = _basket(5);
        index.proposeBasket(next);
        vm.expectRevert(MemeBasketIndex.NotReady.selector); index.executeBasket(next);
        vm.warp(block.timestamp + 1 days);
        vm.prank(address(123)); index.executeBasket(next);
        (uint256 afterLevel,) = index.latestIndex(); assertEq(afterLevel, beforeLevel);
        assertEq(index.componentCount(), 5); assertEq(index.revision(), 2);
        sources[4].set(10e18);
        (afterLevel,) = index.latestIndex(); assertEq(afterLevel, beforeLevel * 120 / 100);
    }
    function test_badWeights_duplicateToken_wrongSource() public {
        MemeBasketIndex.ComponentInput[] memory b = _basket(4);
        b[0].weightBps = 2499;
        vm.expectRevert(MemeBasketIndex.BadBasket.selector); index.initialize(b);
        b = _basket(4); b[1] = b[0];
        vm.expectRevert(MemeBasketIndex.BadBasket.selector); index.initialize(b);
        b = _basket(4); b[0].source = sources[1];
        vm.expectRevert(MemeBasketIndex.BadBasket.selector); index.initialize(b);
    }
    function test_access_initializeOnce_proposalExact_cancel() public {
        vm.prank(address(123)); vm.expectRevert(); index.initialize(_basket(4));
        index.initialize(_basket(4));
        vm.expectRevert(MemeBasketIndex.BadBasket.selector); index.initialize(_basket(4));
        vm.prank(address(123)); vm.expectRevert(); index.proposeBasket(_basket(5));
        index.proposeBasket(_basket(5)); vm.warp(block.timestamp + 1 days);
        vm.expectRevert(MemeBasketIndex.NotReady.selector); index.executeBasket(_basket(4));
        index.cancelBasket(); vm.expectRevert(MemeBasketIndex.NotReady.selector); index.executeBasket(_basket(5));
    }
    function test_invalidComponentPrice_failsClosed() public {
        index.initialize(_basket(4)); sources[1].fail(true);
        vm.expectRevert("source unavailable"); index.latestIndex();
        sources[1].fail(false); sources[1].set(0);
        vm.expectRevert(MemeBasketIndex.NotReady.selector); index.latestIndex();
    }
    function test_permissionlessMaintenance_hasNoPriceSetter() public {
        index.initialize(_basket(4));
        vm.prank(address(123)); index.updatePrices();
        for (uint256 i; i < 4; ++i) assertEq(sources[i].updates(), 1);
    }
    function test_recovery_deadConstituent_preservesLastValidCheckpoint() public {
        index.initialize(_basket(4)); sources[0].set(2e18); index.updatePrices();
        assertEq(index.lastGoodPoints(), 1250e18);
        sources[0].fail(true); index.updatePrices();
        assertEq(index.lastGoodPoints(), 1250e18);
        MemeBasketIndex.ComponentInput[] memory next = _basket(4);
        next[0] = MemeBasketIndex.ComponentInput(tokens[4], sources[4], 2500);
        index.proposeBasket(next);
        vm.expectRevert(MemeBasketIndex.NotReady.selector); index.executeRecoveryBasket(next);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert("source unavailable"); index.executeBasket(next);
        vm.prank(address(123)); index.executeRecoveryBasket(next);
        (uint256 points,) = index.latestIndex(); assertEq(points, 1250e18);
        assertEq(index.revision(), 2); assertEq(index.pendingBasketHash(), bytes32(0));
    }
    function test_recovery_cannotBypassHealthyPricesOrRecentCheckpoint() public {
        index.initialize(_basket(4));
        MemeBasketIndex.ComponentInput[] memory next = _basket(5);
        index.proposeBasket(next); vm.warp(block.timestamp + 1 days);
        vm.expectRevert(MemeBasketIndex.NotReady.selector); index.executeRecoveryBasket(next);
        index.updatePrices(); sources[0].fail(true);
        vm.expectRevert(MemeBasketIndex.NotReady.selector); index.executeRecoveryBasket(next);
        index.cancelBasket(); vm.warp(block.timestamp + 1 days);
        vm.expectRevert(MemeBasketIndex.NotReady.selector); index.executeRecoveryBasket(next);
    }
}

contract V2IndexSourceTest is Test {
    IndexTestToken base;
    IndexTestToken quote;
    IndexTestSource quoteFeed;
    IndexTestPair pair;
    V2IndexSource source;
    function setUp() public {
        vm.warp(1_000_000);
        base = new IndexTestToken(18); quote = new IndexTestToken(18);
        quoteFeed = new IndexTestSource(address(quote));
        pair = new IndexTestPair(address(base), address(quote));
        source = new V2IndexSource(address(base), address(pair), address(pair), quoteFeed, 1800, 7200, 10e18);
    }
    function test_warmup_realElapsedPrice_andCheckpointContinuity() public {
        vm.expectRevert(V2IndexSource.ObservationUnavailable.selector); source.priceUsd();
        vm.warp(block.timestamp + 1799); vm.expectRevert(V2IndexSource.ObservationUnavailable.selector); source.priceUsd();
        vm.warp(block.timestamp + 1); (uint256 p,) = source.priceUsd(); assertEq(p, 2e18);
        source.update(); (p,) = source.priceUsd(); assertEq(p, 2e18);
        vm.prank(address(123)); source.update(); (p,) = source.priceUsd(); assertEq(p, 2e18);
        vm.warp(block.timestamp + 1800); source.update(); (p,) = source.priceUsd(); assertEq(p, 2e18);
    }
    function test_spotManipulation_rejected() public {
        vm.warp(block.timestamp + 1800);
        pair.setReserves(100e18, 1000e18);
        vm.expectRevert(V2IndexSource.PriceDivergence.selector); source.priceUsd();
    }
    function test_stale_requiresRewarm_noFallback() public {
        vm.warp(block.timestamp + 7201);
        vm.expectRevert(V2IndexSource.ObservationUnavailable.selector); source.priceUsd();
        source.update(); vm.expectRevert(V2IndexSource.ObservationUnavailable.selector); source.priceUsd();
        vm.warp(block.timestamp + 1800); (uint256 p,) = source.priceUsd(); assertEq(p, 2e18);
    }
    function test_lowLiquidity_andQuoteFailure() public {
        vm.warp(block.timestamp + 1800); pair.setReserves(1e18, 2e18);
        vm.expectRevert(V2IndexSource.InsufficientLiquidity.selector); source.priceUsd();
        pair.setReserves(100e18, 200e18); quoteFeed.fail(true);
        vm.expectRevert("source unavailable"); source.priceUsd();
    }
    function test_reverseDirection() public {
        IndexTestSource reverseQuote = new IndexTestSource(address(base));
        V2IndexSource reverse = new V2IndexSource(address(quote), address(pair), address(pair), reverseQuote, 1800, 7200, 10e18);
        vm.warp(block.timestamp + 1800); (uint256 p,) = reverse.priceUsd(); assertEq(p, 5e17);
    }
    function test_cumulativeRollover() public {
        pair.cumulative(type(uint256).max - 100, type(uint256).max - 100);
        V2IndexSource overflow = new V2IndexSource(address(base), address(pair), address(pair), quoteFeed, 1800, 7200, 10e18);
        vm.warp(block.timestamp + 1800); (uint256 p,) = overflow.priceUsd(); assertEq(p, 2e18);
    }
    function test_poolTimestampRollover() public {
        vm.warp(2 ** 32 - 900);
        pair = new IndexTestPair(address(base), address(quote));
        V2IndexSource rollover = new V2IndexSource(address(base), address(pair), address(pair), quoteFeed, 1800, 7200, 10e18);
        vm.warp(block.timestamp + 1800); (uint256 p,) = rollover.priceUsd(); assertEq(p, 2e18);
    }
}

contract BasketSourcesForkTest is Test {
    function test_fork_realPoolPaths() public {
        if (!vm.envOr("FORK_TESTS", false)) vm.skip(true);
        vm.createSelectFork("bsc", vm.envOr("INDEX_FORK_BLOCK", uint256(122_592_000)));
        ChainlinkIndexSource bnb = new ChainlinkIndexSource(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c, 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE, 2 hours);
        ChainlinkIndexSource usd = new ChainlinkIndexSource(0x55d398326f99059fF775485246999027B3197955, 0xB97Ad0E74fa7d920791E90258A6E2085088b4320, 1 days);
        address v3factory = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
        address v2factory = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
        V3IndexSource apple = new V3IndexSource(0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A, 0xe9b9998B2EC5430D2246c7f1F8D9f298c97D7365, v3factory, usd, 1800, 1e23);
        V3IndexSource bull = new V3IndexSource(0xBEEA1D618e533a387D941F58a7d4c9b7bD377777, 0xE5Ae318389B8D6d09370a675479c64862152D126, v3factory, usd, 1800, 1e23);
        V2IndexSource lobster = new V2IndexSource(0xeCCBb861c0dda7eFd964010085488B69317e4444, 0x22af7297243c4eEF12E2D5A4f888b92E56BF127C, v2factory, bnb, 1800, 7200, 10e18);
        V2IndexSource fruit = new V2IndexSource(0x225AD472938d116f957BF86fB6B611da144F7777, 0xd7632dd04E030F17532a2b9524280F0C55f2Ce9d, v2factory, apple, 1800, 7200, 10e18);
        V2IndexSource haki = new V2IndexSource(0x82Ec31D69b3c289E541b50E30681FD1ACAd24444, 0xc33bACFf9141Da689875e6381c1932348aB4c5CB, v2factory, bnb, 1800, 7200, 10e18);
        vm.warp(block.timestamp + 1800);
        IIndexPriceSource[4] memory feeds = [IIndexPriceSource(address(lobster)), IIndexPriceSource(address(bull)), IIndexPriceSource(address(fruit)), IIndexPriceSource(address(haki))];
        MemeBasketIndex basket = new MemeBasketIndex(address(this));
        MemeBasketIndex.ComponentInput[] memory components = new MemeBasketIndex.ComponentInput[](4);
        for (uint256 i; i < 4; ++i) {
            (uint256 price,) = feeds[i].priceUsd(); assertGt(price, 0); assertLt(price, 1000e18);
            emit log_named_uint("real path USD price E18", price);
            components[i] = MemeBasketIndex.ComponentInput(feeds[i].baseToken(), feeds[i], 2500);
        }
        basket.initialize(components); basket.updatePrices();
        (uint256 points,) = basket.latestIndex(); assertEq(points, 1000e18);
    }
}
