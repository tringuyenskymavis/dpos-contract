// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import "../../contracts/interfaces/IMaintenance.sol";
import "../libraries/LibMaintenance.sol";
import "../../contracts/utils/CommonErrors.sol";
import "../../contracts/libraries/Math.sol";
import "../libraries/LibTiming.sol";
import { console2 } from "forge-std/console2.sol";

contract MaintenanceFacet is IMaintenance {
  using Math for uint256;
  using EnumerableSet for EnumerableSet.AddressSet;

  modifier syncSchedule() {
    LibMaintenance.syncSchedule();
    _;
  }

  function initialize(
    address validatorContract,
    uint256 minMaintenanceDurationInBlock_,
    uint256 maxMaintenanceDurationInBlock_,
    uint256 minOffsetToStartSchedule_,
    uint256 maxOffsetToStartSchedule_,
    uint256 maxSchedule_,
    uint256 cooldownSecsToMaintain_
  ) external { }

  function initializeV2() external { }

  function initializeV3(address profileContract_) external { }

  function initializeV4() external { }

  /**
   * @inheritdoc IMaintenance
   */
  function setMaintenanceConfig(
    uint256 minMaintenanceDurationInBlock_,
    uint256 maxMaintenanceDurationInBlock_,
    uint256 minOffsetToStartSchedule_,
    uint256 maxOffsetToStartSchedule_,
    uint256 maxSchedules_,
    uint256 cooldownSecsToMaintain_
  ) external { }

  /**
   * @inheritdoc IMaintenance
   */
  function schedule(TConsensus consensusAddr, uint256 startedAtBlock, uint256 endedAtBlock) external {
    address cid = TConsensus.unwrap(consensusAddr);
    _requireCandidateAdmin(cid);

    LibMaintenance.MaintenanceStorage storage ms = LibMaintenance.maintenanceStorage();

    if (LibMaintenance.checkScheduledById(cid)) revert ErrAlreadyScheduled();
    if (!LibMaintenance.checkCooldownEnded(cid)) revert ErrCooldownTimeNotYetEnded();
    if (LibMaintenance.syncSchedule() >= ms._maxSchedule) {
      revert ErrTotalOfSchedulesExceeded();
    }
    if (
      !startedAtBlock.inRange(block.number + ms._minOffsetToStartSchedule, block.number + ms._maxOffsetToStartSchedule)
    ) revert ErrStartBlockOutOfRange();
    if (startedAtBlock >= endedAtBlock) revert ErrStartBlockOutOfRange();

    uint256 maintenanceElapsed = endedAtBlock - startedAtBlock + 1;

    if (!maintenanceElapsed.inRange(ms._minMaintenanceDurationInBlock, ms._maxMaintenanceDurationInBlock)) {
      revert ErrInvalidMaintenanceDuration();
    }
    if (!LibTiming.epochEndingAt(startedAtBlock - 1)) {
      console2.log("start block end of epoch");
      revert ErrStartBlockOutOfRange();
    }
    if (!LibTiming.epochEndingAt(endedAtBlock)) revert ErrEndBlockOutOfRange();

    Schedule storage sSchedule = ms._schedule[cid];
    sSchedule.from = startedAtBlock;
    sSchedule.to = endedAtBlock;
    sSchedule.lastUpdatedBlock = block.number;
    sSchedule.requestTimestamp = block.timestamp;
    ms._scheduledCandidates.add(cid);

    emit MaintenanceScheduled(cid, sSchedule);
  }

  function _requireCandidateAdmin(address cid) internal view {
    if (!LibValidator.isValidatorAdmin(cid, msg.sender)) revert ErrUnauthorized(msg.sig, RoleAccess.CANDIDATE_ADMIN);
  }

  /**
   * @inheritdoc IMaintenance
   */
  function cancelSchedule(TConsensus consensusAddr) external syncSchedule {
    address cid = TConsensus.unwrap(consensusAddr);
    _requireCandidateAdmin(cid);

    if (!LibMaintenance.checkScheduledById(cid)) revert ErrUnexistedSchedule();
    if (LibMaintenance.checkMaintained(cid, block.number)) revert ErrAlreadyOnMaintenance();

    Schedule storage _sSchedule = LibMaintenance.maintenanceStorage()._schedule[cid];
    delete _sSchedule.from;
    delete _sSchedule.to;
    _sSchedule.lastUpdatedBlock = block.number;
    LibMaintenance.maintenanceStorage()._scheduledCandidates.remove(cid);

    emit MaintenanceScheduleCancelled(cid);
  }

  /**
   * @inheritdoc IMaintenance
   */
  function exitMaintenance(TConsensus consensusAddr) external syncSchedule {
    address cid = TConsensus.unwrap(consensusAddr);
    uint256 currentBlock = block.number;
    _requireCandidateAdmin(cid);

    if (!LibMaintenance.checkMaintained(cid, block.number)) revert ErrNotOnMaintenance();

    Schedule storage _sSchedule = LibMaintenance.maintenanceStorage()._schedule[cid];
    _sSchedule.to = currentBlock;
    _sSchedule.lastUpdatedBlock = currentBlock;
    LibMaintenance.maintenanceStorage()._scheduledCandidates.remove(cid);

    emit MaintenanceExited(cid);
  }

  /**
   * @inheritdoc IMaintenance
   */
  function checkMaintained(TConsensus consensusAddr, uint256 _block) external view returns (bool) {
    return LibMaintenance.checkMaintained(TConsensus.unwrap(consensusAddr), _block);
  }

  /**
   * @inheritdoc IMaintenance
   */
  function checkMaintainedById(address validatorId, uint256 _block) external view returns (bool) {
    return LibMaintenance.checkMaintained(validatorId, _block);
  }

  /**
   * @inheritdoc IMaintenance
   */
  function checkMaintainedInBlockRange(
    TConsensus consensusAddr,
    uint256 _fromBlock,
    uint256 _toBlock
  ) external view returns (bool) {
    return LibMaintenance.maintainingInBlockRange(TConsensus.unwrap(consensusAddr), _fromBlock, _toBlock);
  }

  /**
   * @inheritdoc IMaintenance
   */
  function checkManyMaintained(
    TConsensus[] calldata consensusAddrList,
    uint256 atBlock
  ) external view returns (bool[] memory) {
    uint256 length = consensusAddrList.length;
    address[] memory idList = new address[](length);
    for (uint256 i; i < length; ++i) {
      idList[i] = TConsensus.unwrap(consensusAddrList[i]);
    }
    return _checkManyMaintainedById(idList, atBlock);
  }

  /**
   * @inheritdoc IMaintenance
   */
  function checkManyMaintainedById(
    address[] calldata candidateIdList,
    uint256 atBlock
  ) external view returns (bool[] memory) {
    return _checkManyMaintainedById(candidateIdList, atBlock);
  }

  function _checkManyMaintainedById(
    address[] memory idList,
    uint256 atBlock
  ) internal view returns (bool[] memory resList) {
    uint256 length = idList.length;
    resList = new bool[](length);

    for (uint256 i; i < length; ++i) {
      resList[i] = LibMaintenance.checkMaintained(idList[i], atBlock);
    }
  }

  /**
   * @inheritdoc IMaintenance
   */
  function checkManyMaintainedInBlockRange(
    TConsensus[] calldata _consensusAddrList,
    uint256 _fromBlock,
    uint256 _toBlock
  ) external view returns (bool[] memory) {
    uint256 length = _consensusAddrList.length;
    address[] memory idList = new address[](length);
    for (uint256 i; i < length; ++i) {
      idList[i] = TConsensus.unwrap(_consensusAddrList[i]);
    }
    return LibMaintenance.checkManyMaintainedInBlockRangeById(idList, _fromBlock, _toBlock);
  }

  /**
   * @inheritdoc IMaintenance
   */
  function checkManyMaintainedInBlockRangeById(
    address[] calldata idList,
    uint256 fromBlock,
    uint256 toBlock
  ) external view returns (bool[] memory) {
    return LibMaintenance.checkManyMaintainedInBlockRangeById(idList, fromBlock, toBlock);
  }

  /**
   * @inheritdoc IMaintenance
   */
  function checkCooldownEnded(TConsensus consensusAddr) external view returns (bool) {
    return LibMaintenance.checkCooldownEnded(TConsensus.unwrap(consensusAddr));
  }

  /**
   * @inheritdoc IMaintenance
   */
  function checkScheduled(TConsensus consensusAddr) external view returns (bool) {
    return LibMaintenance.checkScheduledById(TConsensus.unwrap(consensusAddr));
  }

  /**
   * @inheritdoc IMaintenance
   */
  function getSchedule(TConsensus consensusAddr) external view returns (Schedule memory) {
    return LibMaintenance.maintenanceStorage()._schedule[TConsensus.unwrap(consensusAddr)];
  }

  /**
   * @inheritdoc IMaintenance
   */
  function totalSchedule() external view returns (uint256 count) {
    unchecked {
      address[] memory mSchedules = LibMaintenance.maintenanceStorage()._scheduledCandidates.values();
      uint256 length = mSchedules.length;

      for (uint256 i; i < length; ++i) {
        if (LibMaintenance.checkScheduledById(mSchedules[i])) ++count;
      }
    }
  }

  /**
   * @inheritdoc IMaintenance
   */
  function cooldownSecsToMaintain() external view returns (uint256) {
    return LibMaintenance.maintenanceStorage()._cooldownSecsToMaintain;
  }

  /**
   * @inheritdoc IMaintenance
   */
  function minMaintenanceDurationInBlock() external view returns (uint256) {
    return LibMaintenance.maintenanceStorage()._minMaintenanceDurationInBlock;
  }

  /**
   * @inheritdoc IMaintenance
   */
  function maxMaintenanceDurationInBlock() external view returns (uint256) {
    return LibMaintenance.maintenanceStorage()._maxMaintenanceDurationInBlock;
  }

  /**
   * @inheritdoc IMaintenance
   */
  function minOffsetToStartSchedule() external view returns (uint256) {
    return LibMaintenance.maintenanceStorage()._minOffsetToStartSchedule;
  }

  /**
   * @inheritdoc IMaintenance
   */
  function maxOffsetToStartSchedule() external view returns (uint256) {
    return LibMaintenance.maintenanceStorage()._maxOffsetToStartSchedule;
  }

  /**
   * @inheritdoc IMaintenance
   */
  function maxSchedule() external view returns (uint256) {
    return LibMaintenance.maintenanceStorage()._maxSchedule;
  }
}
