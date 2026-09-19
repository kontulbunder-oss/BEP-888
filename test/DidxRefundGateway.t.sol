// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {DidxRefundGateway, IDidxAssetGateway} from "../src/index/DidxRefundGateway.sol";
import {DidxBasket} from "../src/index/DidxBasket.sol";
import {DidxTestToken} from "./DidxBasket.t.sol";
import {IMemeDaqRouter} from "../src/interfaces/IMemeDaqRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RefundMemeRouter {
    DidxTestToken public token = new DidxTestToken(18);
    function buy(address meme,address quote,uint256 amount,uint256 minimum,address receiver,uint256) external returns(uint256 out) {
        require(meme==address(token));require(IERC20(quote).transferFrom(msg.sender,address(this),amount));
        out=amount*2;require(out>=minimum);token.mint(receiver,out);
    }
}
contract RefundPurchaseMock {
    DidxBasket public basket;IMemeDaqRouter public memeRouter;uint256 public constant legCount=4;
    constructor(DidxBasket b,RefundMemeRouter r){basket=b;memeRouter=IMemeDaqRouter(address(r));}
    function buyAssets(uint256[4] calldata budgets,uint256[] calldata limits,address receiver,uint256) external payable returns(uint256[4] memory amounts,uint256[] memory legs){
        address[4] memory assets=basket.assets();uint256 spent;legs=new uint256[](4);
        for(uint256 i;i<4;++i){spent+=budgets[i];amounts[i]=budgets[i]*(10000+20000*i);require(amounts[i]>=limits[i],"swap limit");DidxTestToken(assets[i]).mint(receiver,amounts[i]);legs[i]=amounts[i];}
        require(spent==msg.value);
    }
}
contract RejectRefund {
    function mint(DidxRefundGateway g,uint256[4] calldata budgets,uint256[] calldata limits,address receiver) external payable {
        g.mintFromBnb{value:msg.value}(budgets,limits,1,300,address(0),0,receiver,block.timestamp);
    }
}
contract DidxRefundGatewayTest is Test {
    DidxBasket basket;DidxRefundGateway gateway;RefundPurchaseMock source;RefundMemeRouter router;
    DidxTestToken[4] token;address user=address(0x1234);address receiver=address(0x4567);
    function setUp() public {
        address[4] memory assets;uint256[4] memory seed;
        for(uint256 i;i<4;++i){token[i]=new DidxTestToken(18);assets[i]=address(token[i]);seed[i]=(i+1)*100 ether;token[i].mint(address(this),seed[i]);}
        basket=new DidxBasket(assets,address(this));
        for(uint256 i;i<4;++i)token[i].approve(address(basket),seed[i]);
        basket.initialize(seed,address(this),block.timestamp);
        router=new RefundMemeRouter();source=new RefundPurchaseMock(basket,router);gateway=new DidxRefundGateway(IDidxAssetGateway(address(source)));
        vm.deal(user,100 ether);
    }
    function budgets() internal pure returns(uint256[4] memory b){for(uint256 i;i<4;++i)b[i]=0.001 ether;}
    function limits() internal pure returns(uint256[] memory a){a=new uint256[](4);for(uint256 i;i<4;++i)a[i]=1;}
    function test_refundsAllUnusedValueAndComponentSurplusToPayer() public {
        uint256[4] memory beforeR=basket.reserves();
        vm.prank(user);(uint256 shares,,uint256[] memory legs,uint256[4] memory refunds,uint256 nativeRefund)=gateway.mintFromBnb{value:0.005 ether}(budgets(),limits(),0.1 ether,300,address(0),0,receiver,block.timestamp);
        assertEq(shares,0.1 ether);assertEq(basket.balanceOf(receiver),shares);assertEq(nativeRefund,0.001 ether);assertEq(user.balance,99.996 ether);
        uint256[4] memory afterR=basket.reserves();
        for(uint256 i;i<4;++i){assertEq(refunds[i],i*10 ether);assertEq(token[i].balanceOf(user),refunds[i]);assertEq(token[i].balanceOf(receiver),0);assertEq(afterR[i]-beforeR[i],(i+1)*10 ether);assertEq(legs[i],(1+2*i)*10 ether);assertEq(token[i].balanceOf(address(gateway)),0);assertEq(token[i].allowance(address(gateway),address(basket)),0);}
    }
    function testFuzz_conservesAssetsWithoutUsingStrayBalances(uint96 raw) public {
        uint256 n=bound(uint256(raw),1e12,0.01 ether);uint256[4] memory b;for(uint256 i;i<4;++i){b[i]=n;token[i].mint(address(gateway),1e18+i);}
        vm.deal(address(gateway),1 ether);uint256[4] memory beforeR=basket.reserves();
        vm.prank(user);(uint256 shares,,,uint256[4] memory refunded,)=gateway.mintFromBnb{value:4*n+123}(b,limits(),1,0,address(0),0,user,block.timestamp);
        uint256[4] memory afterR=basket.reserves();assertEq(shares,basket.balanceOf(user));assertEq(address(gateway).balance,1 ether);
        for(uint256 i;i<4;++i){assertEq(token[i].balanceOf(address(gateway)),1e18+i);assertEq(afterR[i]-beforeR[i]+refunded[i],n*(10000+20000*i));assertEq(refunded[i],token[i].balanceOf(user));}
    }
    function test_rejectsBasketTransferTaxAtomicallyInsteadOfKeepingSurplus() public {
        token[2].setTax(100);uint256 supply=basket.totalSupply();
        vm.prank(user);vm.expectRevert(DidxBasket.Slippage.selector);gateway.mintFromBnb{value:0.005 ether}(budgets(),limits(),1,300,address(0),0,user,block.timestamp);
        assertEq(basket.totalSupply(),supply);assertEq(address(source).balance,0);assertEq(user.balance,100 ether);
    }
    function test_failedNativeRefundRollsBackMintAndPurchases() public {
        RejectRefund payer=new RejectRefund();uint256 supply=basket.totalSupply();
        vm.deal(address(this),1 ether);vm.expectRevert(DidxRefundGateway.RefundFailed.selector);payer.mint{value:0.005 ether}(gateway,budgets(),limits(),receiver);
        assertEq(basket.totalSupply(),supply);assertEq(address(source).balance,0);assertEq(basket.balanceOf(receiver),0);
    }
    function test_minimumOutputAndFailedSwapRollback() public {
        vm.prank(user);vm.expectRevert(DidxRefundGateway.Slippage.selector);gateway.mintFromBnb{value:0.004 ether}(budgets(),limits(),1 ether,300,address(0),0,user,block.timestamp);
        uint256[] memory tooHigh=limits();tooHigh[0]=100 ether;
        vm.prank(user);vm.expectRevert("swap limit");gateway.mintFromBnb{value:0.004 ether}(budgets(),tooHigh,1,300,address(0),0,user,block.timestamp);assertEq(address(source).balance,0);
    }
    function test_optionalMemePurchaseUsesOnlyNewSharesAndStillRefunds() public {
        basket.transfer(address(gateway),123);
        address meme=address(router.token());
        vm.prank(user);(uint256 shares,uint256 out,,,)=gateway.mintFromBnb{value:0.005 ether}(budgets(),limits(),1,300,meme,1,receiver,block.timestamp);
        assertEq(out,shares*2);assertEq(router.token().balanceOf(receiver),out);assertEq(basket.balanceOf(address(gateway)),123);assertEq(basket.allowance(address(gateway),address(router)),0);assertEq(token[3].balanceOf(user),30 ether);
    }
    function test_assetQuoteAcquisitionPreservesBudgetAndRecipient() public {
        vm.prank(user);(uint256[4] memory amounts,)=gateway.buyAssets{value:0.005 ether}(budgets(),limits(),receiver,block.timestamp);
        for(uint256 i;i<4;++i)assertEq(token[i].balanceOf(receiver),amounts[i]);assertEq(user.balance,99.996 ether);
    }
    function test_rejectsInvalidBudgetRecipientAndDeadline() public {
        vm.prank(user);vm.expectRevert(DidxRefundGateway.InvalidInput.selector);gateway.mintFromBnb{value:0.003 ether}(budgets(),limits(),1,300,address(0),0,user,block.timestamp);
        vm.prank(user);vm.expectRevert(DidxRefundGateway.InvalidInput.selector);gateway.mintFromBnb{value:0.004 ether}(budgets(),limits(),1,300,address(0),0,address(gateway),block.timestamp);
        vm.warp(100);vm.prank(user);vm.expectRevert(DidxRefundGateway.InvalidInput.selector);gateway.mintFromBnb{value:0.004 ether}(budgets(),limits(),1,300,address(0),0,user,99);
    }
}
