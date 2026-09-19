// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DidxBasket} from "../src/index/DidxBasket.sol";

contract DidxTestToken is ERC20 {
    uint256 public tax;
    bool public frozen;
    uint8 private immutable _dec;
    constructor(uint8 d) ERC20("Component","C") { _dec = d; }
    function decimals() public view override returns(uint8) {return _dec;}
    function mint(address to,uint256 amount) external { _mint(to,amount); }
    function burn(address from,uint256 amount) external { _burn(from,amount); }
    function setTax(uint256 bps) external {tax=bps;}
    function freeze(bool value) external {frozen=value;}
    function _update(address from,address to,uint256 amount) internal override {
        require(!frozen,"frozen");
        if(from!=address(0)&&to!=address(0)&&tax!=0){uint256 fee=amount*tax/10000;super._update(from,address(0),fee);amount-=fee;}
        super._update(from,to,amount);
    }
}

contract DidxBasketTest is Test {
    DidxBasket basket;
    DidxTestToken[4] token;
    uint256[4] seed;
    address user=address(0x1234);
    function setUp() public {
        address[4] memory assets;
        for(uint256 i;i<4;++i){token[i]=new DidxTestToken(i==0?6:18);assets[i]=address(token[i]);seed[i]=1000*10**token[i].decimals();}
        token[1].setTax(100);
        basket=new DidxBasket(assets,address(this));
        for(uint256 i;i<4;++i){token[i].mint(address(this),seed[i]*100);token[i].approve(address(basket),type(uint256).max);}
        basket.initialize(seed,address(this),block.timestamp);
    }
    function test_onlyInitializerCanSeedOnce() public {
        vm.expectRevert(DidxBasket.InvalidInput.selector);basket.initialize(seed,address(this),block.timestamp);
        address[4] memory assets=basket.assets();DidxBasket fresh=new DidxBasket(assets,address(this));
        vm.prank(user);vm.expectRevert(DidxBasket.InvalidInput.selector);fresh.initialize(seed,user,block.timestamp);
        assertEq(basket.totalSupply(),1e18);assertEq(basket.balanceOf(basket.LOCK()),1e6);
    }
    function test_taxedDepositsCannotMintUnbackedShares() public {
        uint256[4] memory beforeR=basket.reserves();
        uint256 shares=basket.deposit(seed,1e18,0,user,block.timestamp);
        assertEq(shares,1e18);
        uint256[4] memory afterR=basket.reserves();
        for(uint256 i;i<4;++i)assertEq(afterR[i],beforeR[i]*2);
        assertEq(afterR[1],1980e18);
    }
    function test_redeemChecksNetTransferTaxesAndRevertsAtomically() public {
        basket.deposit(seed,1e18,0,user,block.timestamp);
        uint256[4] memory nominal=basket.previewRedeem(1e18);
        vm.prank(user);vm.expectRevert(DidxBasket.Slippage.selector);basket.redeem(1e18,nominal,user,block.timestamp);
        assertEq(basket.balanceOf(user),1e18);assertEq(token[0].balanceOf(user),0);
        nominal[1]=nominal[1]*9900/10000;
        vm.prank(user);uint256[4] memory net=basket.redeem(1e18,nominal,user,block.timestamp);
        for(uint256 i;i<4;++i)assertEq(net[i],nominal[i]);
    }
    function test_donationsDoNotManipulateMintQuoteOrReserves() public {
        uint256[4] memory beforeQ=basket.previewMint(1e18);
        token[0].transfer(address(basket),seed[0]*20);
        uint256[4] memory afterQ=basket.previewMint(1e18);
        for(uint256 i;i<4;++i)assertEq(beforeQ[i],afterQ[i]);
        assertEq(basket.deposit(seed,1e18,0,user,block.timestamp),1e18);
    }
    function test_lossesSocializedAndZeroAssetDoesNotBlockOtherExits() public {
        token[2].burn(address(basket),seed[2]);
        uint256[4] memory r=basket.reserves();assertEq(r[2],0);
        vm.expectRevert(DidxBasket.InvalidInput.selector);basket.deposit(seed,1,1000,user,block.timestamp);
        uint256[4] memory zero;
        uint256[4] memory received=basket.redeem(1e17,zero,user,block.timestamp);
        assertEq(received[2],0);assertGt(received[0],0);assertEq(basket.reserves()[2],0);
    }
    function test_surplusDeadlineAndRecipientLimits() public {
        uint256[4] memory bad=seed;bad[0]*=2;
        vm.expectRevert(DidxBasket.Slippage.selector);basket.deposit(bad,1,1000,user,block.timestamp);
        vm.expectRevert(DidxBasket.InvalidInput.selector);basket.deposit(seed,1,1001,user,block.timestamp);
        vm.expectRevert(DidxBasket.InvalidInput.selector);basket.deposit(seed,1,0,address(basket),block.timestamp);
        vm.warp(block.timestamp+1);vm.expectRevert(DidxBasket.InvalidInput.selector);basket.deposit(seed,1,0,user,block.timestamp-1);
    }
    function test_frozenAssetRollsBackBurnAndAllTransfers() public {
        token[3].freeze(true);uint256[4] memory zero;
        uint256 shares=basket.balanceOf(address(this));
        vm.expectRevert("frozen");basket.redeem(1e17,zero,user,block.timestamp);
        assertEq(basket.balanceOf(address(this)),shares);assertEq(token[0].balanceOf(user),0);
    }
    function testFuzz_roundTripCannotTakeMoreThanPaid(uint64 factor) public {
        uint256 f=bound(uint256(factor),1,50);
        uint256[4] memory amounts;
        uint256[4] memory beforeR=basket.reserves();
        for(uint256 i;i<4;++i)amounts[i]=seed[i]*f;
        uint256 shares=basket.deposit(amounts,f*1e18,0,user,block.timestamp);
        uint256[4] memory zero;
        vm.prank(user);uint256[4] memory received=basket.redeem(shares,zero,user,block.timestamp);
        for(uint256 i;i<4;++i){assertLe(received[i],amounts[i]);assertGe(basket.reserves()[i],beforeR[i]);assertGe(token[i].balanceOf(address(basket)),basket.reserves()[i]);}
    }
}
