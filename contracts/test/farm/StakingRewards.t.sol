// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {StakingRewards} from "../../src/farm/StakingRewards.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FeeOnTransferToken} from "../mocks/FeeOnTransferToken.sol";

contract StakingRewardsTest is Test {
    StakingRewards internal staking;
    MockERC20 internal stakeToken;
    MockERC20 internal rewardToken;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant DURATION = 7 days;
    uint256 internal constant REWARD = 1_000e18;
    uint256 internal constant TOLERANCE = 1e15; // 0.1%

    function setUp() public {
        stakeToken = new MockERC20("Stake Token", "STK");
        rewardToken = new MockERC20("Reward Token", "RWD");
        staking = _deploy(address(stakeToken), address(rewardToken), DURATION);
        _fund(staking, REWARD);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    function _deploy(address stk, address rwd, uint256 duration) internal returns (StakingRewards s) {
        vm.prank(owner);
        s = new StakingRewards(stk, rwd, duration);
    }

    function _fund(StakingRewards s, uint256 amount) internal {
        MockERC20 rwd = MockERC20(address(s.rewardsToken()));
        rwd.mint(owner, amount);
        vm.startPrank(owner);
        rwd.approve(address(s), amount);
        s.notifyRewardAmount(amount);
        vm.stopPrank();
    }

    function _stake(StakingRewards s, address user, uint256 amount, uint8 lockId) internal returns (uint256 id) {
        MockERC20 stk = MockERC20(address(s.stakingToken()));
        stk.mint(user, amount);
        vm.startPrank(user);
        stk.approve(address(s), amount);
        id = s.stake(amount, lockId);
        vm.stopPrank();
    }

    function _stake(address user, uint256 amount, uint8 lockId) internal returns (uint256) {
        return _stake(staking, user, amount, lockId);
    }

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function test_RevertWhen_ConstructorZeroStakingToken() public {
        vm.expectRevert(StakingRewards.ZeroAddress.selector);
        new StakingRewards(address(0), address(rewardToken), DURATION);
    }

    function test_RevertWhen_ConstructorZeroRewardsToken() public {
        vm.expectRevert(StakingRewards.ZeroAddress.selector);
        new StakingRewards(address(stakeToken), address(0), DURATION);
    }

    function test_RevertWhen_ConstructorZeroDuration() public {
        vm.expectRevert(StakingRewards.ZeroDuration.selector);
        new StakingRewards(address(stakeToken), address(rewardToken), 0);
    }

    // ------------------------------------------------------------------
    // Lock options
    // ------------------------------------------------------------------
    function test_LockOptions() public view {
        (uint64 d0, uint16 m0) = staking.lockOption(0);
        (uint64 d1, uint16 m1) = staking.lockOption(1);
        (uint64 d2, uint16 m2) = staking.lockOption(2);
        (uint64 d3, uint16 m3) = staking.lockOption(3);
        assertEq(d0, 0);
        assertEq(m0, 10_000);
        assertEq(d1, 30 days);
        assertEq(m1, 15_000);
        assertEq(d2, 90 days);
        assertEq(m2, 20_000);
        assertEq(d3, 365 days);
        assertEq(m3, 30_000);
    }

    function test_RevertWhen_InvalidLockOption() public {
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InvalidLockOption.selector, 4));
        staking.lockOption(4);
    }

    // ------------------------------------------------------------------
    // Staking
    // ------------------------------------------------------------------
    function test_StakeCreatesPosition() public {
        uint256 id = _stake(alice, 100e18, 2);

        assertEq(id, 0);
        assertEq(staking.positionCount(alice), 1);
        StakingRewards.Position memory p = staking.getPosition(alice, 0);
        assertEq(p.amount, 100e18);
        assertEq(p.multiplierBps, 20_000);
        assertEq(p.unlockTime, block.timestamp + 90 days);

        assertEq(staking.stakedOf(alice), 100e18);
        assertEq(staking.effectiveBalanceOf(alice), 200e18);
        assertEq(staking.totalStaked(), 100e18);
        assertEq(staking.totalEffective(), 200e18);
        assertEq(stakeToken.balanceOf(address(staking)), 100e18);
    }

    function test_MultiplePositionsGetSequentialIds() public {
        assertEq(_stake(alice, 1e18, 0), 0);
        assertEq(_stake(alice, 1e18, 1), 1);
        assertEq(_stake(alice, 1e18, 3), 2);

        StakingRewards.Position[] memory ps = staking.getPositions(alice);
        assertEq(ps.length, 3);
        assertEq(ps[2].multiplierBps, 30_000);
        assertEq(staking.effectiveBalanceOf(alice), 1e18 + 1.5e18 + 3e18);
    }

    function test_RevertWhen_StakeZero() public {
        vm.prank(alice);
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        staking.stake(0, 0);
    }

    function test_RevertWhen_StakeInvalidLock() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InvalidLockOption.selector, 9));
        staking.stake(1e18, 9);
    }

    // ------------------------------------------------------------------
    // Reward math
    // ------------------------------------------------------------------
    function test_EarnsHalfRewardAtHalfTime() public {
        _stake(alice, 100e18, 0);
        vm.warp(block.timestamp + DURATION / 2);
        assertApproxEqRel(staking.earned(alice), REWARD / 2, TOLERANCE);
    }

    function test_TwoStakersSplitProportionally() public {
        _stake(alice, 100e18, 0);
        _stake(bob, 300e18, 0);
        vm.warp(block.timestamp + DURATION);

        assertApproxEqRel(staking.earned(alice), REWARD / 4, TOLERANCE);
        assertApproxEqRel(staking.earned(bob), (REWARD * 3) / 4, TOLERANCE);
    }

    function test_LateStakerOnlyEarnsFromJoinTime() public {
        _stake(alice, 100e18, 0);
        vm.warp(block.timestamp + DURATION / 2);
        _stake(bob, 100e18, 0);
        vm.warp(block.timestamp + DURATION / 2);

        assertApproxEqRel(staking.earned(alice), (REWARD * 3) / 4, TOLERANCE);
        assertApproxEqRel(staking.earned(bob), REWARD / 4, TOLERANCE);
    }

    function test_LockBoostIncreasesShare() public {
        _stake(alice, 100e18, 0); // effective 100
        _stake(bob, 100e18, 3); // effective 300 (3x)
        vm.warp(block.timestamp + DURATION);

        assertApproxEqRel(staking.earned(alice), REWARD / 4, TOLERANCE);
        assertApproxEqRel(staking.earned(bob), (REWARD * 3) / 4, TOLERANCE);
    }

    function test_NoRewardsAfterPeriodEnds() public {
        _stake(alice, 100e18, 0);
        vm.warp(block.timestamp + DURATION);
        uint256 atEnd = staking.earned(alice);

        vm.warp(block.timestamp + 30 days);
        assertEq(staking.earned(alice), atEnd);
        assertEq(staking.lastTimeRewardApplicable(), staking.finishAt());
    }

    // ------------------------------------------------------------------
    // Withdraw, claim, exit
    // ------------------------------------------------------------------
    function test_WithdrawUnlockedPosition() public {
        uint256 id = _stake(alice, 100e18, 0);

        vm.prank(alice);
        staking.withdraw(id);

        assertEq(stakeToken.balanceOf(alice), 100e18);
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.totalEffective(), 0);
        assertEq(staking.getPosition(alice, id).amount, 0);
    }

    function test_WithdrawLockedPositionAfterUnlock() public {
        uint256 id = _stake(alice, 100e18, 1);
        vm.warp(block.timestamp + 30 days);

        vm.prank(alice);
        staking.withdraw(id);
        assertEq(stakeToken.balanceOf(alice), 100e18);
    }

    function test_RevertWhen_WithdrawStillLocked() public {
        uint256 id = _stake(alice, 100e18, 1);
        uint256 unlockTime = staking.getPosition(alice, id).unlockTime;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.StillLocked.selector, unlockTime));
        staking.withdraw(id);
    }

    function test_RevertWhen_WithdrawNonexistentPosition() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InvalidPosition.selector, 0));
        staking.withdraw(0);
    }

    function test_RevertWhen_WithdrawTwice() public {
        uint256 id = _stake(alice, 100e18, 0);
        vm.startPrank(alice);
        staking.withdraw(id);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InvalidPosition.selector, id));
        staking.withdraw(id);
        vm.stopPrank();
    }

    function test_RevertWhen_GetPositionOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InvalidPosition.selector, 5));
        staking.getPosition(alice, 5);
    }

    function test_GetRewardTransfersTokens() public {
        _stake(alice, 100e18, 0);
        vm.warp(block.timestamp + DURATION);
        uint256 expected = staking.earned(alice);

        vm.prank(alice);
        staking.getReward();

        assertEq(rewardToken.balanceOf(alice), expected);
        assertEq(staking.earned(alice), 0);
    }

    function test_GetRewardWithNothingEarnedIsNoop() public {
        vm.prank(alice);
        staking.getReward();
        assertEq(rewardToken.balanceOf(alice), 0);
    }

    function test_ExitSkipsLockedAndWithdrawnPositions() public {
        uint256 open = _stake(alice, 100e18, 0);
        uint256 locked = _stake(alice, 50e18, 3);
        uint256 withdrawn = _stake(alice, 10e18, 0);
        vm.prank(alice);
        staking.withdraw(withdrawn);

        vm.warp(block.timestamp + DURATION);
        uint256 expectedReward = staking.earned(alice);

        vm.prank(alice);
        staking.exit();

        assertEq(stakeToken.balanceOf(alice), 110e18); // open + withdrawn, not locked
        assertEq(rewardToken.balanceOf(alice), expectedReward);
        assertEq(staking.getPosition(alice, open).amount, 0);
        assertEq(staking.getPosition(alice, locked).amount, 50e18);
        assertEq(staking.stakedOf(alice), 50e18);
    }

    function test_ExitWithOnlyLockedPositionsJustClaims() public {
        _stake(alice, 100e18, 2);
        vm.warp(block.timestamp + DURATION);
        uint256 expectedReward = staking.earned(alice);

        vm.prank(alice);
        staking.exit();

        assertEq(stakeToken.balanceOf(alice), 0);
        assertEq(rewardToken.balanceOf(alice), expectedReward);
        assertEq(staking.stakedOf(alice), 100e18);
    }

    // ------------------------------------------------------------------
    // Kick
    // ------------------------------------------------------------------
    function test_KickResetsExpiredBoost() public {
        StakingRewards s = _deploy(address(stakeToken), address(rewardToken), 60 days);
        _fund(s, REWARD);
        _stake(s, alice, 100e18, 0); // effective 100
        uint256 id = _stake(s, bob, 100e18, 1); // effective 150 for 30 days

        vm.warp(block.timestamp + 30 days);
        vm.prank(alice); // anyone can kick
        s.kick(bob, id);

        assertEq(s.effectiveBalanceOf(bob), 100e18);
        assertEq(s.getPosition(bob, id).multiplierBps, 10_000);

        vm.warp(block.timestamp + 30 days);
        // Days 0-30: Bob 60%. Days 30-60: 50/50. Bob = 0.3 + 0.25 = 55%.
        assertApproxEqRel(s.earned(bob), (REWARD * 55) / 100, TOLERANCE);
        assertApproxEqRel(s.earned(alice), (REWARD * 45) / 100, TOLERANCE);
    }

    function test_RevertWhen_KickStillLocked() public {
        uint256 id = _stake(bob, 100e18, 1);
        vm.expectRevert(StakingRewards.NotKickable.selector);
        staking.kick(bob, id);
    }

    function test_RevertWhen_KickUnboosted() public {
        uint256 id = _stake(bob, 100e18, 0);
        vm.expectRevert(StakingRewards.NotKickable.selector);
        staking.kick(bob, id);
    }

    function test_RevertWhen_KickTwice() public {
        uint256 id = _stake(bob, 100e18, 1);
        vm.warp(block.timestamp + 30 days);
        staking.kick(bob, id);
        vm.expectRevert(StakingRewards.NotKickable.selector);
        staking.kick(bob, id);
    }

    function test_WithdrawAfterKickReturnsFullAmount() public {
        uint256 id = _stake(bob, 100e18, 2);
        vm.warp(block.timestamp + 90 days);
        staking.kick(bob, id);

        vm.prank(bob);
        staking.withdraw(id);
        assertEq(stakeToken.balanceOf(bob), 100e18);
        assertEq(staking.totalEffective(), 0);
    }

    // ------------------------------------------------------------------
    // Undistributed rewards (the stuck-rewards fix)
    // ------------------------------------------------------------------
    function test_UndistributedRewardsAreTrackedAndRecoverable() public {
        vm.warp(block.timestamp + 1 days); // nobody staked for the first day
        _stake(alice, 100e18, 0);
        vm.warp(block.timestamp + DURATION);

        assertApproxEqRel(staking.earned(alice), (REWARD * 6) / 7, TOLERANCE);
        assertApproxEqRel(staking.undistributedRewards(), REWARD / 7, TOLERANCE);

        uint256 expected = staking.undistributedRewards();
        vm.prank(owner);
        staking.recoverUndistributed(owner);
        assertEq(rewardToken.balanceOf(owner), expected);
        assertEq(staking.undistributedRewards(), 0);

        // Everyone owed can still be paid in full.
        uint256 owed = staking.earned(alice);
        vm.prank(alice);
        staking.getReward();
        assertEq(rewardToken.balanceOf(alice), owed);
    }

    function test_UndistributedCountsGapsMidPeriod() public {
        uint256 id = _stake(alice, 100e18, 0);
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        staking.withdraw(id); // pool empty for the next 2 days
        vm.warp(block.timestamp + 2 days);

        // Settle the global accounting by recovering.
        vm.prank(owner);
        staking.recoverUndistributed(owner);
        assertApproxEqRel(rewardToken.balanceOf(owner), (REWARD * 2) / 7, TOLERANCE);
    }

    function test_RevertWhen_RecoverNothing() public {
        _stake(alice, 100e18, 0); // staked from the first second
        vm.prank(owner);
        vm.expectRevert(StakingRewards.NothingToRecover.selector);
        staking.recoverUndistributed(owner);
    }

    function test_RevertWhen_RecoverToZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(StakingRewards.ZeroAddress.selector);
        staking.recoverUndistributed(address(0));
    }

    function test_RevertWhen_NonOwnerRecovers() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.recoverUndistributed(alice);
    }

    function test_NoUndistributedBeforeFirstPeriod() public {
        StakingRewards s = _deploy(address(stakeToken), address(rewardToken), DURATION);
        vm.warp(block.timestamp + 5 days);
        _stake(s, alice, 1e18, 0); // settles with finishAt == 0
        assertEq(s.undistributedRewards(), 0);
        assertEq(s.rewardPerToken(), 0);
    }

    // ------------------------------------------------------------------
    // Owner: notify and duration
    // ------------------------------------------------------------------
    function test_NotifyDuringPeriodRollsOverLeftover() public {
        _stake(alice, 100e18, 0);
        vm.warp(block.timestamp + DURATION / 2);
        uint256 rateBefore = staking.rewardRate();

        _fund(staking, REWARD); // half of the first reward is left, plus a new one

        assertApproxEqRel(staking.rewardRate(), (REWARD + REWARD / 2) / DURATION, TOLERANCE);
        assertGt(staking.rewardRate(), rateBefore);
        assertEq(staking.finishAt(), block.timestamp + DURATION);

        vm.warp(block.timestamp + DURATION);
        assertApproxEqRel(staking.earned(alice), 2 * REWARD, TOLERANCE);
    }

    function test_NewPeriodAfterFinish() public {
        vm.warp(block.timestamp + DURATION + 1);
        _fund(staking, 2 * REWARD);
        assertEq(staking.rewardRate(), (2 * REWARD) / DURATION);
    }

    function test_RevertWhen_NonOwnerNotifies() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.notifyRewardAmount(1e18);
    }

    function test_RevertWhen_RewardRateZero() public {
        StakingRewards s = _deploy(address(stakeToken), address(rewardToken), DURATION);
        rewardToken.mint(owner, DURATION - 1);
        vm.startPrank(owner);
        rewardToken.approve(address(s), DURATION - 1);
        vm.expectRevert(StakingRewards.RewardRateZero.selector);
        s.notifyRewardAmount(DURATION - 1);
        vm.stopPrank();
    }

    function test_RevertWhen_FeeOnTransferRewardTooHigh() public {
        // A fee-on-transfer reward token delivers less than `amount`, so the promised rate can't be paid.
        FeeOnTransferToken fee = new FeeOnTransferToken();
        StakingRewards s = _deploy(address(stakeToken), address(fee), DURATION);
        fee.mint(owner, REWARD);
        vm.startPrank(owner);
        fee.approve(address(s), REWARD);
        vm.expectRevert(StakingRewards.RewardTooHigh.selector);
        s.notifyRewardAmount(REWARD);
        vm.stopPrank();
    }

    function test_SameTokenExcludesStakedFunds() public {
        StakingRewards s = _deploy(address(stakeToken), address(stakeToken), DURATION);
        _stake(s, alice, 500e18, 0);
        _fund(s, REWARD); // must not count Alice's 500 as rewards
        vm.warp(block.timestamp + DURATION);

        vm.prank(alice);
        s.exit();
        assertApproxEqRel(stakeToken.balanceOf(alice), 500e18 + REWARD, TOLERANCE);
    }

    function test_SetRewardsDurationAfterFinish() public {
        vm.warp(block.timestamp + DURATION);
        vm.prank(owner);
        staking.setRewardsDuration(14 days);
        assertEq(staking.duration(), 14 days);
    }

    function test_RevertWhen_ChangingDurationMidPeriod() public {
        vm.prank(owner);
        vm.expectRevert(StakingRewards.RewardPeriodActive.selector);
        staking.setRewardsDuration(14 days);
    }

    function test_RevertWhen_SettingZeroDuration() public {
        vm.warp(block.timestamp + DURATION);
        vm.prank(owner);
        vm.expectRevert(StakingRewards.ZeroDuration.selector);
        staking.setRewardsDuration(0);
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------
    function testFuzz_NeverPaysMoreThanFunded(
        uint256 aliceAmt,
        uint256 bobAmt,
        uint8 aliceLock,
        uint8 bobLock,
        uint256 bobJoinsAfter
    ) public {
        aliceAmt = bound(aliceAmt, 1, 1e30);
        bobAmt = bound(bobAmt, 1, 1e30);
        aliceLock = uint8(bound(aliceLock, 0, 3));
        bobLock = uint8(bound(bobLock, 0, 3));
        bobJoinsAfter = bound(bobJoinsAfter, 0, DURATION);

        _stake(alice, aliceAmt, aliceLock);
        vm.warp(block.timestamp + bobJoinsAfter);
        _stake(bob, bobAmt, bobLock);
        vm.warp(block.timestamp + DURATION + 1 days);

        uint256 owed = staking.earned(alice) + staking.earned(bob);
        assertLe(owed + staking.undistributedRewards(), REWARD);
        assertLe(owed, rewardToken.balanceOf(address(staking)));
    }

    function testFuzz_KickNeverIncreasesEffective(uint8 lockId, uint256 amount, uint256 waitTime) public {
        lockId = uint8(bound(lockId, 1, 3));
        amount = bound(amount, 1, 1e30);
        (uint64 lockDuration,) = staking.lockOption(lockId);
        waitTime = bound(waitTime, lockDuration, lockDuration + 400 days);

        uint256 id = _stake(bob, amount, lockId);
        uint256 before = staking.effectiveBalanceOf(bob);
        vm.warp(block.timestamp + waitTime);
        staking.kick(bob, id);

        assertLe(staking.effectiveBalanceOf(bob), before);
        assertEq(staking.effectiveBalanceOf(bob), amount);
    }
}
