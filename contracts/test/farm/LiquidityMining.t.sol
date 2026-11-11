// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakingRewards} from "../../src/farm/StakingRewards.sol";
import {Pair} from "../../src/core/Pair.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {DexFixture} from "../utils/DexFixture.sol";

/// @notice End to end: provide liquidity, stake the LP tokens in a farm, earn rewards,
///         and still earn swap fees on the underlying liquidity.
contract LiquidityMiningTest is DexFixture {
    StakingRewards internal farm;
    MockERC20 internal mdx;
    Pair internal pair;

    function setUp() public {
        _deployDex();
        _addLiquidity(eth, usd, 100e18, 300_000e18);
        pair = _pair(eth, usd);

        mdx = new MockERC20("Reward", "MDX");
        farm = new StakingRewards(address(pair), address(mdx), 7 days);
        mdx.mint(address(this), 1_000e18);
        mdx.approve(address(farm), 1_000e18);
        farm.notifyRewardAmount(1_000e18);
    }

    function test_StakeLpEarnRewardsAndFees() public {
        uint256 liquidity = pair.balanceOf(lp);
        vm.startPrank(lp);
        pair.approve(address(farm), liquidity);
        farm.stake(liquidity, 2); // 90-day lock, 2x
        vm.stopPrank();

        // Traders pay fees into the pool while the LP tokens sit in the farm.
        for (uint256 i = 0; i < 5; ++i) {
            _swapExactIn(alice, 5e18, _path(address(eth), address(usd)));
            _swapExactIn(alice, 15_000e18, _path(address(usd), address(eth)));
        }
        vm.warp(block.timestamp + 7 days);
        assertApproxEqRel(farm.earned(lp), 1_000e18, 1e15, "sole farmer earns the whole week");

        vm.prank(lp);
        farm.getReward();
        assertApproxEqRel(mdx.balanceOf(lp), 1_000e18, 1e15);

        // After the lock, withdraw LP and remove liquidity: more value than deposited, thanks to fees.
        vm.warp(block.timestamp + 90 days);
        vm.startPrank(lp);
        farm.withdraw(0);
        pair.approve(address(router), liquidity);
        (uint256 ethBack, uint256 usdBack) =
            router.removeLiquidity(address(eth), address(usd), liquidity, 0, 0, lp, DEADLINE);
        vm.stopPrank();

        assertGt(ethBack * usdBack, 100e18 * 300_000e18 * 99_999 / 100_000, "fees grew the position");
    }
}
