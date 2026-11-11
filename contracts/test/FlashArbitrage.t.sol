// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FlashArbitrage} from "../src/periphery/FlashArbitrage.sol";
import {Pair} from "../src/core/Pair.sol";
import {DexFixture} from "./utils/DexFixture.sol";

contract FlashArbitrageTest is DexFixture {
    address internal searcher = makeAddr("searcher");

    function setUp() public {
        _deployDex();
        _seedThreePools();
    }

    /// Someone dumps 20 ETH into the ETH/USD pool, making ETH cheap there (~2,080 USD)
    /// while the ETH/BTC and BTC/USD pools still value it at ~3,000 USD.
    function _dislocate() internal {
        _swapExactIn(bob, 20e18, _path(address(eth), address(usd)));
    }

    function _cycle() internal view returns (address[] memory) {
        return _path(address(usd), address(eth), address(btc), address(usd));
    }

    function _ethPriceInUsdPool() internal view returns (uint256) {
        (uint256 rEth, uint256 rUsd) = router.getReserves(address(eth), address(usd));
        return (rUsd * 1e18) / rEth;
    }

    function test_ArbitrageProfitWithNoCapital() public {
        _dislocate();
        uint256 priceBefore = _ethPriceInUsdPool();
        uint256[] memory quoted = arbitrage.quote(_cycle(), 10_000e18);
        uint256 expectedProfit = quoted[3] - 10_000e18;
        assertApproxEqRel(expectedProfit, 2_566e18, 0.001e18);

        assertEq(usd.balanceOf(searcher), 0); // starts with nothing
        vm.prank(searcher);
        uint256 profit = arbitrage.execute(_cycle(), 10_000e18, 0, DEADLINE);

        assertEq(profit, expectedProfit);
        assertEq(usd.balanceOf(searcher), profit);
        assertEq(usd.balanceOf(address(arbitrage)), 0); // keeps nothing
        assertGt(_ethPriceInUsdPool(), priceBefore, "arbitrage pushes the cheap pool's price back up");
    }

    function test_RevertWhen_NotProfitable() public {
        uint256[] memory quoted = arbitrage.quote(_cycle(), 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(FlashArbitrage.NotProfitable.selector, 1_000e18, quoted[3]));
        arbitrage.execute(_cycle(), 1_000e18, 0, DEADLINE);
    }

    function test_RevertWhen_ProfitBelowMinimum() public {
        _dislocate();
        uint256[] memory quoted = arbitrage.quote(_cycle(), 10_000e18);
        vm.expectRevert(abi.encodeWithSelector(FlashArbitrage.NotProfitable.selector, 10_000e18, quoted[3]));
        arbitrage.execute(_cycle(), 10_000e18, 3_000e18, DEADLINE);
    }

    function test_RevertWhen_PathNotACycle() public {
        vm.expectRevert(FlashArbitrage.InvalidPath.selector);
        arbitrage.execute(_path(address(usd), address(eth), address(btc)), 1e18, 0, DEADLINE);
        vm.expectRevert(FlashArbitrage.InvalidPath.selector);
        arbitrage.quote(_path(address(usd), address(eth)), 1e18);
    }

    function test_RevertWhen_Expired() public {
        vm.warp(100);
        vm.expectRevert(FlashArbitrage.Expired.selector);
        arbitrage.execute(_cycle(), 1e18, 0, 99);
    }

    function test_RevertWhen_CallbackNotFromOwnFlashSwap() public {
        uint256[] memory amounts = arbitrage.quote(_cycle(), 1e18);
        bytes memory data = abi.encode(_cycle(), amounts);

        // Someone calls the callback directly.
        vm.expectRevert(FlashArbitrage.UnauthorizedCallback.selector);
        arbitrage.flashSwapCall(address(this), 0, 0, data);

        // A fake "pair" pretends the arbitrage contract started the swap.
        vm.expectRevert(FlashArbitrage.UnauthorizedCallback.selector);
        arbitrage.flashSwapCall(address(arbitrage), 0, 0, data);

        // A real pair, but a flash swap someone else started.
        Pair firstPair = _pair(usd, eth);
        usd.mint(address(firstPair), 1e18);
        (uint256 out0, uint256 out1) =
            firstPair.token0() == address(eth) ? (uint256(1e15), uint256(0)) : (uint256(0), uint256(1e15));
        vm.expectRevert(FlashArbitrage.UnauthorizedCallback.selector);
        firstPair.swap(out0, out1, address(arbitrage), data);
    }
}
