// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { TransparentUpgradeableProxyV2 } from "@ronin/contracts/extensions/TransparentUpgradeableProxyV2.sol";
import { BridgeSlashDeploy } from "script/contracts/BridgeSlashDeploy.s.sol";
import { BridgeRewardDeploy } from "script/contracts/BridgeRewardDeploy.s.sol";
import { RoninBridgeManagerDeploy } from "script/contracts/RoninBridgeManagerDeploy.s.sol";
import "./20231003_REP002AndREP003_RON_NonConditional_Wrapup2Periods.s.sol";

contract Simulation_20231003_REP002AndREP003_RON_NonConditional_GatewayUpgrade is
  Simulation__20231003_UpgradeREP002AndREP003_RON_NonConditional_Wrapup2Periods
{
  function _hookSetDepositCount() internal pure override returns (uint256) {
    return 42213; // fork-block-number 28327195
  }

  function run() public virtual override {
    Simulation__20231003_UpgradeREP002AndREP003_Base.run();

    // -------------- Day #1 --------------------
    _deployGatewayContracts();

    // -------------- Day #2 (execute proposal on ronin) --------------------
    // LibWrapUpEpoch.fastForwardToNextDay();
    // LibWrapUpEpoch.wrapUpPeriod();

    vm.warp(vm.getBlockTimestamp() + 3 seconds);
    vm.roll(vm.getBlockNumber() + 1);

    _upgradeDPoSContracts();
    _upgradeGatewayContracts();
    _callInitREP2InGatewayContracts();
    _changeAdminOfGatewayContracts();

    // -- done execute proposal

    // Deposit for
    vm.warp(vm.getBlockTimestamp() + 3 seconds);
    vm.roll(vm.getBlockNumber() + 1);
    // _depositFor("after-upgrade-REP2");
    // _dummySwitchNetworks();
    _depositForOnlyOnRonin("after-upgrade-REP2");

    LibWrapUpEpoch.fastForwardToNextDay();
    vm.warp(vm.getBlockTimestamp() + 3 seconds);
    vm.roll(vm.getBlockNumber() + 1);
    _depositForOnlyOnRonin("after-upgrade-REP2_a");

    LibWrapUpEpoch.fastForwardToNextDay();
    vm.warp(vm.getBlockTimestamp() + 3 seconds);
    vm.roll(vm.getBlockNumber() + 1);
    _depositForOnlyOnRonin("after-upgrade-REP2_b");

    // -------------- End of Day #2 --------------------

    // - wrap up period
    LibWrapUpEpoch.wrapUpPeriod();

    vm.warp(vm.getBlockTimestamp() + 3 seconds);
    vm.roll(vm.getBlockNumber() + 1);
    _depositForOnlyOnRonin("after-wrapup-Day2"); // share bridge reward here
    // _depositFor("after-DAY2");

    LibWrapUpEpoch.fastForwardToNextDay();
    vm.warp(vm.getBlockTimestamp() + 3 seconds);
    vm.roll(vm.getBlockNumber() + 1);
    _depositForOnlyOnRonin("after-wrapup-Day2_a");

    // - deposit for

    // -------------- End of Day #3 --------------------
    // - wrap up period
    LibWrapUpEpoch.wrapUpPeriod();

    vm.warp(vm.getBlockTimestamp() + 3 seconds);
    vm.roll(vm.getBlockNumber() + 1);
    _depositForOnlyOnRonin("after-wrapup-Day3"); // share bridge reward here
  }

  /**
   * @dev Tasks:
   * - Deploy BridgeReward
   * - Deploy BridgeSlash
   * - Deploy RoninBridgeManager
   * - Top up for BridgeReward
   */
  function _deployGatewayContracts() internal logFn("_deployGatewayContracts()") {
    uint256 bridgeManagerNonce = vm.getNonce(sender()) + 4;
    address expectedRoninBridgeManager = computeCreateAddress(sender(), bridgeManagerNonce);

    _bridgeSlash = IBridgeSlash(
      new BridgeSlashDeploy().overrideArgs(
        abi.encodeCall(
          IBridgeSlash.initialize,
          (address(_validatorSet), expectedRoninBridgeManager, address(_bridgeTracking), address(_roninGovernanceAdmin))
        )
      ).run()
    );

    _bridgeReward = IBridgeReward(
      new BridgeRewardDeploy().overrideArgs(
        abi.encodeCall(
          IBridgeReward.initialize,
          (
            expectedRoninBridgeManager,
            address(_bridgeTracking),
            address(_bridgeSlash),
            address(_validatorSet),
            address(_roninGovernanceAdmin),
            1337_133
          )
        )
      ).run()
    );

    IBridgeManager actualRoninBridgeManager = new RoninBridgeManagerDeploy().run();
    assertEq(address(actualRoninBridgeManager), expectedRoninBridgeManager);
    _roninBridgeManager = actualRoninBridgeManager;

    _bridgeReward.receiveRON{ value: 100 ether }();
  }

  /**
   * @dev Tasks:
   * - Upgrade RoninGatewayV3
   * - Upgrade BridgeTracking
   */
  function _upgradeGatewayContracts() internal logFn("_upgradeGatewayContracts()") {
    {
      // upgrade `RoninGatewayV3` and bump to V2
      _upgradeProxy(Contract.RoninGatewayV3.key(), abi.encodeCall(IRoninGatewayV3.initializeV2, ()));
      // bump `RoninGatewayV3` to V3
      _roninGateway.initializeV3(address(_roninBridgeManager));
    }

    {
      // bump `BridgeTracking` to V3
      _bridgeTracking.initializeV3({
        bridgeManager: address(_roninBridgeManager),
        bridgeSlash: address(_bridgeSlash),
        bridgeReward: address(_bridgeReward),
        dposGA: address(_roninGovernanceAdmin)
      });
    }
  }

  function _callInitREP2InGatewayContracts() internal logFn("_callInitREP2InGatewayContracts()") {
    vm.startPrank(address(_roninGovernanceAdmin));
    TransparentUpgradeableProxyV2(payable(address(_bridgeReward))).functionDelegateCall(
      abi.encodeCall(IBridgeReward.initializeREP2, ())
    );
    TransparentUpgradeableProxyV2(payable(address(_bridgeTracking))).functionDelegateCall(
      abi.encodeCall(IBridgeTracking.initializeREP2, ())
    );
    TransparentUpgradeableProxyV2(payable(address(_bridgeSlash))).functionDelegateCall(
      abi.encodeCall(IBridgeSlash.initializeREP2, ())
    );
    vm.stopPrank();
  }

  function _changeAdminOfGatewayContracts() internal logFn("_changeAdminOfGatewayContracts()") {
    vm.startPrank(address(_roninGovernanceAdmin));
    TransparentUpgradeableProxyV2(payable(address(_roninGateway))).changeAdmin(address(_roninBridgeManager));
    vm.stopPrank();
  }
}
