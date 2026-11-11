// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Factory} from "../../src/core/Factory.sol";
import {Pair} from "../../src/core/Pair.sol";
import {Router} from "../../src/periphery/Router.sol";
import {FlashArbitrage} from "../../src/periphery/FlashArbitrage.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Drives the DEX with random but valid swaps, liquidity changes, donations and arbitrage.
contract DexHandler is Test {
    Factory public factory;
    Router public router;
    FlashArbitrage public arbitrage;
    MockERC20[3] public tokens;
    Pair[] public pairs;
    address[] public actors;

    /// Value per LP share (k / supply^2, scaled) recorded after the last action, per pair.
    mapping(address => uint256) public lastShareValue;
    /// Set if any action ever lowered a pair's value per LP share.
    bool public shareValueDecreased;

    mapping(bytes32 => uint256) public calls;

    constructor(Factory f, Router r, FlashArbitrage a, MockERC20[3] memory t) {
        (factory, router, arbitrage, tokens) = (f, r, a, t);
        for (uint256 i = 0; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                pairs.push(Pair(factory.getPair(address(t[i]), address(t[j]))));
            }
        }
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        _record();
    }

    function pairCount() external view returns (uint256) {
        return pairs.length;
    }

    /// k / supply^2: never decreases if swaps only add fees and mints/burns round in the pool's favor.
    function shareValue(Pair pair) public view returns (uint256) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 supply = pair.totalSupply();
        return Math.mulDiv(uint256(r0) * r1, 1e18, supply * supply);
    }

    function _record() internal {
        for (uint256 i = 0; i < pairs.length; ++i) {
            uint256 v = shareValue(pairs[i]);
            if (v < lastShareValue[address(pairs[i])]) shareValueDecreased = true;
            lastShareValue[address(pairs[i])] = v;
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _token(uint256 seed) internal view returns (MockERC20) {
        return tokens[seed % 3];
    }

    // ------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------

    function swap(uint256 actorSeed, uint256 fromSeed, uint256 toSeed, bool viaThird, uint256 amountSeed) external {
        MockERC20 from = _token(fromSeed);
        MockERC20 to = _token(toSeed);
        if (from == to) return;
        address[] memory path;
        if (viaThird) {
            MockERC20 mid = _token(3 - (fromSeed % 3) - (toSeed % 3));
            path = new address[](3);
            (path[0], path[1], path[2]) = (address(from), address(mid), address(to));
        } else {
            path = new address[](2);
            (path[0], path[1]) = (address(from), address(to));
        }

        (uint256 reserveIn,) = router.getReserves(path[0], path[1]);
        uint256 amountIn = bound(amountSeed, reserveIn / 1e6 + 1, reserveIn / 10 + 1);
        uint256[] memory amounts = router.getAmountsOut(amountIn, path);
        for (uint256 i = 1; i < amounts.length; ++i) {
            if (amounts[i] == 0) return;
        }

        address actor = _actor(actorSeed);
        from.mint(actor, amountIn);
        vm.startPrank(actor);
        from.approve(address(router), amountIn);
        router.swapExactTokensForTokens(amountIn, amounts[amounts.length - 1], path, actor, type(uint256).max);
        vm.stopPrank();
        calls["swap"]++;
        _record();
    }

    function addLiquidity(uint256 actorSeed, uint256 pairSeed, uint256 amountSeed) external {
        Pair pair = pairs[pairSeed % pairs.length];
        (uint112 r0,,) = pair.getReserves();
        uint256 amount0 = bound(amountSeed, uint256(r0) / 1e6 + 1, uint256(r0) / 10 + 1);
        (uint256 rA, uint256 rB) = router.getReserves(pair.token0(), pair.token1());
        uint256 amount1 = router.quote(amount0, rA, rB) + 1;

        address actor = _actor(actorSeed);
        MockERC20(pair.token0()).mint(actor, amount0);
        MockERC20(pair.token1()).mint(actor, amount1);
        vm.startPrank(actor);
        MockERC20(pair.token0()).approve(address(router), amount0);
        MockERC20(pair.token1()).approve(address(router), amount1);
        router.addLiquidity(pair.token0(), pair.token1(), amount0, amount1, 0, 0, actor, type(uint256).max);
        vm.stopPrank();
        calls["add"]++;
        _record();
    }

    function removeLiquidity(uint256 actorSeed, uint256 pairSeed, uint256 shareSeed) external {
        Pair pair = pairs[pairSeed % pairs.length];
        address actor = _actor(actorSeed);
        uint256 balance = pair.balanceOf(actor);
        if (balance == 0) return;
        uint256 liquidity = bound(shareSeed, 1, balance);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 supply = pair.totalSupply();
        if ((liquidity * r0) / supply == 0 || (liquidity * r1) / supply == 0) return;

        vm.startPrank(actor);
        pair.approve(address(router), liquidity);
        router.removeLiquidity(pair.token0(), pair.token1(), liquidity, 0, 0, actor, type(uint256).max);
        vm.stopPrank();
        calls["remove"]++;
        _record();
    }

    /// Someone sends tokens straight to a pair and syncs: a gift to LPs.
    function donate(uint256 pairSeed, uint256 amountSeed) external {
        Pair pair = pairs[pairSeed % pairs.length];
        (uint112 r0,,) = pair.getReserves();
        MockERC20(pair.token0()).mint(address(pair), bound(amountSeed, 1, uint256(r0) / 10 + 1));
        pair.sync();
        calls["donate"]++;
        _record();
    }

    function arbitrageCycle(uint256 actorSeed, uint256 startSeed, bool reverse, uint256 amountSeed) external {
        uint256 s = startSeed % 3;
        (uint256 a, uint256 b) = reverse ? ((s + 2) % 3, (s + 1) % 3) : ((s + 1) % 3, (s + 2) % 3);
        address[] memory path = new address[](4);
        (path[0], path[1], path[2], path[3]) =
        (address(tokens[s]), address(tokens[a]), address(tokens[b]), address(tokens[s]));

        (uint256 reserveIn,) = router.getReserves(path[0], path[1]);
        uint256 amountIn = bound(amountSeed, reserveIn / 1e6 + 1, reserveIn / 10 + 1);
        uint256[] memory amounts = arbitrage.quote(path, amountIn);
        for (uint256 i = 1; i < amounts.length; ++i) {
            if (amounts[i] == 0) return;
        }
        if (amounts[3] <= amountIn) return;

        vm.prank(_actor(actorSeed));
        arbitrage.execute(path, amountIn, 0, type(uint256).max);
        calls["arbitrage"]++;
        _record();
    }

    function warp(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 1, 1 days));
        calls["warp"]++;
    }
}
