// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Router} from "../src/periphery/Router.sol";
import {DexLibrary} from "../src/periphery/DexLibrary.sol";
import {Pair} from "../src/core/Pair.sol";
import {DexFixture} from "./utils/DexFixture.sol";

contract RouterTest is DexFixture {
    function setUp() public {
        _deployDex();
    }

    // ------------------------------------------------------------------
    // Liquidity
    // ------------------------------------------------------------------
    function test_RevertWhen_ConstructedWithZeroFactory() public {
        vm.expectRevert(Router.ZeroAddress.selector);
        new Router(address(0));
    }

    function test_AddLiquidityCreatesPair() public {
        uint256 liquidity = _addLiquidity(eth, usd, 10e18, 30_000e18);
        Pair pair = _pair(eth, usd);
        assertTrue(address(pair) != address(0));
        assertEq(pair.balanceOf(lp), liquidity);
        (uint256 rEth, uint256 rUsd) = router.getReserves(address(eth), address(usd));
        assertEq(rEth, 10e18);
        assertEq(rUsd, 30_000e18);
    }

    function test_AddLiquidityUsesPoolRatioWhenTooMuchB() public {
        _addLiquidity(eth, usd, 10e18, 30_000e18);
        eth.mint(alice, 1e18);
        usd.mint(alice, 5_000e18);
        vm.startPrank(alice);
        eth.approve(address(router), 1e18);
        usd.approve(address(router), 5_000e18);
        (uint256 a, uint256 b,) = router.addLiquidity(address(eth), address(usd), 1e18, 5_000e18, 0, 0, alice, DEADLINE);
        vm.stopPrank();
        assertEq(a, 1e18);
        assertEq(b, 3_000e18); // only what the ratio needs
        assertEq(usd.balanceOf(alice), 2_000e18);
    }

    function test_AddLiquidityUsesPoolRatioWhenTooMuchA() public {
        _addLiquidity(eth, usd, 10e18, 30_000e18);
        eth.mint(alice, 5e18);
        usd.mint(alice, 3_000e18);
        vm.startPrank(alice);
        eth.approve(address(router), 5e18);
        usd.approve(address(router), 3_000e18);
        (uint256 a, uint256 b,) = router.addLiquidity(address(eth), address(usd), 5e18, 3_000e18, 0, 0, alice, DEADLINE);
        vm.stopPrank();
        assertEq(a, 1e18);
        assertEq(b, 3_000e18);
    }

    function test_RevertWhen_AddLiquidityBelowMinB() public {
        _addLiquidity(eth, usd, 10e18, 30_000e18);
        vm.prank(alice);
        vm.expectRevert(Router.InsufficientBAmount.selector);
        router.addLiquidity(address(eth), address(usd), 1e18, 5_000e18, 0, 3_001e18, alice, DEADLINE);
    }

    function test_RevertWhen_AddLiquidityBelowMinA() public {
        _addLiquidity(eth, usd, 10e18, 30_000e18);
        vm.prank(alice);
        vm.expectRevert(Router.InsufficientAAmount.selector);
        router.addLiquidity(address(eth), address(usd), 5e18, 3_000e18, 2e18, 0, alice, DEADLINE);
    }

    function test_RemoveLiquidity() public {
        uint256 liquidity = _addLiquidity(eth, usd, 10e18, 30_000e18);
        Pair pair = _pair(eth, usd);
        vm.startPrank(lp);
        pair.approve(address(router), liquidity);
        (uint256 a, uint256 b) = router.removeLiquidity(address(usd), address(eth), liquidity, 0, 0, lp, DEADLINE);
        vm.stopPrank();
        // Order follows the arguments: usd first.
        assertApproxEqRel(a, 30_000e18, 1e12);
        assertApproxEqRel(b, 10e18, 1e12);
        assertEq(usd.balanceOf(lp), a);
        assertEq(eth.balanceOf(lp), b);
    }

    function test_RevertWhen_RemoveLiquidityBelowMins() public {
        uint256 liquidity = _addLiquidity(eth, usd, 10e18, 30_000e18);
        Pair pair = _pair(eth, usd);
        vm.startPrank(lp);
        pair.approve(address(router), liquidity);
        vm.expectRevert(Router.InsufficientAAmount.selector);
        router.removeLiquidity(address(eth), address(usd), liquidity, 10e18, 0, lp, DEADLINE);
        vm.expectRevert(Router.InsufficientBAmount.selector);
        router.removeLiquidity(address(eth), address(usd), liquidity, 0, 30_000e18, lp, DEADLINE);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Swaps
    // ------------------------------------------------------------------
    function test_SwapExactInMatchesQuote() public {
        _addLiquidity(eth, usd, 100e18, 300_000e18);
        address[] memory path = _path(address(eth), address(usd));
        uint256 expected = router.getAmountsOut(1e18, path)[1];
        // 1 ETH at 3,000 minus 0.3% fee and ~1% price impact.
        assertApproxEqRel(expected, 2_961.47e18, 1e15);

        assertEq(_swapExactIn(alice, 1e18, path), expected);
        assertEq(usd.balanceOf(alice), expected);
    }

    function test_SwapExactOut() public {
        _addLiquidity(eth, usd, 100e18, 300_000e18);
        address[] memory path = _path(address(usd), address(eth));
        uint256 needed = router.getAmountsIn(1e18, path)[0];

        usd.mint(alice, needed);
        vm.startPrank(alice);
        usd.approve(address(router), needed);
        router.swapTokensForExactTokens(1e18, needed, path, alice, DEADLINE);
        vm.stopPrank();

        assertEq(eth.balanceOf(alice), 1e18);
        assertEq(usd.balanceOf(alice), 0);
    }

    function test_MultiHopSwap() public {
        _seedThreePools();
        address[] memory path = _path(address(btc), address(usd), address(eth));
        uint256 out = _swapExactIn(alice, 0.1e18, path);
        // 0.1 BTC = 6,000 USD = 2 ETH, minus two 0.3% fees and ~2% price impact per hop.
        assertApproxEqRel(out, 1.912e18, 0.001e18);
        assertLt(out, 2e18);
        assertEq(eth.balanceOf(alice), out);
        assertEq(usd.balanceOf(address(router)), 0); // router never holds funds
    }

    function test_RevertWhen_SlippageExceeded() public {
        _addLiquidity(eth, usd, 100e18, 300_000e18);
        address[] memory path = _path(address(eth), address(usd));
        uint256 expected = router.getAmountsOut(1e18, path)[1];
        eth.mint(alice, 1e18);
        vm.startPrank(alice);
        eth.approve(address(router), 1e18);
        vm.expectRevert(Router.InsufficientOutputAmount.selector);
        router.swapExactTokensForTokens(1e18, expected + 1, path, alice, DEADLINE);
        vm.stopPrank();
    }

    function test_RevertWhen_ExactOutCostsTooMuch() public {
        _addLiquidity(eth, usd, 100e18, 300_000e18);
        address[] memory path = _path(address(usd), address(eth));
        uint256 needed = router.getAmountsIn(1e18, path)[0];
        vm.prank(alice);
        vm.expectRevert(Router.ExcessiveInputAmount.selector);
        router.swapTokensForExactTokens(1e18, needed - 1, path, alice, DEADLINE);
    }

    function test_RevertWhen_DeadlinePassed() public {
        vm.warp(1_000);
        address[] memory path = _path(address(eth), address(usd));
        vm.expectRevert(Router.Expired.selector);
        router.swapExactTokensForTokens(1, 0, path, alice, 999);
        vm.expectRevert(Router.Expired.selector);
        router.swapTokensForExactTokens(1, 0, path, alice, 999);
        vm.expectRevert(Router.Expired.selector);
        router.addLiquidity(address(eth), address(usd), 1, 1, 0, 0, alice, 999);
        vm.expectRevert(Router.Expired.selector);
        router.removeLiquidity(address(eth), address(usd), 1, 0, 0, alice, 999);
    }

    // ------------------------------------------------------------------
    // Quote math and library errors
    // ------------------------------------------------------------------
    function test_QuoteFunctions() public view {
        assertEq(router.quote(1e18, 100e18, 300_000e18), 3_000e18);
        assertEq(
            router.getAmountOut(1e18, 100e18, 300_000e18),
            (uint256(1e18) * 9_970 * 300_000e18) / (100e18 * 10_000 + 1e18 * 9_970)
        );
        uint256 amountIn = router.getAmountIn(3_000e18, 100e18, 300_000e18);
        assertGe(router.getAmountOut(amountIn, 100e18, 300_000e18), 3_000e18);
    }

    function test_RevertWhen_QuoteInputsInvalid() public {
        vm.expectRevert(DexLibrary.InsufficientAmount.selector);
        router.quote(0, 1, 1);
        vm.expectRevert(DexLibrary.InsufficientLiquidity.selector);
        router.quote(1, 0, 1);
        vm.expectRevert(DexLibrary.InsufficientInputAmount.selector);
        router.getAmountOut(0, 1, 1);
        vm.expectRevert(DexLibrary.InsufficientLiquidity.selector);
        router.getAmountOut(1, 1, 0);
        vm.expectRevert(DexLibrary.InsufficientOutputAmount.selector);
        router.getAmountIn(0, 1, 1);
        vm.expectRevert(DexLibrary.InsufficientLiquidity.selector);
        router.getAmountIn(10, 100, 10); // can't take the whole reserve
        vm.expectRevert(DexLibrary.InsufficientLiquidity.selector);
        router.getAmountIn(1, 0, 10);
    }

    function test_RevertWhen_PathInvalid() public {
        address[] memory single = new address[](1);
        single[0] = address(eth);
        vm.expectRevert(DexLibrary.InvalidPath.selector);
        router.getAmountsOut(1, single);
        vm.expectRevert(DexLibrary.InvalidPath.selector);
        router.getAmountsIn(1, single);

        vm.expectRevert(abi.encodeWithSelector(DexLibrary.PairNotFound.selector, address(eth), address(btc)));
        router.getAmountsOut(1, _path(address(eth), address(btc)));

        vm.expectRevert(DexLibrary.IdenticalTokens.selector);
        router.getReserves(address(eth), address(eth));
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------
    /// The exact-in quote is never more than the pool can pay, and the exact-out quote
    /// always buys at least what was asked.
    function testFuzz_QuotesAreConsistent(uint256 amount, uint256 reserveIn, uint256 reserveOut) public view {
        reserveIn = bound(reserveIn, 1e6, 1e30);
        reserveOut = bound(reserveOut, 1e6, 1e30);
        amount = bound(amount, 1, (reserveOut * 99) / 100); // up to 99% of the pool

        uint256 amountIn = router.getAmountIn(amount, reserveIn, reserveOut);
        assertGe(router.getAmountOut(amountIn, reserveIn, reserveOut), amount);

        uint256 out = router.getAmountOut(amount, reserveIn, reserveOut);
        assertLt(out, reserveOut);
    }

    /// Swapping there and back always loses value (two fees), so round trips can't drain a pool.
    function testFuzz_RoundTripNeverProfits(uint256 amountIn) public {
        _addLiquidity(eth, usd, 100e18, 300_000e18);
        amountIn = bound(amountIn, 1e9, 50e18);
        uint256 usdOut = _swapExactIn(alice, amountIn, _path(address(eth), address(usd)));
        vm.assume(usdOut > 0);
        uint256 ethBack = _swapExactIn(bob, usdOut, _path(address(usd), address(eth)));
        assertLt(ethBack, amountIn);
    }

    /// Adding then immediately removing liquidity never returns more than was put in.
    function testFuzz_AddRemoveNeverProfits(uint256 a, uint256 b) public {
        _addLiquidity(eth, usd, 100e18, 300_000e18);
        a = bound(a, 1e12, 1_000e18);
        b = bound(b, 1e12, 3_000_000e18);

        eth.mint(alice, a);
        usd.mint(alice, b);
        vm.startPrank(alice);
        eth.approve(address(router), a);
        usd.approve(address(router), b);
        (uint256 usedA, uint256 usedB, uint256 liquidity) =
            router.addLiquidity(address(eth), address(usd), a, b, 0, 0, alice, DEADLINE);
        Pair pair = _pair(eth, usd);
        pair.approve(address(router), liquidity);
        (uint256 backA, uint256 backB) =
            router.removeLiquidity(address(eth), address(usd), liquidity, 0, 0, alice, DEADLINE);
        vm.stopPrank();

        assertLe(backA, usedA);
        assertLe(backB, usedB);
    }
}
