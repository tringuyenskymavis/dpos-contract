// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import "../../contracts/interfaces/staking/IRewardPool.sol";
import "../../contracts/libraries/Math.sol";
import "../../contracts/udvts/Types.sol";
import "./LibBaseStaking.sol";
import "./LibTiming.sol";

library LibRewardCalculation {
  // 32 bytes keccak hash of a string to use as a reward calculation storage location.
  bytes32 constant REWARD_CALCULATION_STORAGE_POSITION = keccak256("diamond.standard.reward.storage");

  struct RewardCalculationStorage {
    /// @dev Mapping from pool address => period number => accumulated rewards per share (one unit staking)
    mapping(address poolId => mapping(uint256 periodNumber => PeriodWrapperConsumer.PeriodWrapper)) _accumulatedRps;
    /// @dev Mapping from the pool address => user address => the reward info of the user
    mapping(address poolId => mapping(address user => IRewardPool.UserRewardFields)) _userReward;
    /// @dev Mapping from the pool address => reward pool fields
    mapping(address poolId => IRewardPool.PoolFields) _stakingPool;
  }

  function rewardCalculationStorage() internal pure returns (RewardCalculationStorage storage ds) {
    bytes32 position = REWARD_CALCULATION_STORAGE_POSITION;
    // assigns struct storage slot to the storage position
    assembly {
      ds.slot := position
    }
  }

  /**
   * @dev Returns the reward amount that user claimable.
   */
  function getReward(
    address poolId,
    address user,
    uint256 latestPeriod,
    uint256 latestStakingAmount
  ) internal view returns (uint256) {
    IRewardPool.UserRewardFields storage _reward = rewardCalculationStorage()._userReward[poolId][user];

    if (_reward.lastPeriod == latestPeriod) {
      return _reward.debited;
    }

    uint256 aRps;
    uint256 lastPeriodReward;
    IRewardPool.PoolFields storage _pool = rewardCalculationStorage()._stakingPool[poolId];
    IRewardPool.PeriodWrapper storage _wrappedArps =
      rewardCalculationStorage()._accumulatedRps[poolId][_reward.lastPeriod];

    if (_wrappedArps.lastPeriod > 0) {
      // Calculates the last period reward if the aRps at the period is set
      aRps = _wrappedArps.inner;
      lastPeriodReward = _reward.lowestAmount * (aRps - _reward.aRps);
    } else {
      // Fallbacks to the previous aRps in case the aRps is not set
      aRps = _reward.aRps;
    }

    uint256 newPeriodsReward = latestStakingAmount * (_pool.aRps - aRps);
    return _reward.debited + (lastPeriodReward + newPeriodsReward) / 1e18;
  }

  /**
   * @dev Syncs the user reward.
   *
   * Emits the event `UserRewardUpdated` once the debit amount is updated.
   * Emits the event `PoolSharesUpdated` once the pool share is updated.
   *
   * Note: The method should be called whenever the user's staking amount changes.
   *
   */
  function syncUserReward(address poolId, address user, uint256 newStakingAmount) internal {
    uint256 period = LibTiming.currentPeriod();
    IRewardPool.PoolFields storage _pool = rewardCalculationStorage()._stakingPool[poolId];
    uint256 lastShares = _pool.shares.inner;

    // Updates the pool shares if it is outdated
    if (_pool.shares.lastPeriod < period) {
      _pool.shares = PeriodWrapperConsumer.PeriodWrapper(LibBaseStaking.getStakingTotal(poolId), period);
    }

    IRewardPool.UserRewardFields storage _reward = rewardCalculationStorage()._userReward[poolId][user];
    uint256 currentStakingAmount = LibBaseStaking.getStakingAmount(poolId, user);
    uint256 debited = getReward(poolId, user, period, currentStakingAmount);

    if (_reward.debited != debited) {
      _reward.debited = debited;
      emit IRewardPool.UserRewardUpdated(poolId, user, debited);
    }

    syncMinStakingAmount(_pool, _reward, period, newStakingAmount, currentStakingAmount);
    _reward.aRps = _pool.aRps;
    _reward.lastPeriod = period;

    if (_pool.shares.inner != lastShares) {
      emit IRewardPool.PoolSharesUpdated(period, poolId, _pool.shares.inner);
    }
  }

  /**
   * @dev Syncs the minimum staking amount of an user in the current period.
   */
  function syncMinStakingAmount(
    IRewardPool.PoolFields storage _pool,
    IRewardPool.UserRewardFields storage _reward,
    uint256 latestPeriod,
    uint256 newStakingAmount,
    uint256 currentStakingAmount
  ) internal {
    if (_reward.lastPeriod < latestPeriod) {
      _reward.lowestAmount = currentStakingAmount;
    }

    uint256 lowestAmount = Math.min(_reward.lowestAmount, newStakingAmount);
    uint256 diffAmount = _reward.lowestAmount - lowestAmount;
    if (diffAmount > 0) {
      _reward.lowestAmount = lowestAmount;
      if (_pool.shares.inner < diffAmount) revert IRewardPool.ErrInvalidPoolShare();
      _pool.shares.inner -= diffAmount;
    }
  }

  /**
   * @dev Claims the settled reward for a specific user.
   *
   * @param lastPeriod Must be in two possible value: `_currentPeriod` in normal calculation, or
   * `_currentPeriod + 1` in case of calculating the reward for revoked validators.
   *
   * Emits the `RewardClaimed` event and the `UserRewardUpdated` event.
   *
   * Note: This method should be called before transferring rewards for the user.
   *
   */
  function claimReward(address poolId, address user, uint256 lastPeriod) internal returns (uint256 amount) {
    uint256 currentStakingAmount = LibBaseStaking.getStakingAmount(poolId, user);
    amount = getReward(poolId, user, lastPeriod, currentStakingAmount);
    emit IRewardPool.RewardClaimed(poolId, user, amount);

    IRewardPool.UserRewardFields storage _reward = rewardCalculationStorage()._userReward[poolId][user];
    _reward.debited = 0;
    syncMinStakingAmount(
      rewardCalculationStorage()._stakingPool[poolId], _reward, lastPeriod, currentStakingAmount, currentStakingAmount
    );
    _reward.lastPeriod = lastPeriod;
    _reward.aRps = rewardCalculationStorage()._stakingPool[poolId].aRps;
    emit IRewardPool.UserRewardUpdated(poolId, user, 0);
  }

  /**
   * @dev Records the amount of rewards `_rewards` for the pools `poolIds`.
   *
   * Emits the event `PoolsUpdated` once the contract recorded the rewards successfully.
   * Emits the event `PoolsUpdateFailed` once the input array lengths are not equal.
   * Emits the event `PoolUpdateConflicted` when the pool is already updated in the period.
   *
   * Note: This method should be called once at the period ending.
   *
   */
  function recordRewards(address[] memory poolIds, uint256[] calldata rewards, uint256 period) internal {
    if (poolIds.length != rewards.length) {
      emit IRewardPool.PoolsUpdateFailed(period, poolIds, rewards);
      return;
    }

    uint256 rps;
    uint256 count;
    address poolId;
    uint256 stakingTotal;
    uint256[] memory aRps = new uint256[](poolIds.length);
    uint256[] memory shares = new uint256[](poolIds.length);
    address[] memory conflicted = new address[](poolIds.length);

    for (uint i = 0; i < poolIds.length; i++) {
      poolId = poolIds[i];
      IRewardPool.PoolFields storage _pool = rewardCalculationStorage()._stakingPool[poolId];
      stakingTotal = LibBaseStaking.getStakingTotal(poolId);

      if (rewardCalculationStorage()._accumulatedRps[poolId][period].lastPeriod == period) {
        unchecked {
          conflicted[count++] = poolId;
        }
        continue;
      }

      // Updates the pool shares if it is outdated
      if (_pool.shares.lastPeriod < period) {
        _pool.shares = PeriodWrapperConsumer.PeriodWrapper(stakingTotal, period);
      }

      // The rps is 0 if no one stakes for the pool
      rps = _pool.shares.inner == 0 ? 0 : (rewards[i] * 1e18) / _pool.shares.inner;
      aRps[i - count] = _pool.aRps += rps;
      rewardCalculationStorage()._accumulatedRps[poolId][period] =
        PeriodWrapperConsumer.PeriodWrapper(_pool.aRps, period);
      _pool.shares.inner = stakingTotal;
      shares[i - count] = _pool.shares.inner;
      poolIds[i - count] = poolId;
    }

    if (count > 0) {
      assembly {
        mstore(conflicted, count)
        mstore(poolIds, sub(mload(poolIds), count))
      }
      emit IRewardPool.PoolsUpdateConflicted(period, conflicted);
    }

    if (poolIds.length > 0) {
      emit IRewardPool.PoolsUpdated(period, poolIds, aRps, shares);
    }
  }
}
