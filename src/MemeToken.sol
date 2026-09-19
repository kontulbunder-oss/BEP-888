// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IMemeToken} from "./interfaces/IMemeToken.sol";
import {IMemeDaqHook} from "./interfaces/IMemeDaqHook.sol";

/// @title MemeToken
/// @notice EIP-1167 clone implementation of a MemeDAQ meme: plain 18-decimal ERC20 with a fixed 1B supply,
///         no transfer tax and no callbacks, plus magnified-dividend accounting for up to 4 reward currencies
///         (one per quote pool) and creator fees. Rewards are held by the hook as Vault claims and paid via
///         `hook.payout`.
/// @dev Excluded accounts (launchpad, hook, Infinity Vault, 0x…dEaD, and contracts excluded later) do not earn;
///      `excludedSupply` tracks their balances so dividends are spread over `eligibleSupply()` only.
///      Dividends are spread over live balances, so two rules keep a swap from inflating the balances that share
///      its tax:
///      - The Vault holds every pool's unsold inventory. A transfer out of the Vault may never leave it holding less
///        than the pools account for (`reservesOfApp`), so that inventory cannot be flash-borrowed inside a lock.
///      - A sell's holder share is spread only once the Vault again holds every meme the pools account for, i.e.
///        after the seller has paid, whatever order its router settles in. A buy's share is spread at once.
contract MemeToken is IMemeToken, ReentrancyGuardTransient {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant MIN_ELIGIBLE = 1e18;
    uint256 public constant MAX_REWARDS = 4;
    uint256 internal constant MAG = 2 ** 96;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct CreatorFee {
        uint128 owed;
        uint128 paid;
    }

    /// @dev `total`: holder share ever booked (spread + pending). `pending`: booked by sells, not yet spread.
    struct HolderShare {
        uint128 total;
        uint128 pending;
    }

    /// @inheritdoc IMemeToken
    address public override creator;
    /// @inheritdoc IMemeToken
    uint8 public override rewardCount;
    bool private _initialized;
    /// @dev Bit i set <=> reward i has a pending holder share (packed with fields `_move` reads anyway).
    uint8 private _pendingMask;
    /// @inheritdoc IMemeToken
    address public override launchpad;
    /// @inheritdoc IMemeToken
    address public override hook;
    /// @inheritdoc IMemeToken
    uint256 public override excludedSupply;

    string private _name;
    string private _symbol;
    string private _meta;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    /// @inheritdoc IMemeToken
    mapping(address => bool) public override isExcluded;

    address[MAX_REWARDS] private _rewardCurrencies;
    bytes32[MAX_REWARDS] private _rewardPoolIds;
    /// @notice Magnified (2^96) dividend per eligible token, per reward index (spread shares only).
    uint256[MAX_REWARDS] public magPerShare;
    HolderShare[MAX_REWARDS] private _holderShares;
    CreatorFee[MAX_REWARDS] private _creatorFees;

    mapping(address => int256[MAX_REWARDS]) private _corr;
    mapping(address => uint256[MAX_REWARDS]) private _withdrawn;
    mapping(address => uint256[MAX_REWARDS]) private _frozen;

    /// @inheritdoc IMemeToken
    address public override infinityVault;
    /// @inheritdoc IMemeToken
    address public override clPoolManager;
    /// @inheritdoc IMemeToken
    address public override binPoolManager;

    /// @dev Locks the implementation.
    constructor() {
        _initialized = true;
    }

    // ------------------------------------------------------------------
    // Initialization
    // ------------------------------------------------------------------

    /// @inheritdoc IMemeToken
    function initialize(InitParams calldata p) external override {
        if (_initialized) revert AlreadyInitialized();
        if (msg.sender != p.launchpad) revert NotLaunchpad();
        uint256 n = p.rewardCurrencies.length;
        if (n == 0 || n > MAX_REWARDS || p.rewardPoolIds.length != n) revert BadParams();
        if (
            p.creator == address(0) || p.hook == address(0) || p.infinityVault == address(0)
                || p.clPoolManager == address(0)
        ) revert ZeroAddress();
        _initialized = true;
        _name = p.name;
        _symbol = p.symbol;
        _meta = p.meta;
        creator = p.creator;
        launchpad = p.launchpad;
        hook = p.hook;
        infinityVault = p.infinityVault;
        clPoolManager = p.clPoolManager;
        binPoolManager = p.binPoolManager;
        rewardCount = uint8(n);
        for (uint256 i; i < n; ++i) {
            _rewardCurrencies[i] = p.rewardCurrencies[i];
            _rewardPoolIds[i] = p.rewardPoolIds[i];
        }
        _exclude(p.launchpad);
        _exclude(p.hook);
        _exclude(p.infinityVault);
        _exclude(DEAD);
        excludedSupply = TOTAL_SUPPLY;
        balanceOf[p.launchpad] = TOTAL_SUPPLY;
        emit Transfer(address(0), p.launchpad, TOTAL_SUPPLY);
    }

    // ------------------------------------------------------------------
    // ERC20
    // ------------------------------------------------------------------

    /// @notice Token name.
    function name() external view override returns (string memory) {
        return _name;
    }

    /// @notice Token symbol.
    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    /// @notice Always 18.
    function decimals() external pure override returns (uint8) {
        return 18;
    }

    /// @notice Fixed total supply (1B * 1e18).
    function totalSupply() external pure override returns (uint256) {
        return TOTAL_SUPPLY;
    }

    /// @notice Standard ERC20 approve.
    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Standard ERC20 transfer.
    function transfer(address to, uint256 amount) external override returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    /// @notice Standard ERC20 transferFrom (an allowance of type(uint256).max is not decreased).
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        _move(from, to, amount);
        return true;
    }

    // ------------------------------------------------------------------
    // Tax booking (hook only)
    // ------------------------------------------------------------------

    /// @inheritdoc IMemeToken
    function onTax(uint8 i, uint256 holderAmt, uint256 creatorAmt, bool isBuy)
        external
        override
        returns (bool distributed)
    {
        if (msg.sender != hook) revert NotHook();
        if (creatorAmt != 0) _creatorFees[i].owed += uint128(creatorAmt);
        if (holderAmt == 0) return true;
        uint256 eligible = TOTAL_SUPPLY - excludedSupply;
        if (eligible < MIN_ELIGIBLE) return false;
        // earlier sell shares first, while every balance still reflects the state before this swap
        if (_pendingMask != 0 && balanceOf[infinityVault] >= _poolReserves()) _flush(eligible);
        HolderShare storage s = _holderShares[i];
        uint128 amt = SafeCast.toUint128(holderAmt);
        s.total += amt;
        if (isBuy) {
            magPerShare[i] += holderAmt * MAG / eligible;
        } else {
            s.pending += amt;
            _pendingMask |= uint8(1 << i);
        }
        emit DividendsDistributed(i, holderAmt);
        return true;
    }

    /// @inheritdoc IMemeToken
    function distribute() external override returns (bool done) {
        _tryFlush();
        return _pendingMask == 0;
    }

    // ------------------------------------------------------------------
    // Claims
    // ------------------------------------------------------------------

    /// @inheritdoc IMemeToken
    function claimDividends() external override nonReentrant {
        _claim(msg.sender);
    }

    /// @inheritdoc IMemeToken
    function claimDividendsFor(address account) external override nonReentrant {
        _claim(account);
    }

    /// @inheritdoc IMemeToken
    function claimCreatorFees() external override nonReentrant {
        address c = creator;
        if (msg.sender != c) revert NotCreator();
        uint256 n = rewardCount;
        for (uint256 i; i < n; ++i) {
            CreatorFee storage f = _creatorFees[i];
            uint256 owed = f.owed;
            uint256 amt = owed - f.paid;
            if (amt == 0) continue;
            f.paid = uint128(owed);
            emit CreatorFeesClaimed(uint8(i), amt);
            IMemeDaqHook(hook).payout(PoolId.wrap(_rewardPoolIds[i]), c, amt);
        }
    }

    /// @inheritdoc IMemeToken
    function setCreator(address newCreator) external override {
        if (msg.sender != creator) revert NotCreator();
        if (newCreator == address(0)) revert ZeroAddress();
        creator = newCreator;
        emit CreatorChanged(msg.sender, newCreator);
    }

    /// @inheritdoc IMemeToken
    function excludeFromDividends(address account) external override {
        if (msg.sender != launchpad) revert NotLaunchpad();
        if (account.code.length == 0) revert NotContract();
        if (isExcluded[account]) revert AlreadyExcluded();
        _tryFlush();
        uint256 n = rewardCount;
        for (uint256 i; i < n; ++i) {
            _frozen[account][i] = _accumulated(account, i, magPerShare[i]);
        }
        _exclude(account);
        excludedSupply += balanceOf[account];
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @inheritdoc IMemeToken
    function meta() external view override returns (string memory) {
        return _meta;
    }

    /// @inheritdoc IMemeToken
    function dividendOf(address account, uint8 i) public view override returns (uint256) {
        if (i >= rewardCount) return 0;
        return _accumulated(account, i, _currentMag(i)) - _withdrawn[account][i];
    }

    /// @inheritdoc IMemeToken
    function dividendsOf(address account)
        external
        view
        override
        returns (address[] memory currencies, uint256[] memory amounts)
    {
        uint256 n = rewardCount;
        currencies = new address[](n);
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            currencies[i] = _rewardCurrencies[i];
            amounts[i] = dividendOf(account, uint8(i));
        }
    }

    /// @inheritdoc IMemeToken
    function pendingDividends(uint8 i) external view override returns (uint256) {
        return i < MAX_REWARDS ? _holderShares[i].pending : 0;
    }

    /// @inheritdoc IMemeToken
    function rewardCurrency(uint8 i) external view override returns (address) {
        return _rewardCurrencies[i];
    }

    /// @inheritdoc IMemeToken
    function rewardPoolId(uint8 i) external view override returns (bytes32) {
        return _rewardPoolIds[i];
    }

    /// @inheritdoc IMemeToken
    function eligibleSupply() external view override returns (uint256) {
        return TOTAL_SUPPLY - excludedSupply;
    }

    /// @inheritdoc IMemeToken
    function totalDistributed(uint8 i) external view override returns (uint256) {
        return _holderShares[i].total;
    }

    /// @inheritdoc IMemeToken
    function creatorFees(uint8 i) external view override returns (uint256 owed, uint256 paid) {
        CreatorFee storage f = _creatorFees[i];
        return (f.owed, f.paid);
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _exclude(address account) internal {
        isExcluded[account] = true;
        emit ExcludedFromDividends(account);
    }

    function _accumulated(address account, uint256 i, uint256 mag) internal view returns (uint256) {
        if (isExcluded[account]) return _frozen[account][i];
        return SafeCast.toUint256(SafeCast.toInt256(mag * balanceOf[account]) + _corr[account][i]) / MAG;
    }

    /// @dev magPerShare[i] as if the pending share were spread now (what the next `_flush` will write).
    function _currentMag(uint256 i) internal view returns (uint256 mag) {
        mag = magPerShare[i];
        uint256 p = _holderShares[i].pending;
        if (p != 0) {
            uint256 eligible = TOTAL_SUPPLY - excludedSupply;
            if (eligible >= MIN_ELIGIBLE) mag += p * MAG / eligible;
        }
    }

    /// @dev Meme inventory the Vault holds for the pools: CL reserves plus, if configured, Bin reserves. Anything
    ///      the Vault holds above this belongs to lockers (credits, ERC6909 claims) or was donated.
    function _poolReserves() internal view returns (uint256 reserves) {
        IVault v = IVault(infinityVault);
        Currency self = Currency.wrap(address(this));
        reserves = v.reservesOfApp(clPoolManager, self);
        address bin = binPoolManager;
        if (bin != address(0)) reserves += v.reservesOfApp(bin, self);
    }

    /// @dev Spreads every pending share over `eligible`; waits while the eligible supply is below MIN_ELIGIBLE.
    function _flush(uint256 eligible) internal {
        if (eligible < MIN_ELIGIBLE) return;
        uint256 mask = _pendingMask;
        for (uint256 i; i < MAX_REWARDS; ++i) {
            if (mask & (1 << i) == 0) continue;
            HolderShare storage s = _holderShares[i];
            magPerShare[i] += uint256(s.pending) * MAG / eligible;
            s.pending = 0;
        }
        _pendingMask = 0;
    }

    /// @dev Flushes pending shares when the Vault holds every meme the pools account for (no seller still owes).
    function _tryFlush() internal {
        if (_pendingMask != 0 && balanceOf[infinityVault] >= _poolReserves()) _flush(TOTAL_SUPPLY - excludedSupply);
    }

    function _claim(address account) internal {
        _tryFlush();
        uint256 n = rewardCount;
        for (uint256 i; i < n; ++i) {
            uint256 acc = _accumulated(account, i, magPerShare[i]);
            uint256 amt = acc - _withdrawn[account][i];
            if (amt == 0) continue;
            _withdrawn[account][i] = acc;
            emit DividendClaimed(account, uint8(i), amt);
            IMemeDaqHook(hook).payout(PoolId.wrap(_rewardPoolIds[i]), account, amt);
        }
    }

    /// @dev O(rewardCount) <= 4 iterations. The only external calls are views on the Infinity Vault, made when a
    ///      sell share is pending or the Vault is the sender.
    function _move(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance();
        bool exFrom = isExcluded[from];
        bool exTo = isExcluded[to];
        bool pending = _pendingMask != 0;
        bool fromVault = exFrom && from == infinityVault;
        if (pending || fromVault) {
            uint256 vaultBalance = balanceOf[infinityVault];
            uint256 reserves = _poolReserves();
            // spread earlier sell shares before any balance moves, once no seller still owes the Vault
            if (pending && vaultBalance >= reserves) _flush(TOTAL_SUPPLY - excludedSupply);
            // a lock may only take what the pools have released (or what it deposited): no flash loans
            if (fromVault && fromBalance - amount < reserves) revert VaultBorrowForbidden();
        }
        unchecked {
            balanceOf[from] = fromBalance - amount;
            balanceOf[to] += amount; // bounded by TOTAL_SUPPLY
        }
        if (exFrom != exTo) {
            if (exFrom) excludedSupply -= amount;
            else excludedSupply += amount;
        }
        uint256 n = rewardCount;
        for (uint256 i; i < n; ++i) {
            uint256 m = magPerShare[i];
            if (m == 0) continue;
            int256 c = SafeCast.toInt256(m * amount);
            if (!exFrom) _corr[from][i] += c;
            if (!exTo) _corr[to][i] -= c;
        }
        emit Transfer(from, to, amount);
    }
}
