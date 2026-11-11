// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Router} from "../src/periphery/Router.sol";
import {DexFixture} from "./utils/DexFixture.sol";

/// @notice A sandwich attack: an attacker sees a victim's swap in the mempool, trades in front
///         of it to move the price, lets the victim trade at the worse price, then trades back.
contract SandwichAttackTest is DexFixture {
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

    function setUp() public {
        _deployDex();
        _addLiquidity(eth, usd, 100e18, 300_000e18);
    }

    function _frontRun() internal returns (uint256 usdFromFrontRun) {
        usdFromFrontRun = _swapExactIn(attacker, 20e18, _path(address(eth), address(usd)));
    }

    function test_SlippageLimitBlocksSandwich() public {
        address[] memory path = _path(address(eth), address(usd));
        uint256 quoted = router.getAmountsOut(10e18, path)[1];
        uint256 minOut = (quoted * 995) / 1_000; // 0.5% slippage tolerance, as the frontend sets

        _frontRun();

        eth.mint(victim, 10e18);
        vm.startPrank(victim);
        eth.approve(address(router), 10e18);
        vm.expectRevert(Router.InsufficientOutputAmount.selector);
        router.swapExactTokensForTokens(10e18, minOut, path, victim, DEADLINE);
        vm.stopPrank();
        assertEq(eth.balanceOf(victim), 10e18, "victim keeps their ETH");
    }

    function test_WithoutSlippageLimitVictimIsSandwiched() public {
        address[] memory path = _path(address(eth), address(usd));
        uint256 quoted = router.getAmountsOut(10e18, path)[1];

        uint256 attackerUsd = _frontRun();
        uint256 victimGot = _swapExactIn(victim, 10e18, path); // minOut = 0: no protection
        uint256 attackerEthBack = _swapExactIn(attacker, attackerUsd, _path(address(usd), address(eth)));

        assertLt(victimGot, (quoted * 75) / 100, "victim loses over 25% to the sandwich");
        assertGt(attackerEthBack, 23e18, "attacker turns 20 ETH into 23+");
    }
}
