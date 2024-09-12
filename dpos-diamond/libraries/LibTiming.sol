// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import { GlobalConfigConsumer } from "../../contracts/extensions/consumers/GlobalConfigConsumer.sol";
import { ITimingInfo } from "../../contracts/interfaces/validator/info-fragments/ITimingInfo.sol";

library LibTiming {
  event TimingInitialized(uint256 numberOfBlocksInEpoch);
  // 32 bytes keccak hash of a string to use as a timing storage location.

  bytes32 constant TIMING_STORAGE_POSITION = keccak256("diamond.standard.timing.storage");

  struct TimingStorage {
    /// @dev The number of blocks in a epoch
    uint256 _numberOfBlocksInEpoch;
    /// @dev The last updated block
    uint256 _lastUpdatedBlock;
    /// @dev The last updated period
    uint256 _lastUpdatedPeriod;
    /// @dev The starting block of the last updated period
    uint256 _currentPeriodStartAtBlock;
    /// @dev Mapping from epoch index => period index
    mapping(uint256 epoch => uint256 period) _periodOf;
    /// @dev Mapping from period index => ending block
    mapping(uint256 period => uint256 endedAtBlock) _periodEndBlock;
    /// @dev The first period which tracked period ending block
    uint256 _firstTrackedPeriodEnd;
  }

  function timingStorage() internal pure returns (TimingStorage storage timingInfo) {
    bytes32 position = TIMING_STORAGE_POSITION;
    assembly {
      timingInfo.slot := position
    }
  }

  function currentPeriod() internal view returns (uint256) {
    return timingStorage()._lastUpdatedPeriod;
  }

  function epochEndingAt(uint256 _block) internal view returns (bool) {
    TimingStorage storage ts = timingStorage();
    return _block % ts._numberOfBlocksInEpoch == ts._numberOfBlocksInEpoch - 1;
  }

  function timingInit() internal {
    TimingStorage storage ts = timingStorage();
    ts._numberOfBlocksInEpoch = 200;
    emit TimingInitialized(ts._numberOfBlocksInEpoch);
  }
}
