// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title IMemeToken
/// @notice MemeDAQ meme: plain fixed-supply ERC20 with multi-currency dividends and creator fees.
interface IMemeToken is IERC20Metadata {
    /// @notice Clone initialization parameters.
    struct InitParams {
        string name;
        string symbol;
        string meta;
        address creator;
        address launchpad;
        address hook;
        address infinityVault;
        address clPoolManager; // Vault app whose meme reserves are pool inventory (required)
        address binPoolManager; // second Vault app counted the same way (0 = none)
        address[] rewardCurrencies; // = the meme's quote currencies, in pool order (address(0) = BNB)
        bytes32[] rewardPoolIds; // PoolId of the pool for each reward index
    }

    event DividendsDistributed(uint8 indexed i, uint256 amount);
    event DividendClaimed(address indexed account, uint8 indexed i, uint256 amount);
    event CreatorFeesClaimed(uint8 indexed i, uint256 amount);
    event CreatorChanged(address indexed from, address indexed to);
    event ExcludedFromDividends(address indexed account);

    error AlreadyInitialized();
    error NotLaunchpad();
    error NotHook();
    error NotCreator();
    error BadParams();
    error ZeroAddress();
    error AlreadyExcluded();
    error NotContract();
    error InsufficientBalance();
    error InsufficientAllowance();
    /// @notice A transfer out of the Infinity Vault would take meme inventory the pools still account for
    ///         (a flash loan inside a Vault lock).
    error VaultBorrowForbidden();

    /// @notice One-time initializer, called by the launchpad in the launch tx.
    function initialize(InitParams calldata p) external;

    /// @notice Books a taxed swap. Only the hook. Never reverts for valid input.
    /// @dev A buy's holder share is spread over the eligible supply at once (the bought tokens are still in the
    ///      Vault). A sell's holder share is held as pending and spread at the next token interaction where the
    ///      Vault holds every meme the pools account for, i.e. once the seller has paid.
    /// @param i Reward index (pool) that was taxed.
    /// @param holderAmt Holder dividend share, in reward currency `i`.
    /// @param creatorAmt Creator fee share, in reward currency `i`.
    /// @param isBuy True when the quote currency is the swap input.
    /// @return distributed False when `holderAmt > 0` but eligible supply < MIN_ELIGIBLE (hook sends it to buyback).
    function onTax(uint8 i, uint256 holderAmt, uint256 creatorAmt, bool isBuy) external returns (bool distributed);

    /// @notice Spreads pending sell shares over the current eligible supply, if the Vault is settled. Permissionless.
    /// @return done True when nothing is pending afterwards.
    function distribute() external returns (bool done);

    /// @notice Claims every non-zero dividend of `msg.sender`.
    function claimDividends() external;

    /// @notice Claims every non-zero dividend of `account` and pays it to `account`. Permissionless.
    function claimDividendsFor(address account) external;

    /// @notice Pays accrued creator fees to the creator. Only creator.
    function claimCreatorFees() external;

    /// @notice Transfers the creator role. Only creator.
    function setCreator(address newCreator) external;

    /// @notice Excludes a contract from dividends (one-way). Only launchpad.
    function excludeFromDividends(address account) external;

    /// @notice Unclaimed dividend of `account` in reward `i`, including its share of pending sell shares as if
    ///         they were spread now.
    function dividendOf(address account, uint8 i) external view returns (uint256);

    /// @notice Unclaimed dividends of `account` in every reward currency.
    function dividendsOf(address account) external view returns (address[] memory currencies, uint256[] memory amounts);

    /// @notice Holder share of reward `i` booked by sells and not yet spread.
    function pendingDividends(uint8 i) external view returns (uint256);

    function meta() external view returns (string memory);
    function creator() external view returns (address);
    function launchpad() external view returns (address);
    function hook() external view returns (address);
    function infinityVault() external view returns (address);
    function clPoolManager() external view returns (address);
    function binPoolManager() external view returns (address);
    function rewardCount() external view returns (uint8);
    function rewardCurrency(uint8 i) external view returns (address);
    function rewardPoolId(uint8 i) external view returns (bytes32);
    function eligibleSupply() external view returns (uint256);
    function excludedSupply() external view returns (uint256);
    function isExcluded(address account) external view returns (bool);
    /// @notice Holder share ever booked for reward `i` (spread + pending).
    function totalDistributed(uint8 i) external view returns (uint256);
    function creatorFees(uint8 i) external view returns (uint256 owed, uint256 paid);
}
