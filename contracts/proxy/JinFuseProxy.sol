// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "./JinFuseStorage.sol";

/**
 * @title JinFuseProxy
 * @author JinFinance
 * @dev This proxy holds the storage contract and delegates every call to the current implementation set.
 * Besides, it allows to upgrade the token's behaviour towards further implementations, and provides authorization control functionalities
 */
contract JinFuseProxy is JinFuseStorage {

    /**
    * @dev This event will be emitted every time the implementation gets upgraded
    * @param version representing the version number of the upgraded implementation
    * @param implementation representing the address of the upgraded implementation
    */
    event Upgraded(bytes32 version, address indexed implementation);

    /**
    * @dev This event will be emitted when ownership is transferred
    * @param previousOwner address which represents the previous owner
    * @param newOwner address which represents the new owner
    */
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
    * @dev This event will be emitted when a new implementation contract is set to pending status
    * @param _pendingImplementation address of the implmentation contract that's pending
    * @param _changeableAt timestamp of when pending timelock expires
    */
    event NewPendingImplementation(address _pendingImplementation, uint256 _changeableAt);


    /**
    * @dev This modifier verifies that msg.sender is the owner of the contract
    */
    modifier onlyOwner() {
      require(msg.sender == getOwner());
      _;
    }

    /**
    * @dev Constructor
    * @param _initialImplementation address representing the implementation contract
    * @param _pendingPeriod the waiting period between when a change in the implementation contract can occur
    */
    constructor(address _initialImplementation, uint256 _pendingPeriod) public {
      require(_initialImplementation != address(0));
      _setImplementation(_initialImplementation);
      _setPendingPeriod(_pendingPeriod);
      _setOwner(msg.sender);
    }
    

    /**
    * @dev Fallback function allowing to perform a delegatecall to the given _implementation().
    * This function will return whatever the implementation call returns
    */
    fallback() external payable {
      address _impl = _implementation();
      require(_impl != address(0));

      assembly {
        // Copy msg.data. We take full control of memory in this inline assembly
        // block because it will not return to Solidity code. We overwrite the
        // Solidity scratch pad at memory position 0.
        calldatacopy(0, 0, calldatasize())

        // Call the implementation.
        // out and outsize are 0 because we don't know the size yet
        let result := delegatecall(gas(), _impl, 0, calldatasize(), 0, 0)

        // Copy the returned data
        returndatacopy(0, 0, returndatasize())

        switch result
        // delegatecall returns 0 on error.
        case 0 { revert(0, returndatasize()) }
        default { return(0, returndatasize()) }
      }
    }


    /**
     * @dev Allows Owner to upgrade the current implementation
     * A Timelock has been put in place. There is a built-in waiting period between implementation contract
     * can be change and go into effect. 
     * @param _newImplementation representing the address of the new implementation to be set.
     */
    function upgradeTo(address _newImplementation) public onlyOwner {
      require(_newImplementation != address(0), "New implementation: cannot be addres(0)");
      require(_newImplementation != _implementation(), "New implementation: cannot be the same as current one");
      require(implementationTimeLock() != 0 && block.timestamp >= implementationTimeLock(), "Timelock: waiting period has not end");
      require(_newImplementation == pendingImplementation(), "New implementation: does not match pending implementation");

      _setImplementation(_newImplementation);
      _setImplementationTimeLock(0);  //resets timelock to 0 signaling no new implementation is pending
      _setVersion(_newImplementation);

      emit Upgraded(version(), _newImplementation);
    }

    /**
     * @dev Declare & set a pending implementation contract and starts the Timelock
     */
    function declarePendingImplementation(address _pendingImpl) public onlyOwner {
      _setPendingImplementation(_pendingImpl);

      uint256 time = block.timestamp + getPendingPeriod();
      _setImplementationTimeLock(time);

      emit NewPendingImplementation(_pendingImpl, time);
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
      _setOwner(address(0));
      //_transferOwnership(address(0));
    }

    /**
     * @dev Allows the current owner to transfer control of the contract to a _newOwner.
     * @param _newOwner The address to transfer ownership to.
     */
    function transferOwnership(address _newOwner) public onlyOwner {
      require(_newOwner != address(0));
      emit OwnershipTransferred(getOwner(), _newOwner);
      _setOwner(_newOwner);
    }


    /**
     * @dev Returns the current implementation
     */
    function implementation() external view returns(address) {
      return _implementation();
    }

    /**
     * @dev Returns the current pending implementation
     */
    function pendingImplementation() public view returns(address) {
      return addressStorage[keccak256(abi.encodePacked("jlsfp.proxy.pendingImpl"))];
    }

    /**
     * @dev Gets the time value of the pending period 
     */
    function getPendingPeriod() public view returns(uint256) {
      return uintStorage[keccak256(abi.encodePacked("jlsfp.proxy.pendingPeriod"))];
    }

    /**
     *@dev Returns timestamp of when timelock expires
     */
    function implementationTimeLock() public view returns(uint256) {
      return uintStorage[keccak256(abi.encodePacked("jlsfp.proxy.timeLock"))];
    }

    function getOwner() public view returns(address) {
      return addressStorage[keccak256(abi.encodePacked("owner"))];
    }
    
    function version() public view returns(bytes32) {
      return bytes32Storage[keccak256(abi.encodePacked("jlsfp.proxy.version"))];
    }

    /**
     * @dev Sets the pending implementation contract to be upgraded to
     */
    function _setPendingImplementation(address _impl) internal {
      require(_impl != address(0));
      require(_impl != _implementation());

      addressStorage[keccak256(abi.encodePacked("jlsfp.proxy.pendingImpl"))] = _impl;
    }

    /**
     * @dev Sets the pending time period between implementation contract change
     */
    function _setPendingPeriod(uint256 _period) internal {
      uintStorage[keccak256(abi.encodePacked("jlsfp.proxy.pendingPeriod"))] = _period;
    }

    /**
     *@dev (Timelock) Sets the time period before implementation contract can be change
     *@param _time the timestamp at which the Timelock will expire
     */
    function _setImplementationTimeLock(uint256 _time) internal {
      uintStorage[keccak256(abi.encodePacked("jlsfp.proxy.timeLock"))] = _time;
    }

    function _setOwner(address _owner) private {
      addressStorage[keccak256(abi.encodePacked("owner"))] = _owner;
    }

    /**
     * @dev Stores a new address in the implementation slot
     */
    function _setImplementation(address _newImplementation) private {
        addressStorage[_IMPLEMENTATION_SLOT] = _newImplementation;
    }

    function _setVersion(address _newImpl) private {
      bytes32 newVersion = keccak256(abi.encodePacked(_IMPLEMENTATION_SLOT, _newImpl));
      bytes32Storage[keccak256(abi.encodePacked("jlsfp.proxy.version"))] = newVersion;
    }

}
