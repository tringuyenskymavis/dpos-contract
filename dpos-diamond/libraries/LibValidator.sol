pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../../contracts/interfaces/IMaintenance.sol";
import "../../contracts/libraries/Math.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

library LibValidator {
  event NewValidatorAdded(address cid);
  event ValidatorRemoved(address cid);

  error ErrValidatorAlreadyExists(address cid);
  error ErrValidatorNotExists(address cid);

  using EnumerableSet for EnumerableSet.AddressSet;

  bytes32 constant VALIDATOR_STORAGE_POSITION = keccak256("diamond.standard.validator.storage");

  struct ValidatorProfile {
    address cid;
    address admin;
  }

  struct ValidatorStorage {
    EnumerableSet.AddressSet _validators;
    mapping(address cid => bool) _validatorExists;
    mapping(address cid => ValidatorProfile) _validatorProfile;
  }

  function validatorStorage() internal pure returns (ValidatorStorage storage ds) {
    bytes32 position = VALIDATOR_STORAGE_POSITION;
    assembly {
      ds.slot := position
    }
  }

  function applyValidator(ValidatorProfile memory profile) internal {
    ValidatorStorage storage vs = validatorStorage();
    address cid = profile.cid;

    if (vs._validatorExists[cid]) revert ErrValidatorAlreadyExists(cid);
    vs._validators.add(cid);
    vs._validatorExists[profile.cid] = true;
    vs._validatorProfile[profile.cid] = profile;
    emit NewValidatorAdded(cid);
  }

  function removeValidator(ValidatorProfile memory profile) internal {
    address cid = profile.cid;
    ValidatorStorage storage vs = validatorStorage();
    if (!vs._validatorExists[cid]) revert ErrValidatorNotExists(cid);
    vs._validators.remove(cid);

    delete vs._validatorExists[cid];
    delete vs._validatorProfile[cid];
    emit ValidatorRemoved(cid);
  }

  function isValidator(address cid) internal view returns (bool) {
    return validatorStorage()._validatorExists[cid];
  }

  function isValidatorAdmin(address cid, address admin) internal view returns (bool) {
    return validatorStorage()._validatorProfile[cid].admin == admin;
  }

  function getValidators() internal view returns (address[] memory) {
    return validatorStorage()._validators.values();
  }
}
