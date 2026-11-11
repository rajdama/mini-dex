// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Factory} from "../core/Factory.sol";
import {Pair} from "../core/Pair.sol";
import {DexLibrary} from "./DexLibrary.sol";

/// @title Router
/// @notice The user-facing entry point. Adds what the low-level Pair leaves out:
///         - slippage protection (min/max amounts), so a trade can't fill at a much worse price
///           than the user saw, e.g. because of a sandwich attack;
///         - deadlines, so a transaction stuck in the mempool can't execute days later;
///         - multi-hop swaps along a path of pairs, and liquidity at the current pool ratio.
/// @dev Holds no funds between transactions: tokens go straight from the user to the pairs.
contract Router {
    using SafeERC20 for IERC20;

    address public immutable factory;

    error Expired();
    error InsufficientAAmount();
    error InsufficientBAmount();
    error InsufficientOutputAmount();
    error ExcessiveInputAmount();

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    constructor(address factory_) {
        factory = factory_;
    }

    // ------------------------------------------------------------------
    // Liquidity
    // ------------------------------------------------------------------

    /// @notice Add liquidity at the pool's current ratio (creating the pair if needed).
    ///         Uses as much of the desired amounts as the ratio allows, never less than the minimums.
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        if (Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            Factory(factory).createPair(tokenA, tokenB);
        }
        (amountA, amountB) = _optimalAmounts(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);

        address pair = DexLibrary.pairFor(factory, tokenA, tokenB);
        IERC20(tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pair, amountB);
        liquidity = Pair(pair).mint(to);
    }

    /// @notice Burn `liquidity` LP tokens and receive at least the minimum amounts of each token.
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = DexLibrary.pairFor(factory, tokenA, tokenB);
        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity);
        (uint256 amount0, uint256 amount1) = Pair(pair).burn(to);

        (address token0,) = DexLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        if (amountA < amountAMin) revert InsufficientAAmount();
        if (amountB < amountBMin) revert InsufficientBAmount();
    }

    // ------------------------------------------------------------------
    // Swaps
    // ------------------------------------------------------------------

    /// @notice Swap an exact `amountIn` of path[0] for at least `amountOutMin` of the last token.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        amounts = DexLibrary.getAmountsOut(factory, amountIn, path);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutputAmount();
        IERC20(path[0]).safeTransferFrom(msg.sender, DexLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    /// @notice Receive an exact `amountOut` of the last token for at most `amountInMax` of path[0].
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        amounts = DexLibrary.getAmountsIn(factory, amountOut, path);
        if (amounts[0] > amountInMax) revert ExcessiveInputAmount();
        IERC20(path[0]).safeTransferFrom(msg.sender, DexLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    // ------------------------------------------------------------------
    // Quotes (used by the frontend and bots)
    // ------------------------------------------------------------------

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) external pure returns (uint256) {
        return DexLibrary.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256) {
        return DexLibrary.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256) {
        return DexLibrary.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory) {
        return DexLibrary.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory) {
        return DexLibrary.getAmountsIn(factory, amountOut, path);
    }

    /// @notice Reserves of the tokenA/tokenB pool, ordered as (tokenA, tokenB).
    function getReserves(address tokenA, address tokenB) external view returns (uint256, uint256) {
        return DexLibrary.getReserves(factory, tokenA, tokenB);
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _optimalAmounts(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal view returns (uint256 amountA, uint256 amountB) {
        (uint256 reserveA, uint256 reserveB) = DexLibrary.getReserves(factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            return (amountADesired, amountBDesired); // first deposit sets the price
        }
        uint256 amountBOptimal = DexLibrary.quote(amountADesired, reserveA, reserveB);
        if (amountBOptimal <= amountBDesired) {
            if (amountBOptimal < amountBMin) revert InsufficientBAmount();
            return (amountADesired, amountBOptimal);
        }
        uint256 amountAOptimal = DexLibrary.quote(amountBDesired, reserveB, reserveA);
        if (amountAOptimal < amountAMin) revert InsufficientAAmount();
        return (amountAOptimal, amountBDesired);
    }

    /// @dev Each hop sends its output straight to the next pair; the last hop sends to `to`.
    function _swap(uint256[] memory amounts, address[] calldata path, address to) internal {
        for (uint256 i = 0; i < path.length - 1; ++i) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = DexLibrary.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address recipient = i < path.length - 2 ? DexLibrary.pairFor(factory, output, path[i + 2]) : to;
            Pair(DexLibrary.pairFor(factory, input, output)).swap(amount0Out, amount1Out, recipient, new bytes(0));
        }
    }
}
