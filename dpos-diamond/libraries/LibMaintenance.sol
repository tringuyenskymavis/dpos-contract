// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../../contracts/interfaces/IMaintenance.sol";
import "../../contracts/libraries/Math.sol";
import "./LibValidator.sol";
import { ErrUnauthorized, RoleAccess } from "../../contracts/utils/CommonErrors.sol";

library LibMaintenance {
  using EnumerableSet for EnumerableSet.AddressSet;

  bytes32 constant MAINTENANCE_STORAGE_POSITION = keccak256("diamond.standard.maintenance.storage");

  struct MaintenanceStorage {
    /// @dev Mapping from candidate id => maintenance schedule.
    mapping(address => IMaintenance.Schedule) _schedule;
    /// @dev The min duration to maintenance in blocks.
    uint256 _minMaintenanceDurationInBlock;
    /// @dev The max duration to maintenance in blocks.
    uint256 _maxMaintenanceDurationInBlock;
    /// @dev The offset to the min block number that the schedule can start.
    uint256 _minOffsetToStartSchedule;
    /// @dev The offset to the max block number that the schedule can start.
    uint256 _maxOffsetToStartSchedule;
    /// @dev The max number of scheduled maintenances.
    uint256 _maxSchedule;
    /// @dev The cooldown time to request new schedule.
    uint256 _cooldownSecsToMaintain;
    /// @dev The set of scheduled candidates.
    EnumerableSet.AddressSet _scheduledCandidates;
  }

  function maintenanceStorage() internal pure returns (MaintenanceStorage storage ds) {
    bytes32 position = MAINTENANCE_STORAGE_POSITION;
    assembly {
      ds.slot := position
    }
  }

  /**
   * @dev Synchronizes the schedule by checking if the scheduled candidates are still in maintenance and removes the candidates that are no longer in maintenance.
   * @return count The number of active schedules.
   */
  function syncSchedule() internal returns (uint256 count) {
    unchecked {
      EnumerableSet.AddressSet storage _scheduledCandidates = maintenanceStorage()._scheduledCandidates;
      address[] memory mSchedules = _scheduledCandidates.values();
      uint256 length = mSchedules.length;

      for (uint256 i; i < length; ++i) {
        if (checkScheduledById(mSchedules[i])) {
          ++count;
        } else {
          _scheduledCandidates.remove(mSchedules[i]);
        }
      }
    }
  }

  /**
   * @dev Check if the validator was maintaining in the current period.
   *
   * Note: This method should be called at the end of the period.
   */
  function maintainingInBlockRange(
    address candidateId,
    uint256 fromBlock,
    uint256 toBlock
  ) internal view returns (bool) {
    IMaintenance.Schedule storage s = maintenanceStorage()._schedule[candidateId];
    return Math.twoRangeOverlap(fromBlock, toBlock, s.from, s.to);
  }

  function checkScheduledById(address candidateId) internal view returns (bool) {
    return block.number <= maintenanceStorage()._schedule[candidateId].to;
  }

  function checkManyMaintainedInBlockRangeById(
    address[] memory idList,
    uint256 fromBlock,
    uint256 toBlock
  ) internal view returns (bool[] memory resList) {
    uint256 length = idList.length;
    resList = new bool[](length);

    for (uint256 i; i < length; ++i) {
      resList[i] = maintainingInBlockRange(idList[i], fromBlock, toBlock);
    }
  }

  /**
   * @dev Checks if the caller is a candidate admin for the given candidate ID.
   */
  function requireCandidatAdmin(address candidateId) internal view {
    if (!LibValidator.isValidatorAdmin(candidateId, msg.sender)) {
      revert ErrUnauthorized(msg.sig, RoleAccess.CANDIDATE_ADMIN);
    }
  }

  function checkMaintained(address candidateId, uint256 atBlock) internal view returns (bool) {
    IMaintenance.Schedule storage _s = maintenanceStorage()._schedule[candidateId];
    return _s.from <= atBlock && atBlock <= _s.to;
  }

  function checkCooldownEnded(address candidateId) internal view returns (bool) {
    return block.timestamp
      > maintenanceStorage()._schedule[candidateId].requestTimestamp + maintenanceStorage()._cooldownSecsToMaintain;
  }

  function setMaintenanceConfig(
    uint256 minMaintenanceDurationInBlock_,
    uint256 maxMaintenanceDurationInBlock_,
    uint256 minOffsetToStartSchedule_,
    uint256 maxOffsetToStartSchedule_,
    uint256 maxSchedule_,
    uint256 cooldownSecsToMaintain_
  ) internal {
    if (minMaintenanceDurationInBlock_ >= maxMaintenanceDurationInBlock_) {
      revert IMaintenance.ErrInvalidMaintenanceDurationConfig();
    }
    if (minOffsetToStartSchedule_ >= maxOffsetToStartSchedule_) {
      revert IMaintenance.ErrInvalidOffsetToStartScheduleConfigs();
    }

    MaintenanceStorage storage ms = maintenanceStorage();
    ms._minMaintenanceDurationInBlock = minMaintenanceDurationInBlock_;
    ms._maxMaintenanceDurationInBlock = maxMaintenanceDurationInBlock_;
    ms._minOffsetToStartSchedule = minOffsetToStartSchedule_;
    ms._maxOffsetToStartSchedule = maxOffsetToStartSchedule_;
    ms._maxSchedule = maxSchedule_;
    ms._cooldownSecsToMaintain = cooldownSecsToMaintain_;
    emit IMaintenance.MaintenanceConfigUpdated(
      minMaintenanceDurationInBlock_,
      maxMaintenanceDurationInBlock_,
      minOffsetToStartSchedule_,
      maxOffsetToStartSchedule_,
      maxSchedule_,
      cooldownSecsToMaintain_
    );
  }

  function maintainanceInit() internal {
    uint256 maxSchedules = uint256(3);
    uint256 minOffsetToStartSchedule = uint256(200);
    uint256 cooldownSecsToMaintain = uint256(3 days);
    uint256 maxOffsetToStartSchedule = uint256(200 * 7);
    uint256 minMaintenanceDurationInBlock = uint256(100);
    uint256 maxMaintenanceDurationInBlock = uint256(1000);
    setMaintenanceConfig(
      minMaintenanceDurationInBlock,
      maxMaintenanceDurationInBlock,
      minOffsetToStartSchedule,
      maxOffsetToStartSchedule,
      maxSchedules,
      cooldownSecsToMaintain
    );
  }
}
