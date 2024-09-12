import { Diamond } from "dpos-diamond/Diamond.sol";
import { DiamondCutFacet, IDiamondCut } from "dpos-diamond/facets/DiamondCutFacet.sol";
import { MaintenanceFacet, IMaintenance } from "dpos-diamond/facets/MaintenanceFacet.sol";
import { LibMaintenance } from "dpos-diamond/libraries/LibMaintenance.sol";
import { LibValidator } from "dpos-diamond/libraries/LibValidator.sol";
import { LibTiming } from "dpos-diamond/libraries/LibTiming.sol";
import { LibRewardCalculation } from "dpos-diamond/libraries/LibRewardCalculation.sol";
import { Script } from "forge-std/Script.sol";
import { DiamondInit } from "dpos-diamond/upgradeInitializers/DiamondInit.sol";
import { DiamondLoupeFacet } from "dpos-diamond/facets/DiamondLoupeFacet.sol";
import { OwnershipFacet } from "dpos-diamond/facets/OwnershipFacet.sol";
import { TConsensus } from "contracts/udvts/Types.sol";
import "../../contracts/utils/CommonErrors.sol";
import { RoleAccess } from "../../contracts/utils/RoleAccess.sol";
import { CandidateStakingFacet } from "dpos-diamond/facets/CandidateStakingFacet.sol";
import { console2 } from "forge-std/console2.sol";

contract DiamondDeploy is Script {
  address internal _diamond;
  address internal _cutFacet;
  address internal _maintenanceFacet;
  address internal _initializer;
  address internal _diamondLoupeFacet;
  address internal _ownershipFacet;
  address internal _owner = makeAddr("Owner");
  IDiamondCut.FacetCut[] internal _facets;
  address internal _candidateStakingFacet;

  function run() public {
    _deployFacet();
    _deployInitializer();
    _prepareFacetCuts();
    _diamond = address(new Diamond(_owner, _cutFacet));

    bytes memory callData = abi.encodeCall(DiamondInit.init, ());
    vm.startPrank(_owner);
    IDiamondCut(_diamond).diamondCut(_facets, _initializer, callData);
    vm.stopPrank();
    _testDiamond();
  }

  function _deployFacet() internal {
    _cutFacet = address(new DiamondCutFacet());
    _diamondLoupeFacet = address(new DiamondLoupeFacet());
    _candidateStakingFacet = address(new CandidateStakingFacet());
    _ownershipFacet = address(new OwnershipFacet());
    bytes4[] memory ownershipFacetSelectors = new bytes4[](2);
    ownershipFacetSelectors[0] = OwnershipFacet.transferOwnership.selector;
    ownershipFacetSelectors[1] = OwnershipFacet.owner.selector;
    _maintenanceFacet = address(new MaintenanceFacet());

    vm.label(_cutFacet, "DiamondCutFacet");
    vm.label(_diamondLoupeFacet, "DiamondLoupeFacet");
    vm.label(_ownershipFacet, "OwnershipFacet");
    vm.label(_maintenanceFacet, "MaintenanceFacet");
    vm.label(_candidateStakingFacet, "CandidateStakingFacet");
  }

  function _deployInitializer() internal {
    _initializer = address(new DiamondInit());
  }

  function _prepareFacetCuts() internal {
    // DiamondLoupeFacet's selectors
    bytes4[] memory diamondLoupeFacetSelectors = new bytes4[](4);
    diamondLoupeFacetSelectors[0] = DiamondLoupeFacet.facets.selector;
    diamondLoupeFacetSelectors[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
    diamondLoupeFacetSelectors[2] = DiamondLoupeFacet.facetAddresses.selector;
    diamondLoupeFacetSelectors[3] = DiamondLoupeFacet.facetAddress.selector;
    _facets.push(
      IDiamondCut.FacetCut({
        facetAddress: _diamondLoupeFacet,
        action: IDiamondCut.FacetCutAction.Add,
        functionSelectors: diamondLoupeFacetSelectors
      })
    );
    // OwnershipFacet's selectors
    bytes4[] memory ownershipFacetSelectors = new bytes4[](2);
    ownershipFacetSelectors[0] = OwnershipFacet.transferOwnership.selector;
    ownershipFacetSelectors[1] = OwnershipFacet.owner.selector;

    _facets.push(
      IDiamondCut.FacetCut({
        facetAddress: _ownershipFacet,
        action: IDiamondCut.FacetCutAction.Add,
        functionSelectors: ownershipFacetSelectors
      })
    );
    // MaintenanceFacet's selectors
    bytes4[] memory maintenanceFacetSelectors = new bytes4[](2);
    maintenanceFacetSelectors[0] = MaintenanceFacet.schedule.selector;
    maintenanceFacetSelectors[1] = MaintenanceFacet.cancelSchedule.selector;

    _facets.push(
      IDiamondCut.FacetCut({
        facetAddress: _maintenanceFacet,
        action: IDiamondCut.FacetCutAction.Add,
        functionSelectors: maintenanceFacetSelectors
      })
    );
    // CandidateStakingFacet's selectors
    bytes4[] memory candidateStakingFacetSelectors = new bytes4[](3);
    candidateStakingFacetSelectors[0] = CandidateStakingFacet.applyValidatorCandidate.selector;
    candidateStakingFacetSelectors[1] = CandidateStakingFacet.getCommissionRateRange.selector;
    candidateStakingFacetSelectors[2] = CandidateStakingFacet.minValidatorStakingAmount.selector;
    _facets.push(
      IDiamondCut.FacetCut({
        facetAddress: _candidateStakingFacet,
        action: IDiamondCut.FacetCutAction.Add,
        functionSelectors: candidateStakingFacetSelectors
      })
    );
  }

  function _testDiamond() internal {
    _testRevertMaintenance();
    _testConcreteMaintenance();
  }

  function _testRevertMaintenance() internal {
    vm.startPrank(makeAddr("Validator admin"));
    vm.expectRevert(
      abi.encodeWithSelector(ErrUnauthorized.selector, IMaintenance.schedule.selector, RoleAccess.CANDIDATE_ADMIN)
    );
    console2.log("current block number", block.number);
    // fork this block 30711961
    IMaintenance(_diamond).schedule(TConsensus.wrap(makeAddr("Validator")), 30712200, 30712200 + 199);
  }

  function _testConcreteMaintenance() internal {
    _testApplyThenMaintenance();
    _testCancelMaintenance();
  }

  function _testApplyThenMaintenance() internal {
    address validatorAdmin = makeAddr("Validator admin");
    address validator = makeAddr("Validator");
    vm.startPrank(validatorAdmin);
    vm.deal(validatorAdmin, 100_000 ether);
    CandidateStakingFacet(_diamond).applyValidatorCandidate{ value: 100_000 ether }(TConsensus.wrap(validator), 15_00);
    IMaintenance(_diamond).schedule(TConsensus.wrap(validator), 30712200, 30712200 + 199);
    vm.stopPrank();
  }

  function _testCancelMaintenance() internal {
    address validatorAdmin = makeAddr("Validator admin");
    address validator = makeAddr("Validator");
    vm.prank(validatorAdmin);
    IMaintenance(_diamond).cancelSchedule(TConsensus.wrap(validator));
  }
}
