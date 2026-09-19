// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {DidxLaunchTest} from "./DidxLaunch.t.sol";
import {DidxBasket, DidxTestToken} from "./DidxBasket.t.sol";
import {DidxBasketRegistry} from "../src/index/DidxBasketRegistry.sol";
import {IMemeDaqLaunchpad} from "../src/interfaces/IMemeDaqLaunchpad.sol";
import {MockFeed} from "./mocks/Mocks.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {IMdaqBuyback} from "../src/interfaces/IMdaqBuyback.sol";

// Exercises each real reserve basket; only its external DEX conversion is mocked.
contract FiveChoiceRedeemer {
    DidxBasket public immutable basket;
    constructor(DidxBasket basket_) { basket=basket_; }
    function redeemToBnb(uint256 shares,uint256[] calldata,uint256 minOut,address recipient,uint256 deadline)
        external returns(uint256 amount,uint256[] memory legs)
    {
        basket.transferFrom(msg.sender,address(this),shares);
        uint256[4] memory minimum;
        basket.redeem(shares,minimum,address(this),deadline);
        amount=shares;require(amount>=minOut);
        (bool ok,)=recipient.call{value:amount}("");require(ok);
        legs=new uint256[](0);
    }
}

contract DidxFiveChooseFourTest is DidxLaunchTest {
    DidxBasketRegistry registry;
    DidxTestToken platform;
    DidxBasket[5] choices;
    function setUp() public override {
        super.setUp();
        registry=new DidxBasketRegistry(address(lp),basket);
        lp.setBasketRegistry(registry);
        platform=new DidxTestToken(18);platform.setTax(200);
        registry.setPlatformToken(address(platform));
        choices[4]=basket;
        address[4] memory original=basket.assets();
        for(uint256 omit;omit<4;++omit){
            address[4] memory assets;uint256 at;
            for(uint256 i;i<4;++i)if(i!=omit)assets[at++]=original[i];
            assets[3]=address(platform);
            DidxBasket b=new DidxBasket(assets,address(this));
            uint256[4] memory amounts;
            for(uint256 i;i<4;++i){amounts[i]=10e18;DidxTestToken(assets[i]).mint(address(this),10e18);DidxTestToken(assets[i]).approve(address(b),10e18);}
            b.initialize(amounts,address(this),block.timestamp);
            registry.registerBasket(b);choices[omit]=b;
            lp.setQuote(address(b),IMemeDaqLaunchpad.QuoteConfig(true,true,18,IMemeDaqLaunchpad.PriceSource.CHAINLINK,10000,3600,address(new MockFeed(18,40e18)),0,0));
        }
    }
    function test_allFiveCombinationsLaunchSeparateReservePools() public {
        for(uint256 i;i<5;++i){
            address q=address(choices[i]);uint8 mask=uint8(31 ^ (1 << i));
            assertEq(registry.composition(q),mask);assertEq(registry.basketForMask(mask),q);
            address m=lp.launchBasket(_params(_q(q,10000),0,bytes32(i+1)));
            IMemeDaqLaunchpad.MemeView memory info=lp.getMeme(m);
            assertEq(info.quotes.length,1);assertEq(info.quotes[0],q);
            vm.roll(block.number+101);
            choices[i].approve(address(router),1e16);
            uint256 bought=router.buy(m,q,1e16,1,address(this),block.timestamp);
            MemeToken(m).approve(address(router),bought/2);
            assertGt(router.sell(m,q,bought/2,1,alice,block.timestamp),0);
        }
        assertEq(lp.memeCount(),5);
    }
    function test_redemptionNeverUsesAnotherCombinationsReserves() public {
        uint256[4] memory original=basket.reserves();
        DidxBasket selected=choices[0];uint256[4] memory minimum;
        selected.redeem(1e17,minimum,alice,block.timestamp);
        address[4] memory assets=selected.assets();
        assertGt(platform.balanceOf(alice),0);
        assertEq(DidxTestToken(basket.assets()[0]).balanceOf(alice),0);
        for(uint256 i;i<4;++i){assertEq(basket.reserves()[i],original[i]);assertGt(DidxTestToken(assets[i]).balanceOf(alice),0);}
    }
    function test_noReplacementDuplicateOrForeignCandidate() public {
        vm.expectRevert(DidxBasketRegistry.BadBasket.selector);registry.setPlatformToken(address(platform));
        vm.expectRevert(DidxBasketRegistry.BadBasket.selector);registry.registerBasket(choices[0]);
        vm.prank(alice);vm.expectRevert(DidxBasketRegistry.NotOwner.selector);registry.registerBasket(choices[0]);
        address[4] memory assets=basket.assets();assets[0]=address(new DidxTestToken(18));
        DidxBasket foreign=new DidxBasket(assets,address(this));uint256[4] memory amounts;
        for(uint256 i;i<4;++i){amounts[i]=1e18;DidxTestToken(assets[i]).mint(address(this),1e18);DidxTestToken(assets[i]).approve(address(foreign),1e18);}
        foreign.initialize(amounts,address(this),block.timestamp);
        vm.expectRevert(DidxBasketRegistry.BadBasket.selector);registry.registerBasket(foreign);
        vm.expectRevert(IMemeDaqLaunchpad.BadConfig.selector);lp.setBasketRegistry(registry);
    }
    function test_cannotMixTwoReserveSharesInOneLaunch() public {
        vm.expectRevert(IMemeDaqLaunchpad.BadQuotes.selector);
        lp.launch(_params(_q(address(choices[0]),5000,address(choices[1]),5000),0,keccak256("mixed")));
    }
    function test_buybackRedeemsAllFiveWithoutCrossApprovals() public {
        uint256[] memory limits=new uint256[](0);
        for(uint256 i;i<5;++i){
            FiveChoiceRedeemer gateway=new FiveChoiceRedeemer(choices[i]);
            vm.deal(address(gateway),1 ether);
            bb.setBasketGateway(address(gateway));
            if(i==0)assertEq(bb.basketGateway(),address(gateway));
            assertEq(bb.basketGateways(address(choices[i])),address(gateway));
            choices[i].transfer(address(bb),1e16);
            assertEq(bb.swapToBnb(address(choices[i]),1e16,1e16,3,abi.encode(limits)),1e16);
            assertEq(choices[i].balanceOf(address(bb)),0);
            assertEq(choices[i].allowance(address(bb),address(gateway)),0);
            for(uint256 j;j<5;++j)if(i!=j)assertEq(choices[j].allowance(address(bb),address(gateway)),0);
            vm.expectRevert(IMdaqBuyback.BadRoute.selector);bb.setBasketGateway(address(gateway));
        }
        assertEq(address(bb).balance,5e16);
    }
    function test_unregisteredBuybackRouteRollsBack() public {
        choices[0].transfer(address(bb),1e16);
        uint256[] memory limits=new uint256[](0);
        vm.expectRevert(IMdaqBuyback.BadRoute.selector);
        bb.swapToBnb(address(choices[0]),1e16,1,3,abi.encode(limits));
        assertEq(choices[0].balanceOf(address(bb)),1e16);
        FiveChoiceRedeemer gateway=new FiveChoiceRedeemer(choices[0]);
        vm.prank(alice);vm.expectRevert();bb.setBasketGateway(address(gateway));
    }
}
