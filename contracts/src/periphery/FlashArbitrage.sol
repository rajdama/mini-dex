// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pair, IFlashSwapCallee} from "../core/Pair.sol";
import {DexLibrary} from "./DexLibrary.sol";

/// @title FlashArbitrage
/// @notice Trades a cycle of pools (e.g. ETH -> USD -> BTC -> ETH) in one transaction when the
///         cycle returns more than it started with, and pays the profit to the caller.
///
/// It needs no starting capital: it flash-borrows the first hop's output from the first pool,
/// trades it through the rest of the cycle, then repays the first pool with part of what comes
/// back. If the cycle isn't profitable enough, everything reverts and only gas is spent.
///
/// Arbitrage is what keeps prices consistent across pools: each trade pushes the mispriced
/// pools back toward each other.
contract FlashArbitrage is IFlashSwapCallee {
    using SafeERC20 for IERC20;

    address public immutable factory;

    error Expired();
    error InvalidPath();
    error NotProfitable(uint256 amountIn, uint256 amountOut);
    error UnauthorizedCallback();

    event ArbitrageExecuted(address indexed caller, address indexed token, uint256 amountIn, uint256 profit);

    constructor(address factory_) {
        factory = factory_;
    }

    /// @notice Expected output of trading `amountIn` around `path` (path[0] == path[last]).
    ///         Profit is `amounts[last] - amountIn` when positive.
    function quote(address[] calldata path, uint256 amountIn) external view returns (uint256[] memory amounts) {
        _checkPath(path);
        return DexLibrary.getAmountsOut(factory, amountIn, path);
    }

    /// @notice Run the cycle with `amountIn` of path[0]; revert unless profit >= `minProfit`.
    function execute(address[] calldata path, uint256 amountIn, uint256 minProfit, uint256 deadline)
        external
        returns (uint256 profit)
    {
        if (block.timestamp > deadline) revert Expired();
        _checkPath(path);

        uint256[] memory amounts = DexLibrary.getAmountsOut(factory, amountIn, path);
        uint256 amountOut = amounts[amounts.length - 1];
        if (amountOut < amountIn + minProfit || amountOut <= amountIn) revert NotProfitable(amountIn, amountOut);

        // Flash-borrow the first hop's output; the rest happens in flashSwapCall.
        address firstPair = DexLibrary.pairFor(factory, path[0], path[1]);
        (address token0,) = DexLibrary.sortTokens(path[0], path[1]);
        (uint256 out0, uint256 out1) = path[0] == token0 ? (uint256(0), amounts[1]) : (amounts[1], uint256(0));
        Pair(firstPair).swap(out0, out1, address(this), abi.encode(path, amounts));

        profit = IERC20(path[0]).balanceOf(address(this));
        IERC20(path[0]).safeTransfer(msg.sender, profit);
        emit ArbitrageExecuted(msg.sender, path[0], amountIn, profit);
    }

    /// @dev Called by the first pair mid-swap. Trades the borrowed tokens around the rest of
    ///      the cycle, then repays the first pair with `amounts[0]` of path[0].
    function flashSwapCall(address sender, uint256, uint256, bytes calldata data) external {
        (address[] memory path, uint256[] memory amounts) = abi.decode(data, (address[], uint256[]));
        // Only a flash swap this contract started, from the pair it expects, may get here.
        if (sender != address(this) || msg.sender != DexLibrary.pairFor(factory, path[0], path[1])) {
            revert UnauthorizedCallback();
        }

        for (uint256 i = 1; i < path.length - 1; ++i) {
            address pair = DexLibrary.pairFor(factory, path[i], path[i + 1]);
            (address token0,) = DexLibrary.sortTokens(path[i], path[i + 1]);
            (uint256 out0, uint256 out1) =
                path[i] == token0 ? (uint256(0), amounts[i + 1]) : (amounts[i + 1], uint256(0));
            IERC20(path[i]).safeTransfer(pair, amounts[i]);
            Pair(pair).swap(out0, out1, address(this), new bytes(0));
        }

        IERC20(path[0]).safeTransfer(msg.sender, amounts[0]);
    }

    function _checkPath(address[] calldata path) internal pure {
        if (path.length < 3 || path[0] != path[path.length - 1]) revert InvalidPath();
    }
}
