// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {StakingRewards} from "../../src/farm/StakingRewards.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {StakingHandler as Handler} from "./StakingHandler.sol";

/// @notice Properties that must hold after ANY sequence of stakes, withdrawals, claims, kicks,
///         reward top-ups, recoveries and time jumps.
contract StakingRewardsInvariantTest is StdInvariant, Test {
    StakingRewards internal staking;
    MockERC20 internal stakeToken;
    MockERC20 internal rewardToken;
    Handler internal handler;
    address internal owner = makeAddr("owner");

    function setUp() public {
        stakeToken = new MockERC20("Stake Token", "STK");
        rewardToken = new MockERC20("Reward Token", "RWD");
        vm.prank(owner);
        staking = new StakingRewards(address(stakeToken), address(rewardToken), 7 days);

        handler = new Handler(staking, stakeToken, rewardToken, owner);
        handler.notify(1_000e18);
        targetContract(address(handler));
    }

    /// Every staked token is held by the contract, and the totals match per-user balances.
    function invariant_StakedTokensAreBacked() public view {
        uint256 sumStaked;
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            sumStaked += staking.stakedOf(handler.actors(i));
        }
        assertEq(staking.totalStaked(), sumStaked);
        assertEq(stakeToken.balanceOf(address(staking)), staking.totalStaked());
    }

    /// Effective balance is the sum of users' boosted balances, and a boost never shrinks a stake.
    function invariant_EffectiveBalancesAddUp() public view {
        uint256 sumEffective;
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            sumEffective += staking.effectiveBalanceOf(a);
            assertGe(staking.effectiveBalanceOf(a), staking.stakedOf(a));
        }
        assertEq(staking.totalEffective(), sumEffective);
    }

    /// The contract can always pay everything it owes: unclaimed rewards plus undistributed rewards.
    function invariant_Solvent() public view {
        uint256 owed = staking.undistributedRewards();
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            owed += staking.earned(handler.actors(i));
        }
        assertGe(rewardToken.balanceOf(address(staking)), owed);
    }

    /// Reward tokens are conserved: funded = claimed + recovered + still in the contract.
    function invariant_RewardTokensConserved() public view {
        assertEq(
            handler.ghostFunded(),
            handler.ghostClaimed() + handler.ghostRecovered() + rewardToken.balanceOf(address(staking))
        );
    }
}
