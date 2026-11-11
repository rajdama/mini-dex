// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Factory} from "../core/Factory.sol";
import {Pair} from "../core/Pair.sol";

/// @title DexLibrary
/// @notice Price math shared by the Router and the arbitrage contract.
library DexLibrary {
    error IdenticalTokens();
    error PairNotFound(address tokenA, address tokenB);
    error InsufficientAmount();
    error InsufficientInputAmount();
    error InsufficientOutputAmount();
    error InsufficientLiquidity();
    error InvalidPath();

    uint256 internal constant FEE_DENOMINATOR = 10_000;
    uint256 internal constant FEE_MULTIPLIER = 9_970; // 1 - 0.3%

    /// @notice Whether `token` is token0 of its pair with `other` (pairs order tokens by address).
    function isToken0(address token, address other) internal pure returns (bool) {
        if (token == other) revert IdenticalTokens();
        return token < other;
    }

    function pairFor(address factory, address tokenA, address tokenB) internal view returns (address pair) {
        pair = Factory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairNotFound(tokenA, tokenB);
    }

    /// @notice Reserves ordered as (tokenA, tokenB).
    function getReserves(address factory, address tokenA, address tokenB)
        internal
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        bool aIsToken0 = isToken0(tokenA, tokenB);
        // slither-disable-next-line unused-return
        (uint112 r0, uint112 r1,) = Pair(pairFor(factory, tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = aIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// @notice Amount of B worth `amountA` at the current price, without fees or price impact.
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256) {
        if (amountA == 0) revert InsufficientAmount();
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();
        return (amountA * reserveB) / reserveA;
    }

    /// @notice Output for an exact input, after the 0.3% fee:
    ///         out = in * 0.997 * reserveOut / (reserveIn + in * 0.997)
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 amountInWithFee = amountIn * FEE_MULTIPLIER;
        return (amountInWithFee * reserveOut) / (reserveIn * FEE_DENOMINATOR + amountInWithFee);
    }

    /// @notice Input needed for an exact output, after the 0.3% fee (rounded up).
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        if (amountOut == 0) revert InsufficientOutputAmount();
        if (reserveIn == 0 || reserveOut == 0 || amountOut >= reserveOut) revert InsufficientLiquidity();
        return (reserveIn * amountOut * FEE_DENOMINATOR) / ((reserveOut - amountOut) * FEE_MULTIPLIER) + 1;
    }

    function getAmountsOut(address factory, uint256 amountIn, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        if (path.length < 2) revert InvalidPath();
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 0; i < path.length - 1; ++i) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    function getAmountsIn(address factory, uint256 amountOut, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        if (path.length < 2) revert InvalidPath();
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; --i) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
}
