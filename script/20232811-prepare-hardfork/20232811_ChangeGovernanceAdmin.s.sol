// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { console2 as console } from "forge-std/console2.sol";
import { stdStorage, StdStorage } from "forge-std/StdStorage.sol";
import { LibErrorHandler } from "contract-libs/LibErrorHandler.sol";
import { TContract } from "foundry-deployment-kit/types/Types.sol";
import { LibProxy } from "foundry-deployment-kit/libraries/LibProxy.sol";
import { Proposal, RoninMigration } from "script/RoninMigration.s.sol";
import { LibString, Contract } from "script/utils/Contract.sol";
import { RoninGovernanceAdmin, HardForkRoninGovernanceAdminDeploy } from "script/contracts/HardForkRoninGovernanceAdminDeploy.s.sol";
import { RoninTrustedOrganization, TemporalRoninTrustedOrganizationDeploy } from "script/contracts/TemporalRoninTrustedOrganizationDeploy.s.sol";

contract Migration__20232811_ChangeGovernanceAdmin is RoninMigration {
  using LibString for *;
  using LibErrorHandler for bool;
  using stdStorage for StdStorage;
  using LibProxy for address payable;

  function run() public {
    // ================================================= Simulation Scenario for HardFork Upgrade Scenario ==========================================

    // Denotation:
    // - Current Broken Ronin Governance Admin (X)
    // - Current Ronin Trusted Organization (Y)
    // - New Temporal Ronin Trusted Organization (A)
    // - New Ronin Governance Admin (B)

    // 1. Deploy new (A) which has extra interfaces ("sumGovernorWeights(address[])", "totalWeights()").
    // 2. Deploy (B) which is compatible with (Y).
    // 3. Cheat storage slot of Ronin Trusted Organization of current broken Ronin Governance Admin (Y) to point from (Y) -> (A)
    // 4. Create and Execute Proposal of changing all system contracts that have ProxAdmin address of (X) to change from (X) -> (A)
    // 5. Validate (A) functionalities

    // =============================================================================================================================================

    // Get current broken Ronin Governance Admin
    address roninGovernanceAdmin = config.getAddressFromCurrentNetwork(Contract.RoninGovernanceAdmin.key());

    // Deploy temporal Ronin Trusted Organization
    // RoninTrustedOrganization tmpTrustedOrg = new TemporalRoninTrustedOrganizationDeploy().run();
    // vm.makePersistent(address(tmpTrustedOrg));

    // Deploy new Ronin Governance Admin
    RoninGovernanceAdmin hardForkGovernanceAdmin = new HardForkRoninGovernanceAdminDeploy().run();

    // StdStorage storage $;
    // assembly {
    //   // Assign storage slot
    //   $.slot := stdstore.slot
    // }

    // Cheat write into Trusted Organization storage slot with new temporal Trusted Organization contract
    // $.target(roninGovernanceAdmin).sig("roninTrustedOrganizationContract()").checked_write(address(tmpTrustedOrg));
    // (, bytes memory rawData) =
    //   address(roninGovernanceAdmin).staticcall(abi.encodeWithSignature("roninTrustedOrganizationContract()"));
    // assertEq(abi.decode(rawData, (address)), address(tmpTrustedOrg));

    address trustedOrg = config.getAddressFromCurrentNetwork(Contract.RoninTrustedOrganization.key());
    vm.store(
      address(trustedOrg),
      bytes32(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc),
      bytes32(uint256(uint160(0x6A51C2B073a6daDBeCAC1A420AFcA7788C81612f)))
    );

    // Get all contracts deployed from the current network
    address payable[] memory addrs = config.getAllAddresses(network());

    // Identify proxy targets to change admin
    for (uint256 i; i < addrs.length; ++i) {
      try this.getProxyAdmin(addrs[i]) returns (address payable proxy) {
        if (proxy == roninGovernanceAdmin) {
          console.log("Target Proxy to change admin with proposal", vm.getLabel(addrs[i]));
          _proxyTargets.push(addrs[i]);
        }
      } catch {}
    }

    address[] memory targets = _proxyTargets;
    uint256[] memory values = new uint256[](targets.length);
    bytes[] memory callDatas = new bytes[](targets.length);

    // Build `changeAdmin` calldata to migrate to new Ronin Governance Admin
    for (uint256 i; i < targets.length; ++i) {
      callDatas[i] = abi.encodeWithSelector(
        TransparentUpgradeableProxy.changeAdmin.selector,
        address(hardForkGovernanceAdmin)
      );
    }

    Proposal.ProposalDetail memory proposal = _buildProposal(
      RoninGovernanceAdmin(roninGovernanceAdmin),
      block.timestamp + 5 minutes,
      targets,
      values,
      callDatas
    );

    // Execute the proposal
    _executeProposal(RoninGovernanceAdmin(roninGovernanceAdmin), RoninTrustedOrganization(trustedOrg), proposal);

    // Change broken Ronin Governance Admin to new Ronin Governance Admin
    config.setAddress(network(), Contract.RoninGovernanceAdmin.key(), address(hardForkGovernanceAdmin));
  }
}
