// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

/// @title IChainlinkFeed
/// @notice Minimal Chainlink AggregatorV3 interface used for quote-currency USD prices.
interface IChainlinkFeed {
    /// @notice Number of decimals of `answer` (8 for every BSC USD feed we use).
    function decimals() external view returns (uint8);

    /// @notice Human readable feed name, e.g. "BNB / USD".
    function description() external view returns (string memory);

    /// @notice Latest round data.
    /// @return roundId The round id.
    /// @return answer The price, scaled by `decimals()`.
    /// @return startedAt Round start timestamp.
    /// @return updatedAt Timestamp of the last update.
    /// @return answeredInRound Deprecated round id.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
