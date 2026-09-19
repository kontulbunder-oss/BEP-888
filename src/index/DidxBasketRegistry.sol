// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {DidxBasket} from "./DidxBasket.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IDidxLaunchOwner {
    function owner() external view returns (address);
    function basketQuote() external view returns (address);
}

/// @notice Five candidates, four assets per immutable reserve basket. Registration never changes reserves.
/// The original four candidates and basket are permanent; the platform token can be bound exactly once.
contract DidxBasketRegistry {
    address public immutable launchpad;
    address public immutable defaultBasket;
    bytes32 public immutable basketCodeHash;
    address[5] private _candidates;
    mapping(address => uint8) public composition;
    mapping(uint8 => address) public basketForMask;
    error NotOwner();
    error BadBasket();
    event PlatformTokenSet(address indexed token);
    event BasketRegistered(address indexed basket, uint8 mask);

    constructor(address launchpad_, DidxBasket initial) {
        launchpad = launchpad_;
        defaultBasket = address(initial);
        basketCodeHash = address(initial).codehash;
        if (IDidxLaunchOwner(launchpad_).basketQuote() != address(initial)) revert BadBasket();
        address[4] memory assets = initial.assets();
        for (uint256 i; i < 4; ++i) _candidates[i] = assets[i];
        _register(initial);
    }
    modifier onlyOwner() {
        if (msg.sender != IDidxLaunchOwner(launchpad).owner()) revert NotOwner();
        _;
    }
    function candidates() external view returns (address[5] memory) { return _candidates; }
    function validateBinding(address initial) external view {
        if (msg.sender != launchpad || initial != defaultBasket) revert BadBasket();
    }
    function isBasket(address basket) external view returns (bool) { return composition[basket] != 0; }
    function setPlatformToken(address token) external onlyOwner {
        if (_candidates[4] != address(0) || token.code.length == 0 || IERC20Metadata(token).decimals() != 18) revert BadBasket();
        for (uint256 i; i < 4; ++i) if (_candidates[i] == token) revert BadBasket();
        _candidates[4] = token;
        emit PlatformTokenSet(token);
    }
    function registerBasket(DidxBasket basket) external onlyOwner { _register(basket); }
    function _register(DidxBasket basket) private {
        // The same immutable code also pins initializer, share accounting and absence of admin withdrawals.
        if (address(basket).codehash != basketCodeHash || basket.totalSupply() == 0) revert BadBasket();
        address[4] memory assets = basket.assets();
        uint256[4] memory reserves = basket.reserves();
        uint8 mask;
        for (uint256 i; i < 4; ++i) {
            uint8 bit;
            for (uint256 j; j < 5; ++j) if (assets[i] == _candidates[j]) bit = uint8(1 << j);
            if (bit == 0 || mask & bit != 0 || reserves[i] == 0) revert BadBasket();
            mask |= bit;
        }
        if (basketForMask[mask] != address(0)) revert BadBasket();
        composition[address(basket)] = mask;
        basketForMask[mask] = address(basket);
        emit BasketRegistered(address(basket), mask);
    }
}
