// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import "../../contracts/extensions/RONTransferHelper.sol";
import "../../contracts/interfaces/staking/IBaseStaking.sol";
import "../../contracts/interfaces/validator/IRoninValidatorSet.sol";
import "../../contracts/interfaces/IProfile.sol";
import "../../contracts/libraries/Math.sol";
import { TPoolId, TConsensus } from "../../contracts/udvts/Types.sol";
import { LibRewardCalculation } from "./LibRewardCalculation.sol";

library LibBaseStaking {
  // 32 bytes keccak hash of a string to use as a base staking storage location.
  bytes32 constant BASE_STAKING_STORAGE_POSITION = keccak256("diamond.standard.base.staking.storage");

  struct BaseStakingStorage {
    /// @dev Mapping from pool address (i.e. validator id) => staking pool detail
    mapping(address pid => IBaseStaking.PoolDetail) _poolDetail;
    /// @dev The cooldown time in seconds to undelegate from the last timestamp (s)he delegated.
    uint256 _cooldownSecsToUndelegate;
    /// @dev The number of seconds that a candidate must wait to be revoked and take the self-staking amount back.
    uint256 _waitingSecsToRevoke;
    /// @dev Mapping from "admin address of an active pool" => "pool id".
    mapping(address adminOfActivePool => address poolId) _adminOfActivePoolMapping;
  }

  function baseStakingStorage() internal pure returns (BaseStakingStorage storage bs) {
    bytes32 position = BASE_STAKING_STORAGE_POSITION;
    assembly {
      bs.slot := position
    }
  }

  function requireValue() internal view {
    if (msg.value == 0) revert IBaseStaking.ErrZeroValue();
  }

  function requirePoolAdmin(IBaseStaking.PoolDetail storage _pool, address requester) internal view {
    if (_pool.__shadowedPoolAdmin != requester) revert IBaseStaking.ErrOnlyPoolAdminAllowed();
  }

  function anyExceptPoolAdmin(IBaseStaking.PoolDetail storage _pool, address delegator) internal view {
    if (_pool.wasAdmin[delegator]) revert IBaseStaking.ErrPoolAdminForbidden();
  }

  function isAdminOfActivePool(address admin) internal view returns (bool) {
    return baseStakingStorage()._adminOfActivePoolMapping[admin] != address(0);
  }

  function poolOfConsensusIsActive(TConsensus consensusAddr) internal view {
    
  }

  function getPoolDetailById(address poolId)
    internal
    view
    returns (address admin, uint256 stakingAmount, uint256 stakingTotal)
  {
    IBaseStaking.PoolDetail storage _pool = baseStakingStorage()._poolDetail[poolId];
    return (_pool.__shadowedPoolAdmin, _pool.stakingAmount, _pool.stakingTotal);
  }

  function getManySelfStakingsById(address[] memory poolIds) internal view returns (uint256[] memory selfStakings_) {
    selfStakings_ = new uint256[](poolIds.length);
    mapping(address poolId => IBaseStaking.PoolDetail _poolDetail) storage _poolDetail =
      baseStakingStorage()._poolDetail;
    for (uint i = 0; i < poolIds.length;) {
      selfStakings_[i] = _poolDetail[poolIds[i]].stakingAmount;

      unchecked {
        ++i;
      }
    }
  }

  function getStakingTotal(address poolId) internal view returns (uint256) {
    return baseStakingStorage()._poolDetail[poolId].stakingTotal;
  }

  function getStakingAmount(address poolId, address user) internal view returns (uint256) {
    return baseStakingStorage()._poolDetail[poolId].delegatingAmount[user];
  }

  /**
   * @dev Changes the delegate amount.
   */
  function changeDelegatingAmount(
    IBaseStaking.PoolDetail storage _pool,
    address delegator,
    uint256 newDelegatingAmount,
    uint256 newStakingTotal
  ) internal {
    LibRewardCalculation.syncUserReward(_pool.pid, delegator, newDelegatingAmount);
    _pool.stakingTotal = newStakingTotal;
    _pool.delegatingAmount[delegator] = newDelegatingAmount;
  }
}
