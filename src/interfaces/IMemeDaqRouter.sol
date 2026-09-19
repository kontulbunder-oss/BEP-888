// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

/// @title IMemeDaqRouter
/// @notice Stateless exact-in router for MemeDAQ pools (no Permit2, full-fill accounting, partial-fill refund).
interface IMemeDaqRouter {
    event Trade(
        address indexed meme,
        address indexed trader,
        address indexed quote,
        bool isBuy,
        uint256 amountIn,
        uint256 amountOut
    );

    error BadValue();
    error BadAmount();
    error BadRecipient();
    error Expired();
    error NotVault();
    error Unsettled();
    error TooLittleReceived(uint256 out, uint256 minOut);

    /// @notice Buys `meme` with exactly `amountIn` of `quote` (address(0) = BNB, sent as msg.value).
    function buy(address meme, address quote, uint256 amountIn, uint256 minOut, address to, uint256 deadline)
        external
        payable
        returns (uint256 out);

    /// @notice Sells exactly `amountIn` of `meme` for `quote`. Needs `meme.approve(router, amountIn)`.
    function sell(address meme, address quote, uint256 amountIn, uint256 minOut, address to, uint256 deadline)
        external
        returns (uint256 out);
}
