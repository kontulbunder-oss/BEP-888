// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {LRBBase} from "./utils/launchpad-router-buyback/LRBBase.sol";
import {DidxBasket} from "../src/index/DidxBasket.sol";
import {DidxTestToken} from "./DidxBasket.t.sol";
import {MockFeed} from "./mocks/Mocks.sol";
import {IMemeDaqLaunchpad} from "../src/interfaces/IMemeDaqLaunchpad.sol";
import {MemeToken} from "../src/MemeToken.sol";

contract DidxLaunchTest is LRBBase {
    DidxBasket basket;
    function setUp() public virtual override {
        super.setUp();address[4] memory assets;uint256[4] memory amounts;
        for(uint256 i;i<4;++i){DidxTestToken t=new DidxTestToken(18);assets[i]=address(t);amounts[i]=100e18;t.mint(address(this),200e18);}
        basket=new DidxBasket(assets,address(this));
        for(uint256 i;i<4;++i)DidxTestToken(assets[i]).approve(address(basket),amounts[i]);
        basket.initialize(amounts,address(this),block.timestamp);
        lp.setBasketQuote(address(basket));
        lp.setQuote(address(basket),IMemeDaqLaunchpad.QuoteConfig(true,true,18,IMemeDaqLaunchpad.PriceSource.CHAINLINK,10000,3600,address(new MockFeed(18,400e18)),0,0));
    }
    function test_basketOnlyLaunchBuySellAndRedeem() public {
        IMemeDaqLaunchpad.LaunchParams memory p=_params(_q(address(basket),10000),0,keccak256("didx"));
        address meme=lp.launchBasket(p);
        IMemeDaqLaunchpad.MemeView memory m=lp.getMeme(meme);
        assertEq(m.quotes.length,1);assertEq(m.quotes[0],address(basket));
        vm.roll(block.number+101);
        basket.approve(address(router),1e16);
        uint256 bought=router.buy(meme,address(basket),1e16,1,address(this),block.timestamp);
        assertGt(bought,0);
        MemeToken(meme).approve(address(router),bought/2);
        uint256 sold=router.sell(meme,address(basket),bought/2,1,address(this),block.timestamp);
        assertGt(sold,0);
        uint256[4] memory zero;
        uint256[4] memory received=basket.redeem(sold,zero,alice,block.timestamp);
        for(uint256 i;i<4;++i)assertGt(received[i],0);
    }
    function test_cannotLaunchBasketWithBnbOrMixPools() public {
        IMemeDaqLaunchpad.LaunchParams memory p=_params(_q(BNB,10000),0,keccak256("bad"));
        vm.expectRevert(IMemeDaqLaunchpad.BadConfig.selector);lp.launchBasket(p);
        p.quotes=_q(address(basket),10000);p.devBuyBnb=1;
        vm.expectRevert(IMemeDaqLaunchpad.BadConfig.selector);lp.launchBasket{value:1}(p);
        p.devBuyBnb=0;p.quotes=_q(address(basket),5000,BNB,5000);
        vm.expectRevert(IMemeDaqLaunchpad.BadQuotes.selector);lp.launch(p);
        vm.expectRevert(IMemeDaqLaunchpad.BadConfig.selector);lp.setBasketQuote(address(basket));
    }
}
