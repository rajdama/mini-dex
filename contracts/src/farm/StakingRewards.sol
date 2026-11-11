// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Copied unchanged from https://github.com/rajdama/staking-rewards (contracts/src/StakingRewards.sol).
// Here the staking token is a DEX LP token: "liquidity mining".

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title StakingRewards
/// @notice Stake `stakingToken`, optionally lock it for a boost, and earn `rewardsToken`
///         over a fixed reward period.
///
/// HOW THE MATH WORKS
///
/// Rewards stream out at a fixed `rewardRate` (tokens per second) and are shared by all
/// stakers in proportion to their *effective* balance. Instead of looping over users, the
/// contract tracks ONE global number:
///
///     rewardPerToken = rewards earned by one unit of effective balance since the start
///
/// It grows by `rewardRate * secondsPassed / totalEffective` on every interaction. Each user
/// remembers the value it had when their account was last settled, so their new earnings are
///
///     effectiveBalance * (rewardPerToken - userRewardPerTokenPaid)
///
/// LOCK BOOSTS
///
/// Every stake creates a separate *position* with its own lock. Locking longer multiplies the
/// position's effective balance (1x, 1.5x, 2x or 3x). When a lock expires, anyone can `kick`
/// the position back to 1x, so expired locks can't keep a boost they no longer earn.
///
/// UNDISTRIBUTED REWARDS
///
/// If nobody is staked for part of a period, the rewards for that time have no one to go to.
/// They are tracked in `undistributedRewards` and the owner can recover them.
contract StakingRewards is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // ------------------------------------------------------------------
    // Types and constants
    // ------------------------------------------------------------------

    /// @notice One stake. `amount == 0` means the position was withdrawn.
    struct Position {
        uint128 amount;
        uint64 unlockTime;
        uint16 multiplierBps;
    }

    /// @notice 10_000 basis points = 1x.
    uint16 public constant BASE_MULTIPLIER = 10_000;

    /// @notice Lock options are ids 0 to LOCK_OPTION_COUNT - 1. See `lockOption`.
    uint8 public constant LOCK_OPTION_COUNT = 4;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------
    error ZeroAmount();
    error ZeroAddress();
    error ZeroDuration();
    error InvalidLockOption(uint8 lockId);
    error InvalidPosition(uint256 positionId);
    error StillLocked(uint256 unlockTime);
    error NotKickable();
    error RewardPeriodActive();
    error RewardRateZero();
    error RewardTooHigh();
    error NothingToRecover();

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------
    event Staked(
        address indexed user, uint256 indexed positionId, uint256 amount, uint16 multiplierBps, uint64 unlockTime
    );
    event Withdrawn(address indexed user, uint256 indexed positionId, uint256 amount);
    event Kicked(address indexed user, uint256 indexed positionId, address indexed caller);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward, uint256 rewardRate, uint256 finishAt);
    event RewardsDurationUpdated(uint256 newDuration);
    event UndistributedRecovered(address indexed to, uint256 amount);

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardsToken;

    uint256 public duration; // length of a reward period in seconds
    uint256 public finishAt; // timestamp when the current period ends
    uint256 public updatedAt; // last time the global accounting was settled
    uint256 public rewardRate; // reward tokens paid out per second
    uint256 public rewardPerTokenStored; // accumulated reward per unit of effective balance, scaled by 1e18
    uint256 public undistributedRewards; // rewards for time when nobody was staked

    uint256 public totalStaked; // raw tokens staked
    uint256 public totalEffective; // boosted balance that earns rewards

    mapping(address => uint256) public stakedOf;
    mapping(address => uint256) public effectiveBalanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards; // settled but unclaimed

    mapping(address => Position[]) internal _positions;

    constructor(address stakingToken_, address rewardsToken_, uint256 duration_) Ownable(msg.sender) {
        if (stakingToken_ == address(0) || rewardsToken_ == address(0)) revert ZeroAddress();
        if (duration_ == 0) revert ZeroDuration();
        stakingToken = IERC20(stakingToken_);
        rewardsToken = IERC20(rewardsToken_);
        duration = duration_;
    }

    // ------------------------------------------------------------------
    // Accounting
    // ------------------------------------------------------------------

    /// @dev Settles global accounting up to now, then credits `account` (if any).
    ///      Runs before every state change so balances never change mid-interval.
    modifier updateReward(address account) {
        _updateReward(account);
        _;
    }

    function _updateReward(address account) internal {
        uint256 last = lastTimeRewardApplicable();
        if (totalEffective == 0) {
            // Nobody staked: this interval's rewards have no owner. Track them for recovery.
            if (last > updatedAt) {
                undistributedRewards += rewardRate * (last - updatedAt);
            }
        } else {
            rewardPerTokenStored = rewardPerToken();
        }
        updatedAt = last;

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Lock duration and boost for each lock option.
    function lockOption(uint8 lockId) public pure returns (uint64 lockDuration, uint16 multiplierBps) {
        if (lockId == 0) return (0, 10_000); // no lock, 1x
        if (lockId == 1) return (30 days, 15_000); // 1.5x
        if (lockId == 2) return (90 days, 20_000); // 2x
        if (lockId == 3) return (365 days, 30_000); // 3x
        revert InvalidLockOption(lockId);
    }

    /// @notice Rewards stop accruing once the period has finished.
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < finishAt ? block.timestamp : finishAt;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalEffective == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + (rewardRate * (lastTimeRewardApplicable() - updatedAt) * 1e18) / totalEffective;
    }

    function earned(address account) public view returns (uint256) {
        return
            (effectiveBalanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18
                + rewards[account];
    }

    function positionCount(address user) external view returns (uint256) {
        return _positions[user].length;
    }

    function getPosition(address user, uint256 positionId) external view returns (Position memory) {
        if (positionId >= _positions[user].length) revert InvalidPosition(positionId);
        return _positions[user][positionId];
    }

    /// @notice All positions of a user, including withdrawn ones (amount 0), indexed by position id.
    function getPositions(address user) external view returns (Position[] memory) {
        return _positions[user];
    }

    // ------------------------------------------------------------------
    // User actions
    // ------------------------------------------------------------------

    /// @notice Stake `amount` with lock option `lockId`. Returns the new position id.
    function stake(uint256 amount, uint8 lockId)
        external
        nonReentrant
        updateReward(msg.sender)
        returns (uint256 positionId)
    {
        if (amount == 0) revert ZeroAmount();
        (uint64 lockDuration, uint16 multiplierBps) = lockOption(lockId);

        uint64 unlockTime = (block.timestamp + lockDuration).toUint64();
        uint256 effective = _effective(amount, multiplierBps);

        positionId = _positions[msg.sender].length;
        _positions[msg.sender].push(
            Position({amount: amount.toUint128(), unlockTime: unlockTime, multiplierBps: multiplierBps})
        );

        totalStaked += amount;
        totalEffective += effective;
        stakedOf[msg.sender] += amount;
        effectiveBalanceOf[msg.sender] += effective;

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, positionId, amount, multiplierBps, unlockTime);
    }

    /// @notice Withdraw an unlocked position in full.
    function withdraw(uint256 positionId) external nonReentrant updateReward(msg.sender) {
        _withdraw(positionId);
    }

    function getReward() external nonReentrant updateReward(msg.sender) {
        _claim();
    }

    /// @notice Withdraw every unlocked position and claim all rewards.
    /// @dev Loops over the caller's own positions, so its gas grows with how many they opened.
    function exit() external nonReentrant updateReward(msg.sender) {
        Position[] storage positions = _positions[msg.sender];
        uint256 count = positions.length;
        uint256 totalAmount = 0;
        uint256 totalEffectiveOut = 0;

        for (uint256 i = 0; i < count; ++i) {
            Position storage p = positions[i];
            if (p.amount == 0 || block.timestamp < p.unlockTime) continue;

            uint256 amount = p.amount;
            totalAmount += amount;
            totalEffectiveOut += _effective(amount, p.multiplierBps);
            p.amount = 0;
            p.multiplierBps = 0;
            emit Withdrawn(msg.sender, i, amount);
        }

        // One write per total instead of one per position.
        if (totalAmount > 0) {
            totalStaked -= totalAmount;
            totalEffective -= totalEffectiveOut;
            stakedOf[msg.sender] -= totalAmount;
            effectiveBalanceOf[msg.sender] -= totalEffectiveOut;
            stakingToken.safeTransfer(msg.sender, totalAmount);
        }
        _claim();
    }

    /// @notice Reset an expired lock's boost to 1x. Anyone can call this.
    function kick(address user, uint256 positionId) external nonReentrant updateReward(user) {
        Position storage p = _position(user, positionId);
        if (block.timestamp < p.unlockTime || p.multiplierBps == BASE_MULTIPLIER) revert NotKickable();

        uint256 oldEffective = _effective(p.amount, p.multiplierBps);
        uint256 newEffective = p.amount;
        p.multiplierBps = BASE_MULTIPLIER;

        effectiveBalanceOf[user] -= oldEffective - newEffective;
        totalEffective -= oldEffective - newEffective;
        emit Kicked(user, positionId, msg.sender);
    }

    // ------------------------------------------------------------------
    // Owner actions
    // ------------------------------------------------------------------

    function setRewardsDuration(uint256 newDuration) external onlyOwner {
        if (block.timestamp < finishAt) revert RewardPeriodActive();
        if (newDuration == 0) revert ZeroDuration();
        duration = newDuration;
        emit RewardsDurationUpdated(newDuration);
    }

    /// @notice Pull `amount` reward tokens from the owner and start (or extend) a reward period.
    ///         Rewards left over from an active period roll into the new one.
    function notifyRewardAmount(uint256 amount) external onlyOwner updateReward(address(0)) {
        rewardsToken.safeTransferFrom(msg.sender, address(this), amount);

        // Everything the new period will pay out: the new amount plus what's left of the current period.
        uint256 total = amount;
        if (block.timestamp < finishAt) {
            // rewardRate is the exact rate still being paid, so this is exactly what the current
            // schedule has left to pay. No precision is lost here (see AUDIT.md, Slither notes).
            // slither-disable-next-line divide-before-multiply
            total += (finishAt - block.timestamp) * rewardRate;
        }
        if (total < duration) revert RewardRateZero(); // would round the rate down to 0

        // The contract must hold the full total. Staked funds (when both tokens are the same)
        // and recoverable undistributed rewards don't count.
        uint256 available = rewardsToken.balanceOf(address(this)) - undistributedRewards;
        if (address(rewardsToken) == address(stakingToken)) {
            available -= totalStaked;
        }
        if (total > available) revert RewardTooHigh();

        // slither-disable-next-line divide-before-multiply
        rewardRate = total / duration;

        finishAt = block.timestamp + duration;
        updatedAt = block.timestamp;
        emit RewardAdded(amount, rewardRate, finishAt);
    }

    /// @notice Send rewards that accrued while nobody was staked to `to`.
    function recoverUndistributed(address to) external onlyOwner nonReentrant updateReward(address(0)) {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = undistributedRewards;
        if (amount == 0) revert NothingToRecover();
        undistributedRewards = 0;
        rewardsToken.safeTransfer(to, amount);
        emit UndistributedRecovered(to, amount);
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    function _position(address user, uint256 positionId) internal view returns (Position storage p) {
        if (positionId >= _positions[user].length) revert InvalidPosition(positionId);
        p = _positions[user][positionId];
        if (p.amount == 0) revert InvalidPosition(positionId);
    }

    function _effective(uint256 amount, uint16 multiplierBps) internal pure returns (uint256) {
        return (amount * multiplierBps) / BASE_MULTIPLIER;
    }

    function _withdraw(uint256 positionId) internal {
        Position storage p = _position(msg.sender, positionId);
        if (block.timestamp < p.unlockTime) revert StillLocked(p.unlockTime);

        uint256 amount = p.amount;
        uint256 effective = _effective(amount, p.multiplierBps);
        p.amount = 0;
        p.multiplierBps = 0;

        totalStaked -= amount;
        totalEffective -= effective;
        stakedOf[msg.sender] -= amount;
        effectiveBalanceOf[msg.sender] -= effective;

        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, positionId, amount);
    }

    function _claim() internal {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }
}
