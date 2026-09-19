// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {IIndexPriceSource, IMemeBasketIndex} from "./IIndexPriceSource.sol";

/// @notice On-chain, price-return basket. It is a benchmark, not an ERC20 or a redeemable asset vault.
///         Weights apply at the latest rebalance; constituent weights subsequently drift with their returns.
contract MemeBasketIndex is Ownable2Step, IMemeBasketIndex {
    uint256 public constant INITIAL_POINTS = 1000e18;
    uint256 public constant MAX_COMPONENTS = 16;
    uint256 public constant REBALANCE_DELAY = 1 days;
    struct ComponentInput { address token; IIndexPriceSource source; uint16 weightBps; }
    struct Component { address token; IIndexPriceSource source; uint16 weightBps; uint256 basePriceE18; }
    Component[] private _components;
    uint256 public anchorPoints;
    uint256 public revision;
    uint256 public lastGoodPoints;
    uint256 public lastGoodAt;
    bytes32 public pendingBasketHash;
    uint256 public pendingBasketAt;
    error BadBasket();
    error NotReady();
    event BasketProposed(bytes32 indexed basketHash, uint256 executableAt);
    event BasketProposalCancelled(bytes32 indexed basketHash);
    event BasketActivated(uint256 indexed revision, uint256 anchorPoints, ComponentInput[] components);
    event BasketRecovered(uint256 indexed revision, uint256 preservedPoints, uint256 lastHealthyAt);

    constructor(address owner_) Ownable(owner_) {}

    function initialize(ComponentInput[] calldata input) external onlyOwner {
        if (revision != 0) revert BadBasket();
        _replace(input, INITIAL_POINTS);
    }

    function getConstituents() external view returns (Component[] memory) { return _components; }
    function componentCount() external view returns (uint256) { return _components.length; }

    function _prices() internal view returns (uint256[] memory prices, uint256 time) {
        uint256 n = _components.length;
        if (n == 0) revert NotReady();
        prices = new uint256[](n);
        time = block.timestamp;
        for (uint256 i; i < n; ++i) {
            (uint256 value, uint256 timestamp) = _components[i].source.priceUsd();
            if (value == 0 || timestamp == 0 || timestamp > block.timestamp) revert NotReady();
            prices[i] = value;
            if (timestamp < time) time = timestamp;
        }
    }

    function _points(uint256[] memory prices) internal view returns (uint256 points) {
        uint256 performance;
        for (uint256 i; i < prices.length; ++i) {
            Component storage c = _components[i];
            performance += FullMath.mulDiv(prices[i], uint256(c.weightBps) * 1e18, c.basePriceE18);
        }
        points = FullMath.mulDiv(anchorPoints, performance, 10000e18);
        if (points == 0) revert NotReady();
    }

    function latestIndex() public view returns (uint256 pointsE18, uint256 updatedAt) {
        (uint256[] memory prices, uint256 time) = _prices();
        return (_points(prices), time);
    }

    function snapshot() external view returns (uint256 pointsE18, uint256 updatedAt, uint256[] memory pricesE18) {
        (pricesE18, updatedAt) = _prices();
        pointsE18 = _points(pricesE18);
    }

    /// @notice Anyone may maintain the immutable price sources; no permission to set arbitrary prices.
    function updatePrices() external {
        for (uint256 i; i < _components.length; ++i) _components[i].source.update();
        // Maintenance must still succeed while a V2 source is rewarming. Never publish a fallback as a live price.
        try this.latestIndex() returns (uint256 points, uint256) {
            lastGoodPoints = points;
            lastGoodAt = block.timestamp;
        } catch {}
    }

    function proposeBasket(ComponentInput[] calldata input) external onlyOwner {
        if (revision == 0) revert NotReady();
        _validate(input);
        pendingBasketHash = keccak256(abi.encode(input));
        pendingBasketAt = block.timestamp + REBALANCE_DELAY;
        emit BasketProposed(pendingBasketHash, pendingBasketAt);
    }

    function cancelBasket() external onlyOwner {
        emit BasketProposalCancelled(pendingBasketHash);
        delete pendingBasketHash;
        delete pendingBasketAt;
    }

    /// @notice Execute exactly the announced basket after one day. The previous index level is preserved.
    function executeBasket(ComponentInput[] calldata input) external {
        if (pendingBasketHash == bytes32(0) || block.timestamp < pendingBasketAt || keccak256(abi.encode(input)) != pendingBasketHash) revert NotReady();
        (uint256 previous,) = latestIndex();
        delete pendingBasketHash;
        delete pendingBasketAt;
        _replace(input, previous);
    }

    /// @notice Recovery from an unreadable constituent: the same one-day proposal and at least one day since
    ///         the last valid checkpoint are required. Only the last on-chain computed level can be preserved.
    ///         Normal reads continue to fail until replacement; an operator cannot supply an arbitrary level.
    function executeRecoveryBasket(ComponentInput[] calldata input) external {
        if (pendingBasketHash == bytes32(0) || block.timestamp < pendingBasketAt
            || keccak256(abi.encode(input)) != pendingBasketHash || lastGoodPoints == 0
            || block.timestamp < lastGoodAt + REBALANCE_DELAY) revert NotReady();
        try this.latestIndex() returns (uint256, uint256) { revert NotReady(); } catch {}
        uint256 points = lastGoodPoints;
        uint256 healthyAt = lastGoodAt;
        delete pendingBasketHash;
        delete pendingBasketAt;
        _replace(input, points);
        emit BasketRecovered(revision, points, healthyAt);
    }

    function _validate(ComponentInput[] calldata input) internal view {
        uint256 n = input.length;
        if (n < 2 || n > MAX_COMPONENTS) revert BadBasket();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            ComponentInput calldata c = input[i];
            if (c.token.code.length == 0 || address(c.source).code.length == 0 || c.weightBps == 0 || c.source.baseToken() != c.token) revert BadBasket();
            sum += c.weightBps;
            for (uint256 j; j < i; ++j) if (c.token == input[j].token) revert BadBasket();
        }
        if (sum != 10000) revert BadBasket();
    }

    function _replace(ComponentInput[] calldata input, uint256 points) internal {
        _validate(input);
        delete _components;
        for (uint256 i; i < input.length; ++i) {
            ComponentInput calldata c = input[i];
            (uint256 price, uint256 time) = c.source.priceUsd();
            if (price == 0 || time == 0 || time > block.timestamp) revert NotReady();
            _components.push(Component(c.token, c.source, c.weightBps, price));
        }
        anchorPoints = points;
        lastGoodPoints = points;
        lastGoodAt = block.timestamp;
        ++revision;
        emit BasketActivated(revision, points, input);
    }
}
