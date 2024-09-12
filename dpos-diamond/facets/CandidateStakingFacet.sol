// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import { LibArray } from "../../contracts/libraries/LibArray.sol";
import "../../contracts/interfaces/staking/ICandidateStaking.sol";
import "../libraries/LibBaseStaking.sol";
import { IBaseStaking } from "../../contracts/interfaces/staking/IBaseStaking.sol";
import "../libraries/LibRewardCalculation.sol";
import "../libraries/LibValidator.sol";

contract CandidateStakingFacet {
  uint256 internal constant MIN_VALIDATOR_STAKING_AMOUNT = 100_000 ether;
  uint256 internal constant MAX_COMMISSION_RATE = 100_00;
  uint256 internal constant MIN_COMMISSION_RATE = 10_00;

  function minValidatorStakingAmount() public pure returns (uint256) {
    return MIN_VALIDATOR_STAKING_AMOUNT;
  }

  function getCommissionRateRange() external pure returns (uint256, uint256) {
    return (MIN_COMMISSION_RATE, MAX_COMMISSION_RATE);
  }

  function applyValidatorCandidate(TConsensus consensusAddr, uint256 commissionRate) external payable {
    LibBaseStaking.BaseStakingStorage storage bs = LibBaseStaking.baseStakingStorage();

    if (LibBaseStaking.isAdminOfActivePool(msg.sender)) {
      revert IBaseStaking.ErrAdminOfAnyActivePoolForbidden(msg.sender);
    }
    if (commissionRate > MAX_COMMISSION_RATE || commissionRate < MIN_COMMISSION_RATE) {
      revert ICandidateStaking.ErrInvalidCommissionRate();
    }

    uint256 amount = msg.value;
    address payable poolAdmin = payable(msg.sender);
    address poolId = TConsensus.unwrap(consensusAddr);

    _applyValidatorCandidate({ poolAdmin: poolAdmin, candidateAdmin: msg.sender, poolId: poolId, amount: amount });

    IBaseStaking.PoolDetail storage _pool = bs._poolDetail[poolId];
    _pool.__shadowedPoolAdmin = poolAdmin;
    _pool.pid = poolId;
    bs._adminOfActivePoolMapping[poolAdmin] = poolId;
    _pool.wasAdmin[poolAdmin] = true;

    _stake(_pool, poolAdmin, amount);
    emit ICandidateStaking.PoolApproved(poolId, poolAdmin);
  }

  function _applyValidatorCandidate(
    address payable poolAdmin,
    address candidateAdmin,
    address poolId,
    uint256 amount
  ) internal {
    if (amount < minValidatorStakingAmount()) revert ICandidateStaking.ErrInsufficientStakingAmount();
    if (poolAdmin != candidateAdmin) revert ICandidateStaking.ErrThreeInteractionAddrsNotEqual();
    if (poolAdmin == poolId) revert LibArray.ErrDuplicated(msg.sig);

    LibValidator.applyValidator(LibValidator.ValidatorProfile({ cid: poolId, admin: candidateAdmin }));
  }

  function _stake(IBaseStaking.PoolDetail storage _pool, address requester, uint256 amount) internal {
    LibBaseStaking.requirePoolAdmin(_pool, requester);
    _pool.stakingAmount += amount;
    LibBaseStaking.changeDelegatingAmount(_pool, requester, _pool.stakingAmount, _pool.stakingTotal + amount);
    _pool.lastDelegatingTimestamp[requester] = block.timestamp;
    emit ICandidateStaking.Staked(_pool.pid, amount);
  }

  function _unstake(IBaseStaking.PoolDetail storage _pool, address requester, uint256 amount) internal {
    LibBaseStaking.requirePoolAdmin(_pool, requester);
    if (amount > _pool.stakingAmount) revert ICandidateStaking.ErrInsufficientStakingAmount();
    if (
      _pool.lastDelegatingTimestamp[requester] + LibBaseStaking.baseStakingStorage()._cooldownSecsToUndelegate
        > block.timestamp
    ) {
      revert ICandidateStaking.ErrUnstakeTooEarly();
    }

    _pool.stakingAmount -= amount;
    LibBaseStaking.changeDelegatingAmount(_pool, requester, _pool.stakingAmount, _pool.stakingTotal - amount);
    emit ICandidateStaking.Unstaked(_pool.pid, amount);
  }
}
