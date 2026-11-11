// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Factory} from "../../src/core/Factory.sol";
import {Pair} from "../../src/core/Pair.sol";
import {Router} from "../../src/periphery/Router.sol";
import {FlashArbitrage} from "../../src/periphery/FlashArbitrage.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {DexHandler} from "./DexHandler.sol";

/// @notice Properties that must hold after ANY sequence of swaps (single and multi-hop),
///         liquidity adds and removals, donations, arbitrage cycles and time jumps.
contract DexInvariantTest is StdInvariant, Test {
    Factory internal factory;
    Router internal router;
    FlashArbitrage internal arbitrage;
    MockERC20[3] internal tokens;
    DexHandler internal handler;

    function setUp() public {
        factory = new Factory();
        router = new Router(address(factory));
        arbitrage = new FlashArbitrage(address(factory));
        tokens[0] = new MockERC20("Ether", "ETH");
        tokens[1] = new MockERC20("Bitcoin", "BTC");
        tokens[2] = new MockERC20("Dollar", "USD");

        // Seed the three pools at consistent prices.
        _seed(tokens[0], 100e18, tokens[2], 300_000e18);
        _seed(tokens[1], 5e18, tokens[2], 300_000e18);
        _seed(tokens[0], 100e18, tokens[1], 5e18);

        handler = new DexHandler(factory, router, arbitrage, tokens);
        targetContract(address(handler));
    }

    function _seed(MockERC20 a, uint256 amountA, MockERC20 b, uint256 amountB) internal {
        a.mint(address(this), amountA);
        b.mint(address(this), amountB);
        a.approve(address(router), amountA);
        b.approve(address(router), amountB);
        router.addLiquidity(address(a), address(b), amountA, amountB, 0, 0, address(this), type(uint256).max);
    }

    /// Every pair's stored reserves equal its actual token balances.
    function invariant_ReservesMatchBalances() public view {
        for (uint256 i = 0; i < handler.pairCount(); ++i) {
            Pair pair = handler.pairs(i);
            (uint112 r0, uint112 r1,) = pair.getReserves();
            assertEq(MockERC20(pair.token0()).balanceOf(address(pair)), r0);
            assertEq(MockERC20(pair.token1()).balanceOf(address(pair)), r1);
        }
    }

    /// The value behind each LP token (k / supply^2) never goes down: no action can take value from LPs.
    function invariant_LpShareValueNeverDecreases() public view {
        assertFalse(handler.shareValueDecreased());
    }

    /// The minimum liquidity stays locked, so no pool can ever be fully drained.
    function invariant_MinimumLiquidityLocked() public view {
        for (uint256 i = 0; i < handler.pairCount(); ++i) {
            Pair pair = handler.pairs(i);
            assertEq(pair.balanceOf(pair.DEAD()), pair.MINIMUM_LIQUIDITY());
            (uint112 r0, uint112 r1,) = pair.getReserves();
            assertGt(r0, 0);
            assertGt(r1, 0);
        }
    }

    /// The router and the arbitrage contract never keep anyone's tokens.
    function invariant_PeripheryHoldsNoFunds() public view {
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(tokens[i].balanceOf(address(router)), 0);
            assertEq(tokens[i].balanceOf(address(arbitrage)), 0);
        }
    }
}
