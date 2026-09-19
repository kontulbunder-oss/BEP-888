// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {DidxBasket} from "./DidxBasket.sol";
import {IIndexPriceSource} from "./IIndexPriceSource.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Chainlink-shaped USD/share NAV adapter. Only launch pricing/display use this oracle.
contract DidxNavFeed {
    DidxBasket public immutable basket;
    IIndexPriceSource[4] public sources;
    uint256[4] private scales;
    uint8 public constant decimals = 18;
    constructor(DidxBasket basket_, IIndexPriceSource[4] memory sources_) {
        basket = basket_;
        address[4] memory assets = basket_.assets();
        for (uint256 i; i < 4; ++i) {
            require(sources_[i].baseToken() == assets[i], "source asset");
            uint8 d = IERC20Metadata(assets[i]).decimals();
            require(d <= 18, "decimals");
            scales[i] = 10 ** d;
        }
        sources = sources_;
    }
    function updatePrices() external { for (uint256 i; i < 4; ++i) sources[i].update(); }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 supply = basket.totalSupply();
        require(supply != 0, "uninitialized");
        uint256[4] memory reserves = basket.reserves();
        uint256 value;
        uint256 time = block.timestamp;
        for (uint256 i; i < 4; ++i) {
            (uint256 price, uint256 updated) = sources[i].priceUsd();
            require(price > 0 && updated > 0 && updated <= block.timestamp, "price");
            value += Math.mulDiv(reserves[i], price, scales[i]);
            time = Math.min(time, updated);
        }
        uint256 nav = Math.mulDiv(value, 1e18, supply);
        require(nav > 0 && nav <= uint256(type(int256).max), "nav");
        return (1, int256(nav), time, time, 1);
    }
}
