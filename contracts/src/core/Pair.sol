// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Implemented by contracts that receive a flash swap.
interface IFlashSwapCallee {
    function flashSwapCall(address sender, uint256 amount0Out, uint256 amount1Out, bytes calldata data) external;
}

/// @notice Read by a new Pair during construction to learn its two tokens.
interface IPairDeployer {
    function parameters() external view returns (address token0, address token1);
}

/// @title Pair
/// @notice A constant-product liquidity pool for two tokens. It is also the ERC20 LP token
///         for its liquidity providers.
///
/// HOW IT WORKS
///
/// The pool holds `reserve0` of token0 and `reserve1` of token1 and keeps their product
/// (`k = reserve0 * reserve1`) from going down. To buy some token1 you must add enough token0
/// that the product, after a 0.3% fee on what you added, is at least what it was before.
/// The bigger your trade compared to the pool, the worse the price you get (price impact).
///
/// The fee stays in the pool, so `k` slowly grows and every LP token becomes redeemable
/// for a bit more of both tokens over time. That's how liquidity providers earn.
///
/// Like Uniswap V2, the pair is a low-level contract: tokens are sent to it first, then
/// `mint`, `burn` or `swap` compares its balances with its stored reserves to see what came
/// in. End users go through the Router, which adds slippage and deadline protection.
contract Pair is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice LP tokens permanently locked on the first deposit. Makes the first-depositor
    ///         "inflation" attack uneconomical and keeps the pool from ever being fully emptied.
    uint256 public constant MINIMUM_LIQUIDITY = 1_000;

    /// @notice Swap fee in basis points (30 = 0.3%), paid to liquidity providers.
    uint256 public constant FEE_BPS = 30;

    /// @dev OpenZeppelin's ERC20 can't mint to address(0), so locked liquidity goes here.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable factory;
    address public immutable token0;
    address public immutable token1;

    uint112 private _reserve0;
    uint112 private _reserve1;
    uint32 private _blockTimestampLast;

    /// @notice Time-weighted price accumulators (UQ112x112), for on-chain TWAP oracles.
    ///         price0 = token1 per token0. Overflow is expected and harmless: consumers take differences.
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    error Locked();
    error Overflow();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InsufficientLiquidity();
    error InvalidTo();
    error K();

    event Mint(address indexed sender, address indexed to, uint256 amount0, uint256 amount1, uint256 liquidity);
    event Burn(address indexed sender, address indexed to, uint256 amount0, uint256 amount1, uint256 liquidity);
    event Swap(
        address indexed sender,
        address indexed to,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() ERC20("Mini DEX LP", "MDEX-LP") {
        factory = msg.sender;
        (token0, token1) = IPairDeployer(msg.sender).parameters();
    }

    /// @notice Current reserves. Reverts while a swap, mint or burn is in progress: during a flash
    ///         swap the reserves are stale, and another contract reading them as a price would be
    ///         exposed to "read-only reentrancy" manipulation.
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) {
        if (_reentrancyGuardEntered()) revert Locked();
        return (_reserve0, _reserve1, _blockTimestampLast);
    }

    // ------------------------------------------------------------------
    // Liquidity
    // ------------------------------------------------------------------

    /// @notice Mint LP tokens for tokens already sent to the pair.
    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        (uint112 r0, uint112 r1) = (_reserve0, _reserve1);
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - r0;
        uint256 amount1 = balance1 - r1;

        uint256 supply = totalSupply();
        // slither-disable-next-line incorrect-equality
        if (supply == 0) {
            // First deposit sets the price. LP supply starts at the geometric mean of the amounts.
            uint256 root = Math.sqrt(amount0 * amount1);
            if (root <= MINIMUM_LIQUIDITY) revert InsufficientLiquidityMinted();
            liquidity = root - MINIMUM_LIQUIDITY;
            _mint(DEAD, MINIMUM_LIQUIDITY);
        } else {
            // Later deposits get LP in proportion to what they add. Adding off-ratio
            // only counts the smaller side, so it can't be used to shift the price for free.
            liquidity = Math.min((amount0 * supply) / r0, (amount1 * supply) / r1);
        }
        // slither-disable-next-line incorrect-equality
        if (liquidity == 0) revert InsufficientLiquidityMinted();

        _mint(to, liquidity);
        _update(balance0, balance1, r0, r1);
        emit Mint(msg.sender, to, amount0, amount1, liquidity);
    }

    /// @notice Burn the LP tokens sent to the pair and return the underlying tokens to `to`.
    function burn(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        (uint112 r0, uint112 r1) = (_reserve0, _reserve1);
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        uint256 supply = totalSupply();
        amount0 = (liquidity * balance0) / supply;
        amount1 = (liquidity * balance1) / supply;
        // slither-disable-next-line incorrect-equality
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        _burn(address(this), liquidity);
        IERC20(token0).safeTransfer(to, amount0);
        IERC20(token1).safeTransfer(to, amount1);

        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));
        _update(balance0, balance1, r0, r1);
        emit Burn(msg.sender, to, amount0, amount1, liquidity);
    }

    // ------------------------------------------------------------------
    // Swaps
    // ------------------------------------------------------------------

    /// @notice Send out `amount0Out`/`amount1Out` to `to`. Input must already be in the pair,
    ///         or (flash swap) be sent back during the `flashSwapCall` callback when `data` is
    ///         non-empty. Either way, the constant-product check runs after.
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external nonReentrant {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();
        if (amount0Out >= _reserve0 || amount1Out >= _reserve1) revert InsufficientLiquidity();
        if (to == token0 || to == token1) revert InvalidTo();

        // Optimistically send the output first. This is what makes flash swaps possible.
        if (amount0Out > 0) IERC20(token0).safeTransfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).safeTransfer(to, amount1Out);
        if (data.length > 0) IFlashSwapCallee(to).flashSwapCall(msg.sender, amount0Out, amount1Out, data);

        _settleSwap(amount0Out, amount1Out, to);
    }

    /// @notice Send tokens above the reserves (e.g. accidental transfers) to `to`.
    function skim(address to) external nonReentrant {
        IERC20(token0).safeTransfer(to, IERC20(token0).balanceOf(address(this)) - _reserve0);
        IERC20(token1).safeTransfer(to, IERC20(token1).balanceOf(address(this)) - _reserve1);
    }

    /// @notice Set the reserves to the current balances.
    function sync() external nonReentrant {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), _reserve0, _reserve1);
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    /// @dev Works out what came in, enforces the constant-product rule after fees, stores the
    ///      new reserves and emits Swap. Split out of `swap` to keep each function's stack small.
    ///      Reserves can't have changed since `swap` read them: the pair is locked.
    function _settleSwap(uint256 amount0Out, uint256 amount1Out, address to) private {
        uint256 amount0In;
        uint256 amount1In;
        {
            (uint112 r0, uint112 r1) = (_reserve0, _reserve1);
            uint256 balance0 = IERC20(token0).balanceOf(address(this));
            uint256 balance1 = IERC20(token1).balanceOf(address(this));
            amount0In = balance0 > r0 - amount0Out ? balance0 - (r0 - amount0Out) : 0;
            amount1In = balance1 > r1 - amount1Out ? balance1 - (r1 - amount1Out) : 0;
            // slither-disable-next-line incorrect-equality
            if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

            // k must not decrease after charging the fee on the input:
            // (balance0 - 0.3% of amount0In) * (balance1 - 0.3% of amount1In) >= reserve0 * reserve1
            uint256 adjusted0 = balance0 * 10_000 - amount0In * FEE_BPS;
            uint256 adjusted1 = balance1 * 10_000 - amount1In * FEE_BPS;
            if (adjusted0 * adjusted1 < uint256(r0) * uint256(r1) * 1e8) revert K();

            _update(balance0, balance1, r0, r1);
        }
        emit Swap(msg.sender, to, amount0In, amount1In, amount0Out, amount1Out);
    }

    /// @dev Stores new reserves and, on the first update of each block, accumulates the
    ///      previous price weighted by how long it lasted.
    function _update(uint256 balance0, uint256 balance1, uint112 r0, uint112 r1) private {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert Overflow();
        uint32 blockTimestamp = uint32(block.timestamp); // truncation is intended; wraps in 2106
        unchecked {
            uint32 elapsed = blockTimestamp - _blockTimestampLast; // wraps around by design
            if (elapsed > 0 && r0 != 0 && r1 != 0) {
                // UQ112x112 price times seconds. Overflow is intended: consumers use differences.
                // slither-disable-next-line divide-before-multiply
                price0CumulativeLast += ((uint256(r1) << 112) / r0) * elapsed;
                // slither-disable-next-line divide-before-multiply
                price1CumulativeLast += ((uint256(r0) << 112) / r1) * elapsed;
            }
        }
        _reserve0 = uint112(balance0);
        _reserve1 = uint112(balance1);
        _blockTimestampLast = blockTimestamp;
        emit Sync(_reserve0, _reserve1);
    }
}
