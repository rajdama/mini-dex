// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StakingRewards} from "../../src/farm/StakingRewards.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Drives StakingRewards with random but valid actions for invariant testing.
contract StakingHandler is Test {
    StakingRewards public staking;
    MockERC20 public stakeToken;
    MockERC20 public rewardToken;
    address public owner;

    address[] public actors;

    // Ghost variables: what the outside world has put in and taken out.
    uint256 public ghostFunded;
    uint256 public ghostClaimed;
    uint256 public ghostRecovered;

    mapping(bytes32 => uint256) public calls;

    constructor(StakingRewards _staking, MockERC20 _stakeToken, MockERC20 _rewardToken, address _owner) {
        staking = _staking;
        stakeToken = _stakeToken;
        rewardToken = _rewardToken;
        owner = _owner;
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function stake(uint256 actorSeed, uint256 amount, uint8 lockId) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, 1e27);
        lockId = uint8(bound(lockId, 0, 3));

        stakeToken.mint(actor, amount);
        vm.startPrank(actor);
        stakeToken.approve(address(staking), amount);
        staking.stake(amount, lockId);
        vm.stopPrank();
        calls["stake"]++;
    }

    function withdraw(uint256 actorSeed, uint256 positionSeed) external {
        address actor = _actor(actorSeed);
        uint256 count = staking.positionCount(actor);
        if (count == 0) return;
        uint256 id = positionSeed % count;
        StakingRewards.Position memory p = staking.getPosition(actor, id);
        if (p.amount == 0 || block.timestamp < p.unlockTime) return;

        vm.prank(actor);
        staking.withdraw(id);
        calls["withdraw"]++;
    }

    function claim(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 before = rewardToken.balanceOf(actor);
        vm.prank(actor);
        staking.getReward();
        ghostClaimed += rewardToken.balanceOf(actor) - before;
        calls["claim"]++;
    }

    function exit(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 before = rewardToken.balanceOf(actor);
        vm.prank(actor);
        staking.exit();
        ghostClaimed += rewardToken.balanceOf(actor) - before;
        calls["exit"]++;
    }

    function kick(uint256 actorSeed, uint256 positionSeed) external {
        address actor = _actor(actorSeed);
        uint256 count = staking.positionCount(actor);
        if (count == 0) return;
        uint256 id = positionSeed % count;
        StakingRewards.Position memory p = staking.getPosition(actor, id);
        if (p.amount == 0 || block.timestamp < p.unlockTime || p.multiplierBps == staking.BASE_MULTIPLIER()) {
            return;
        }
        staking.kick(actor, id);
        calls["kick"]++;
    }

    function notify(uint256 amount) external {
        amount = bound(amount, 1e18, 1e24);
        rewardToken.mint(owner, amount);
        vm.startPrank(owner);
        rewardToken.approve(address(staking), amount);
        staking.notifyRewardAmount(amount);
        vm.stopPrank();
        ghostFunded += amount;
        calls["notify"]++;
    }

    function recover() external {
        if (staking.undistributedRewards() == 0) return;
        uint256 before = rewardToken.balanceOf(owner);
        vm.prank(owner);
        staking.recoverUndistributed(owner);
        ghostRecovered += rewardToken.balanceOf(owner) - before;
        calls["recover"]++;
    }

    function warp(uint256 secondsForward) external {
        secondsForward = bound(secondsForward, 1, 60 days);
        vm.warp(block.timestamp + secondsForward);
        calls["warp"]++;
    }
}
