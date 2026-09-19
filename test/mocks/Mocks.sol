// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IChainlinkFeed} from "../../src/interfaces/IChainlinkFeed.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {StartPrice} from "../../src/libraries/StartPrice.sol";

/// @notice Minimal mintable ERC20 for unit tests (no solmate).
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @notice Settable Chainlink-style feed.
contract MockFeed is IChainlinkFeed {
    uint8 public override decimals;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function description() external pure override returns (string memory) {
        return "MOCK / USD";
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

    /// @notice Test swapper that can run any swap mode directly against the pool manager and settles for `msg.sender`.
    contract Swapper is ILockCallback {
        IVault public immutable vault;
        ICLPoolManager public immutable pm;

        struct Job {
            PoolKey key;
            bool zeroForOne;
            int256 amountSpecified;
            address user;
        }

        constructor(IVault vault_, ICLPoolManager pm_) {
            vault = vault_;
            pm = pm_;
        }

        /// @notice amountSpecified < 0 exact-in, > 0 exact-out. Native input: send enough msg.value; the rest is refunded.
        function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified)
            external
            payable
            returns (BalanceDelta d)
        {
            d = abi.decode(vault.lock(abi.encode(Job(key, zeroForOne, amountSpecified, msg.sender))), (BalanceDelta));
            if (address(this).balance != 0) {
                (bool ok,) = msg.sender.call{value: address(this).balance}("");
                require(ok, "refund");
            }
        }

        function lockAcquired(bytes calldata data) external returns (bytes memory) {
            require(msg.sender == address(vault), "vault");
            Job memory j = abi.decode(data, (Job));
            BalanceDelta d = pm.swap(
                j.key,
                ICLPoolManager.SwapParams({
                    zeroForOne: j.zeroForOne,
                    amountSpecified: j.amountSpecified,
                    sqrtPriceLimitX96: j.zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
                }),
                ""
            );
            _resolve(j.key.currency0, d.amount0(), j.user);
            _resolve(j.key.currency1, d.amount1(), j.user);
            return abi.encode(d);
        }

        function _resolve(Currency c, int128 a, address user) internal {
            if (a < 0) {
                uint256 amt = uint256(uint128(-a));
                if (c.isNative()) {
                    vault.settle{value: amt}();
                } else {
                    vault.sync(c);
                    MockERC20(Currency.unwrap(c)).transferFrom(user, address(vault), amt);
                    vault.settle();
                }
            } else if (a > 0) {
                vault.take(c, user, uint256(uint128(a)));
            }
        }

        receive() external payable {}
    }

    /// @notice Third party trying to add liquidity to a MemeDAQ pool.
    contract RogueAdder is ILockCallback {
        IVault public immutable vault;
        ICLPoolManager public immutable pm;
        PoolKey internal _key;
        int24 internal _lo;
        int24 internal _hi;

        constructor(IVault vault_, ICLPoolManager pm_) {
            vault = vault_;
            pm = pm_;
        }

        function add(PoolKey memory key, int24 lo, int24 hi) external {
            _key = key;
            _lo = lo;
            _hi = hi;
            vault.lock("");
        }

        function lockAcquired(bytes calldata) external returns (bytes memory) {
            pm.modifyLiquidity(
                _key,
                ICLPoolManager.ModifyLiquidityParams({tickLower: _lo, tickUpper: _hi, liquidityDelta: 1e18, salt: 0}),
                ""
            );
            return "";
        }
    }

    /// @notice Exposes the StartPrice library.
    contract StartPriceHarness {
        function startTick(uint256 fdv, uint256 quoteUsd, uint8 dec, bool memeIs0) external pure returns (int24) {
            return StartPrice.startTick(fdv, quoteUsd, dec, memeIs0);
        }
    }

    /// @notice Contract holder used for exclusion tests.
    contract Holder {
        receive() external payable {}
    }

    /// @notice Adds liquidity to any (hookless) pool from its own token balances.
    contract LiquidityHelper is ILockCallback {
        IVault public immutable vault;
        ICLPoolManager public immutable pm;

        constructor(IVault vault_, ICLPoolManager pm_) {
            vault = vault_;
            pm = pm_;
        }

        function add(PoolKey memory key, int24 lo, int24 hi, uint256 liquidity) external {
            vault.lock(abi.encode(key, lo, hi, liquidity));
        }

        function lockAcquired(bytes calldata data) external returns (bytes memory) {
            (PoolKey memory key, int24 lo, int24 hi, uint256 liquidity) =
                abi.decode(data, (PoolKey, int24, int24, uint256));
            (BalanceDelta d,) = pm.modifyLiquidity(
                key,
                ICLPoolManager.ModifyLiquidityParams({
                    tickLower: lo, tickUpper: hi, liquidityDelta: int256(liquidity), salt: 0
                }),
                ""
            );
            _pay(key.currency0, d.amount0());
            _pay(key.currency1, d.amount1());
            return "";
        }

        function _pay(Currency c, int128 a) internal {
            if (a >= 0) return;
            vault.sync(c);
            MockERC20(Currency.unwrap(c)).transfer(address(vault), uint256(uint128(-a)));
            vault.settle();
        }
    }

    /// @notice Launchpad stand-in that maps any meme to a fixed pool key (router refund-path test).
    contract MockKeyLaunchpad {
        PoolKey internal _k;
        bool internal _memeIs0;

        function set(PoolKey memory k, bool memeIs0) external {
            _k = k;
            _memeIs0 = memeIs0;
        }

        function poolKeyOf(address, address) external view returns (PoolKey memory, bool) {
            return (_k, _memeIs0);
        }
    }
