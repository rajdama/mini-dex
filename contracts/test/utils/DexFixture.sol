// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Factory} from "../../src/core/Factory.sol";
import {Pair} from "../../src/core/Pair.sol";
import {Router} from "../../src/periphery/Router.sol";
import {FlashArbitrage} from "../../src/periphery/FlashArbitrage.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Deploys a fresh DEX with three mintable tokens for tests.
abstract contract DexFixture is Test {
    Factory internal factory;
    Router internal router;
    FlashArbitrage internal arbitrage;
    MockERC20 internal eth;
    MockERC20 internal btc;
    MockERC20 internal usd;

    address internal lp = makeAddr("lp");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant DEADLINE = type(uint256).max;

    function _deployDex() internal {
        factory = new Factory();
        router = new Router(address(factory));
        arbitrage = new FlashArbitrage(address(factory));
        eth = new MockERC20("Ether", "ETH");
        btc = new MockERC20("Bitcoin", "BTC");
        usd = new MockERC20("Dollar", "USD");
    }

    /// @dev Adds liquidity through the router as `lp`.
    function _addLiquidity(MockERC20 a, MockERC20 b, uint256 amountA, uint256 amountB)
        internal
        returns (uint256 liquidity)
    {
        a.mint(lp, amountA);
        b.mint(lp, amountB);
        vm.startPrank(lp);
        a.approve(address(router), amountA);
        b.approve(address(router), amountB);
        (,, liquidity) = router.addLiquidity(address(a), address(b), amountA, amountB, 0, 0, lp, DEADLINE);
        vm.stopPrank();
    }

    /// @dev Three pools at consistent prices: 1 ETH = 3,000 USD, 1 BTC = 60,000 USD = 20 ETH.
    function _seedThreePools() internal {
        _addLiquidity(eth, usd, 100e18, 300_000e18);
        _addLiquidity(btc, usd, 5e18, 300_000e18);
        _addLiquidity(eth, btc, 100e18, 5e18);
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        (p[0], p[1]) = (a, b);
    }

    function _path(address a, address b, address c) internal pure returns (address[] memory p) {
        p = new address[](3);
        (p[0], p[1], p[2]) = (a, b, c);
    }

    function _path(address a, address b, address c, address d) internal pure returns (address[] memory p) {
        p = new address[](4);
        (p[0], p[1], p[2], p[3]) = (a, b, c, d);
    }

    function _swapExactIn(address user, uint256 amountIn, address[] memory path) internal returns (uint256 out) {
        MockERC20(path[0]).mint(user, amountIn);
        vm.startPrank(user);
        MockERC20(path[0]).approve(address(router), amountIn);
        uint256[] memory amounts = router.swapExactTokensForTokens(amountIn, 0, path, user, DEADLINE);
        vm.stopPrank();
        out = amounts[amounts.length - 1];
    }

    function _pair(MockERC20 a, MockERC20 b) internal view returns (Pair) {
        return Pair(factory.getPair(address(a), address(b)));
    }
}
