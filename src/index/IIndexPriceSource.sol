// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IIndexPriceSource {
    function baseToken() external view returns (address);
    function priceUsd() external view returns (uint256 priceE18, uint256 updatedAt);
    function update() external;
}

interface IMemeBasketIndex {
    function latestIndex() external view returns (uint256 pointsE18, uint256 updatedAt);
    function updatePrices() external;
}
