// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "./proxy/JinFuseStorage.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

interface IConsensus {
    function delegate(address _validator) external payable;
    function withdraw(address _validator, uint256 _amount) external;
    function delegatedAmount(address _address, address _validator) external view returns(uint256);
    function getMaxStake() external pure returns(uint256);
    function stakeAmount(address _address) external view returns(uint256);
}

interface IToken {
    function mint(address recipient_, uint256 amount_) external returns (bool);
    function burn(uint256 _amount) external;
}

/**
* @title Fuse Liquid staking pool implementation logic
* @author JinFinance.com
*
* This is a Fuse liquid staking protocol 
*
*/
contract JinFuseStakingPool is JinFuseStorage {
    using SafeMath for uint256;

    bytes32 internal constant PRICE_RATIO = keccak256(abi.encodePacked("priceRatio"));
    bytes32 internal constant EPOCH = keccak256(abi.encodePacked("epoch"));
    bytes32 internal constant EPOCH_INTERVAL = keccak256(abi.encodePacked("epochInterval"));
    bytes32 internal constant LAST_UPDATE_TIME = keccak256(abi.encodePacked("lastUpdateTime"));
    bytes32 internal constant SYSTEM_STAKE_LIMIT = keccak256(abi.encodePacked("systemStakeLimit"));
    bytes32 internal constant SYSTEM_TOTAL_STAKED = keccak256(abi.encodePacked("systemTotalStaked"));
    bytes32 internal constant SAFEGUARD_LIMIT_ENABLED = keccak256(abi.encodePacked("safeguardLimitEnabled"));
    bytes32 internal constant OVER_LIMIT = keccak256(abi.encodePacked("overLimit"));
    bytes32 internal constant OWNER = keccak256(abi.encodePacked("owner"));
    bytes32 internal constant TREASURY = keccak256(abi.encodePacked("treasury"));
    bytes32 internal constant CONSENSUS = keccak256(abi.encodePacked("consensus"));
    bytes32 internal constant SF_TOKEN = keccak256(abi.encodePacked("SFToken"));
    bytes32 internal constant VALIDATORS = keccak256(abi.encodePacked("validators"));
    bytes32 internal constant VALIDATOR_INDEX = keccak256(abi.encodePacked("validatorIndex"));
    bytes32 internal constant PROTOCOL_FEE_BASIS = keccak256(abi.encodePacked("protocolFeeBasis"));
    bytes32 internal constant REENTRANCY_GUARD = keccak256(abi.encodePacked("reentracyGuard"));
    bytes32 internal constant PAUSE_FLAG_POSITION = keccak256(abi.encodePacked("pauseFlagPosition"));


    /**
    * @notice This event is emitted when the epoch is updated
    * @param latestEpoch the new value of the current epoch
    */
    event EpochUpdated(uint256 latestEpoch);

    /**
    * @notice This event is emitted when a deposit is made
    * @param user the address that made the deposit
    * @param deposit the amount deposited by user
    * @param tokens the amount of tokens received by user
    */
    event Deposited(address indexed user, uint256 deposit, uint256 tokens);

    /**
    * @notice This event is emitted when a withdrawal occurs
    * @param user the address that made the withdrawal
    * @param tokens the amount of tokens exchanged
    * @param rate the exchange rate ratio at time of withdraw
    * @param payout the amount received
    */
    event Withdrawn(address indexed user, uint256 tokens, uint256 rate, uint256 payout);

    /**
    * @notice This event is emitted when tokens are burned upon withdrawals
    * @param tokens the amount of tokens burned
    * @param exchanger the user address that tokens were received from and initiated the withdrawal
    */
    event Burned(uint256 tokens, address exchanger);

    /**
    * @notice This event is emitted when the protocol's validator index is manually changed
    * @param newIndex the new value of the index
    * @param priorIndex the prior value of the index
    */
    event ChangedValidatorIndex(uint256 newIndex, uint256 priorIndex);

    /**
    * @notice This event is emitted when the price ratio (protocol's exchange rate) is updated
    * @param updatedRatio the new value of the ratio
    * @param accumulatedRewards the amount of staking rewards after fee
    * @param totalSupply the total supply of tokens
    */
    event UpdatedPriceRatio(uint256 updatedRatio, uint256 accumulatedRewards, uint256 totalSupply);
    
    /**
    * @notice This event is emitted when protocol fee portion is distributed to Treasury
    * @param treasury the address of the treasury
    * @param rewardedShares the amount of tokens corresponding to the value of the fees
    * @param protocolFees represents the value amount of the protocol fee portion
    * @param priceRatio the value representing the price ratio (exchange rate) of the token
    */
    event DistributedProtocolFee(address indexed treasury, uint256 rewardedShares, uint256 protocolFees, uint256 priceRatio);

    /**
    * @notice This event is emitted when protocol's staking limit is changed
    * @param newLimit the new staking limit of the protocol
    * @param priorLimit the old prior staking limit of the protocol
    */
    event NewSystemStakeLimit(uint256 newLimit, uint256 priorLimit);

    /**
    * @notice This event is emitted if system staking limits are removed
    * @param admin the address that calls the function
    */
    event DisabledSafeguard(address indexed admin);

    /**
    * @notice This event is emitted if system staking limits are reenabled
    * @param admin the address that calls the function
    */
    event ReenabledSafeguard(address indexed admin, uint256 newLimit);

    /**
    * @notice This event is emitted if protocol fee percentage is changed
    * @param admin the address that calls the function
    * @param newBasisRate the new fee percentage represented in basis points
    */
    event ChangedProtocolFee(address indexed admin, uint256 newBasisRate);

    /**
    * @notice This event is emitted when a new validator is added to list
    * @param admin the address that calls the function
    * @param validatorAdded the address of the newly validator added
    */
    event AddedValidator(address indexed admin, address validatorAdded);

    /**
    * @notice This event is emitted when a new validator is removed from list
    * @param validatorRemoved the address of the validator that is removed
    * @param admin the address that calls the function
    */
    event RemovedValidator(address validatorRemoved, address indexed admin);

    /**
    * @notice This event is emitted when a validator is replaced
    * @param newValidator the new validator added
    * @param oldValidator the old validator replaced
    */
    event ReplacedValidator(address newValidator, address oldValidator);

    /**
    * @notice This event is emitted when a pause occurs
    *
    * Refer to {isPaused} for more detail.
    */
    event Paused();

    /**
    * @notice This event is emitted when unpause occurs
    *
    * Refer to {isPaused} for more detail.
    */
    event Unpaused();


    /**
    * @dev This modifier verifies that msg.sender is the owner of the contract
    */
    modifier onlyOwner() {
        require(msg.sender == addressStorage[OWNER], "OWNER_VALIDATION_ERROR");
        _;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and make it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {

        require(uintStorage[REENTRANCY_GUARD] != 2, "ReentrancyGuard: reentrant call");

        uintStorage[REENTRANCY_GUARD] = 2;

        _;

        uintStorage[REENTRANCY_GUARD] = 1;
    }

    modifier whenNotStopped() {
        require(!isPaused(), "IS_PAUSED");
        _;
    }

    modifier whenStopped() {
        require(isPaused(), "IS_NOT_PAUSED");
        _;
    }

    /**
    * @dev This contract must be initialized with the following variables:
    * @param _initialValidator address of the initial validator
    * @param _consensus official Fuse Consensus contract
    * @param _token erc20 liquid stake token contract 
    * @param _treasury address of Protocol Treasury
    * @param _systemLimit set initial amount representing the limit on protocol's total staked
    * @param _epochInterval base time interval for each epoch period
    */
    function initialize(address _initialValidator, address _consensus, address _token, address _treasury, 
        uint256 _time, uint256 _systemLimit, uint256 _epochInterval) external onlyOwner {
        require(!isInitialized());
        require(_initialValidator != address(0));

        if(!isInValidatorList(_initialValidator)) {
            _addValidator(_initialValidator);
        }
        
        _setConsensus(_consensus);
        _setSFToken(_token);
        _setTreasury(_treasury);
        _setLastUpdateTime(_time);  
        _setSafeguardLimitEnabled(true);

        _setSystemStakeLimit(_systemLimit);            
        _setEpochInterval(_epochInterval);

        _setPriceRatio(1e18);       

        _setProtocolFeeBasis(500);     
        uintStorage[REENTRANCY_GUARD] = 1;


        setInitialized(true);

    }  


    /**
    * @notice Deposit funds into the staking pool
    * @dev Fallback function allowing users are able to submit their funds to the staking pool
    * This is executed when there's no match to any available function identifier
    * Restricts fallback calls from Consensus to prevent loop and lockout
    * Protects against accidental transactions from calling non-existent function
    */
    fallback() external payable {
        if (msg.sender != consensus()) {
            _deposit();
        }
    }

    /**
    * @notice Deposit funds into the staking pool
    * @dev This function is alternative way to deposit funds.
    */
    function deposit() external payable {
        _deposit();
    }


    /**
    * @notice Change how much can be staked to the protocol
    * @dev The allowed max amount is influenced and capped based on consensus and number of validators
    * @param _amount the desired amount for the protocol's total staking limit
    */
    function setSystemStakeLimit(uint256 _amount) external onlyOwner {
        require(_amount != systemStakeLimit(), "SAME_LIMIT, NO_CHANGE");
        uint256 systemMaxStake = IConsensus(consensus()).getMaxStake().mul(getValidatorsLength());
        require(_amount < systemMaxStake);

        emit NewSystemStakeLimit(_amount, systemStakeLimit());
        _setSystemStakeLimit(_amount);

        if (isOverLimit() && systemStakeLimit() > systemTotalStaked()) {
            _setOverLimit(false);
        }
    }

    /**
    * @notice (Optional) Removes restriction on system staking limits
    */
    function removeLimit() external onlyOwner {
        _setSafeguardLimitEnabled(false);

        emit DisabledSafeguard(msg.sender);
    }

    /**
    * @notice (Optional) Reenable restriction on system staking limits
    * @param _limit the amount to set the protocol stake limit to
    */
    function reenableLimit(uint256 _limit) external onlyOwner {
        require(!isSafeguardLimitEnabled());
        _setSafeguardLimitEnabled(true);
        _setSystemStakeLimit(_limit);

        emit ReenabledSafeguard(msg.sender, _limit);
    }

    /**
    * @notice Restakes network reward and updates exchange rate
    */
    function update() external {
        _update();
    }

    /**
    * @notice Withdraw funds from the staking pool
    * @dev This function is meant to also handle withdrawal amounts greater than max limit of a single validator 
    * @param _amount the amount of tokens to be exchanged which represents the user's share of the staking pool
    */
    function withdraw(uint256 _amount) external nonReentrant {

        IERC20(getSFToken()).transferFrom(msg.sender, address(this), _amount);

        _update();
        
        uint256 payout = _amount.mul(priceRatio()).div(1e18);
        uint256 withdrawableAmount = IConsensus(consensus()).delegatedAmount(address(this), _getCurrentValidator()); 
        
        if (withdrawableAmount >= payout) {
            IConsensus(consensus()).withdraw(_getCurrentValidator(), payout);
        } else {
            uint256 rpAmount = payout.sub(withdrawableAmount);
            IConsensus(consensus()).withdraw(_getCurrentValidator(), withdrawableAmount);

            address[] memory list = getValidators();
            for (uint256 i = 0; i < list.length; i++) {
                withdrawableAmount = IConsensus(consensus()).delegatedAmount(address(this), list[i]); 

                if (withdrawableAmount >= rpAmount) {
                    IConsensus(consensus()).withdraw(list[i], rpAmount);
                    break;
                } else {
                    rpAmount = rpAmount.sub(withdrawableAmount);
                    IConsensus(consensus()).withdraw(list[i], withdrawableAmount);
                }
            }
        }

        uint256 newSystemTotal = systemTotalStaked().sub(payout);
        _setSystemTotalStaked(newSystemTotal);
        
        IToken(getSFToken()).burn(_amount);

        (bool success, bytes memory data) = msg.sender.call{value: payout}("");
        require(success, "Failed to send withdrawal amount"); 
        
        emit Burned(_amount, msg.sender);
        emit Withdrawn(msg.sender, _amount, priceRatio(), payout);
    }

    /**
    * @notice Withdraw funds from the staking pool from a choosen validator
    * @dev This function handles withdrawal amounts up to selected validator's delegated amount
    * @param _amount the amount of tokens to be exchanged which represents the user's share of the staking pool
    * @param _validatorPosition the index position of the validator in which stakes are withdrawn from
    */
    function withdraw(uint256 _amount, uint256 _validatorPosition) external nonReentrant {
        require(!isPaused(), "Currently paused");
        
        IERC20(getSFToken()).transferFrom(msg.sender, address(this), _amount);

        _update();
        
        uint256 payout = _amount.mul(priceRatio()).div(1e18);
        address selectedValidator = _getValidatorAt(_validatorPosition);
        uint256 withdrawableAmount = IConsensus(consensus()).delegatedAmount(address(this), selectedValidator); 
        
        require(payout <= withdrawableAmount);
        IConsensus(consensus()).withdraw(selectedValidator, payout);

        uint256 newSystemTotal = systemTotalStaked().sub(payout);
        _setSystemTotalStaked(newSystemTotal);
        
        IToken(getSFToken()).burn(_amount);

        (bool success, bytes memory data) = msg.sender.call{value: payout}("");
        require(success, "Failed to send withdrawal amount");


        emit Burned(_amount, msg.sender);
        emit Withdrawn(msg.sender, _amount, priceRatio(), payout);

    }

    /**
      * @notice Stops selective validator withdrawal operation, defaults to withdraw()
      */
    function pause() external onlyOwner {
        _pause();

        emit Paused();
    }

    /**
      * @notice Resume selective validator withdrawal operation
      */
    function unpause() external onlyOwner {
        _unpause();

        emit Unpaused();
    }

    /**
    * @notice Sets protocol's performance fee (a percentage of staking rewards)
    * @param _amount represents the staking rewards fee defined in basis points 
    *
    * Access only by protocol owner. In the future, ownership can be transferred over 
    * to a Governance contract entity which will manage and handle operations in a decentralized way.
    */
    function changeProtocolFeeBasis(uint256 _amount) external onlyOwner {
        //restricts protocol performance fee to a max of 2000 (20%)
        require(_amount <= 2000); 
        _setProtocolFeeBasis(_amount);

        emit ChangedProtocolFee(msg.sender, _amount);
    }

    /**
    * @notice Adds new validator to staking pool
    * @param _newValidator address of the validator to be added 
    */
    function addValidator(address _newValidator) external onlyOwner {
        require(!isInValidatorList(_newValidator), "Already in list");
        _addValidator(_newValidator);

        emit AddedValidator(msg.sender, _newValidator);
    }

    /**
    * @notice Removes validator from staking pool
    * @param _validator address of the validator to be removed 
    */ 
    function removeValidator(address _validator) external onlyOwner {
        require(isInValidatorList(_validator), "_Validator: not an existing validator");
        require(getValidatorsLength() > 1, "Existing list must be greater than 1");

        address[] storage validatorList = addressArrayStorage[VALIDATORS];

        for (uint256 i = 0; i < validatorList.length; i++) {
            if(validatorList[i] == _validator) {
                
                validatorList[i] = validatorList[validatorList.length - 1];   
                validatorList.pop();

                //_setValidatorList(validatorList);                        

                //Redistribute staking pool's delegation in the removed validator
                uint256 withdrawableAmount = IConsensus(consensus()).delegatedAmount(address(this), _validator); 
                IConsensus(consensus()).withdraw(_validator, withdrawableAmount);
                _validatorStakeRedistribution(withdrawableAmount);

                emit RemovedValidator(_validator, msg.sender);

                break;
            }
        }
    }

    /**
    * @notice Removes validator from staking pool by replacing
    * @param _validator address of the validator to be replaced 
    * @param _replacement address of the validator replacement
    */
    function replaceValidator(address _validator, address _replacement) external onlyOwner {
        require(_replacement != address(0));
        require(isInValidatorList(_validator), "_Validator: not an existing validator");
        require(!isInValidatorList(_replacement), "Replacement: already on list");

        address[] memory validatorList = getValidators();

        for (uint256 i = 0; i < validatorList.length; i++) {
            if(validatorList[i] == _validator) {
                
                validatorList[i] = _replacement; 

                _setValidatorList(validatorList);                        

                //Redistribute staking pool's delegation in the removed validator
                uint256 withdrawableAmount = IConsensus(consensus()).delegatedAmount(address(this), _validator); 
                IConsensus(consensus()).withdraw(_validator, withdrawableAmount);
            
                _setValidatorIndex(i);

                _validatorStakeRedistribution(withdrawableAmount);

                emit ReplacedValidator(_replacement, _validator);

                break;
            }
        }
    }


    /**
    * @notice Removes validator from staking pool by index selection
    * @dev A simpler and more direct way to remove validator thru replacement
    * @param _index the index value of the validator to be replaced 
    * @param _replacement address of the validator replacement
    */
    function replaceValidatorByIndex(uint256 _index, address _replacement) external onlyOwner {
        require(_replacement != address(0));
        require(_index < getValidatorsLength(), "Does not exist: over list size");
        require(!isInValidatorList(_replacement), "Replacement: already on list");

        address[] memory validatorList = getValidators();
        address replacedValidator = validatorList[_index];
        validatorList[_index] = _replacement;
        _setValidatorList(validatorList);

        uint256 withdrawableAmount = IConsensus(consensus()).delegatedAmount(address(this), replacedValidator); 
        IConsensus(consensus()).withdraw(replacedValidator, withdrawableAmount);
        _validatorStakeRedistribution(withdrawableAmount);

        emit ReplacedValidator(_replacement, replacedValidator);

    }

    /**
    * @dev Mannually change the current index pointer
    * @param _index the index selector of the validator list
    */
    function setValidatorIndex(uint256 _index) public onlyOwner {
        require(getValidatorsLength() > 0);
        require(_index <= getValidatorsLength().sub(1));
        emit ChangedValidatorIndex(_index, getValidatorIndex()); 
        _setValidatorIndex(_index);
    }

    /**
      * @notice Returns current ratio representing the exchange rate
      */
    function priceRatio() public view returns(uint256) {
        return uintStorage[PRICE_RATIO];
    }

    /**
      * @notice Gets the current epoch of the protocol
      */
    function epoch() public view returns(uint256) {
        return uintStorage[EPOCH];
    }
    
    /**
    * @notice Returns the latest current interval of subsequent epochs
    * @dev Interval time can change so it's not a representation of protocol lifetime
    */
    function epochInterval() public view returns(uint256) {
        return uintStorage[EPOCH_INTERVAL];
    }

    /**
    * @notice Returns logged time of latest epoch
    * @dev Logs time of epoch change rather than when transaction is called
    *
    * See {_performEpochUpdate}
    */
    function lastUpdateTime() public view returns(uint256) {
        return uintStorage[LAST_UPDATE_TIME];
    }

    /**
      * @notice Returns the current protocol's total staking limit
      */
    function systemStakeLimit() public view returns(uint256) {
        return uintStorage[SYSTEM_STAKE_LIMIT];
    }

    /**
      * @notice Gets the total amount staked in the protocol
      */
    function systemTotalStaked() public view returns(uint256) {
        return uintStorage[SYSTEM_TOTAL_STAKED];
    }

    /**
      * @notice Returns whether or not safeguard limit is enabled
      */
    function isSafeguardLimitEnabled() public view returns(bool) {
        return boolStorage[SAFEGUARD_LIMIT_ENABLED];
    }

    /**
      * @notice Returns whether or not the protocol is over the designated limit
      */
    function isOverLimit() public view returns(bool) {
        return boolStorage[OVER_LIMIT];
    }

    /**
      * @notice Returns the treasury address
      */
    function getTreasury() public view returns(address) {
        return addressStorage[TREASURY];
    }

    /**
      * @notice Returns the consensus address
      */
    function consensus() public view returns(address) {
        return addressStorage[CONSENSUS];
    }

    /**
      * @notice Returns the token address representing user's share of the staking pool 
      */
    function getSFToken() public view returns(address) {
        return addressStorage[SF_TOKEN];
    }

    /**
      * @notice Gets the protocol's list of current validators
      */
    function getValidators() public view returns(address[] memory) {
        return addressArrayStorage[VALIDATORS];
    }



    /**
      * @notice Returns the current number of validators on list
      */
    function getValidatorsLength() public view returns(uint256) {
        address[] memory validatorList = getValidators();
        return validatorList.length;
    }

    /**
    * @notice Checks if address is a current validator on list
    * @param _validator the address to be checked
    */
    function isInValidatorList(address _validator) public view returns(bool) {
        address[] memory validatorList = getValidators();

        for (uint256 i = 0; i < validatorList.length; i++) {
            if(validatorList[i] == _validator) {
                return true;
            }
        }

        return false;
    }

    /**
      * @notice Returns value of current index
      */
    function getValidatorIndex() public view returns(uint256) {
        return uintStorage[VALIDATOR_INDEX];
    }

    /**
      * @notice Get current protocol fee in terms of basis points (1 point = 0.01%)
      */
    function getProtocolFeeBasis() public view returns(uint256) {
        return uintStorage[PROTOCOL_FEE_BASIS];
    }

    /**
    * @notice Returns whether paused or not
    * @dev Focus of pause operation affects only the selective withdraw function 
    *
    * See selective withdrawal: {withdraw(uint256, uint256)}
    * If paused, use default withdrawal method. See {withdraw}
    */
    function isPaused() public view returns (bool) {
        return boolStorage[PAUSE_FLAG_POSITION];
    }

    /**
    * @notice Performs protocol checks before deposits
    */
    function _priorChecks() internal {

        //System max limit check
        uint256 systemMaxStake = IConsensus(consensus()).getMaxStake().mul(getValidatorsLength());
        require(systemTotalStaked().add(msg.value) <= systemMaxStake);

        //Safeguard check, if enabled
        if (isSafeguardLimitEnabled()) {
            require(!isOverLimit(), "SAFEGUARD: OVER_LIMIT");
        }

        //Accepts deposit, activates limit guard
        if (systemTotalStaked().add(msg.value) > systemStakeLimit()) {
            _setOverLimit(true);
        }
        
        //Epoch check
        if (block.timestamp >= lastUpdateTime().add(epochInterval())) {
            _performEpochUpdate();
        }
    }

    /**
    * @notice Determines time pass and updates protocol epoch
    */
    function _performEpochUpdate() internal {

        uint256 currentTime = block.timestamp;
        uint256 prior = lastUpdateTime();
        uint256 epochIncrement = currentTime.sub(prior).div(epochInterval());
        uint256 updatedEpoch = epoch().add(epochIncrement);
        _setEpoch(updatedEpoch);

        uint256 latestCycle = prior.add(epochIncrement.mul(epochInterval()));
        _setLastUpdateTime(latestCycle);

        emit EpochUpdated(updatedEpoch);
    }

    /**
    * @dev Process user deposit, updates and mints liquid tokens
    */
    function _deposit() internal {

        if(systemTotalStaked() != 0) {
            _priorChecks();
            _update();
            _submit(msg.value);

            uint256 newSystemTotal = systemTotalStaked().add(msg.value);
            _setSystemTotalStaked(newSystemTotal);

        } else {
            //handle first ever deposit
            _submit(msg.value);
            _setSystemTotalStaked(msg.value);
        }

        uint256 tokens = msg.value.mul(1e18).div(priceRatio());
        IToken(getSFToken()).mint(msg.sender, tokens);

        emit Deposited(msg.sender, msg.value, tokens);
    }

    /**
    * @notice Delegates funds to staking pool
    */
    function _submit(uint256 _amount) internal {
        _validatorStakeRedistribution(_amount);
    }

    /**
    * @notice Updates rewards, ratio, and restakes reward into network 
    */
    function _update() internal {

        uint256 fbal = address(this).balance.sub(msg.value);

        //The staking rewards fee is defined in basis points (1 basis point is equal to 0.01%, 10000 is 100%).
        uint256 protocolFee = fbal.mul(getProtocolFeeBasis()).div(10000);
        
        uint256 fbalAfterFee = fbal.sub(protocolFee);
        uint256 sfSupply = IERC20(getSFToken()).totalSupply();
        uint256 ratioIncrement = fbalAfterFee.mul(1e18).div(sfSupply);

        uint256 newPriceRatio = priceRatio().add(ratioIncrement);
        _setPriceRatio(newPriceRatio);     

        _submit(fbalAfterFee);
        _distributionByShares(protocolFee);

        uint256 newSystemTotal = systemTotalStaked().add(fbal);
        _setSystemTotalStaked(newSystemTotal);

        emit UpdatedPriceRatio(newPriceRatio, fbalAfterFee, sfSupply);
    }

    /**
    * @dev Tokens are minted to the Treasury corresponding to the protocol fees restaked
    * @param _amount the value amount of the protocol fees 
    */
    function _distributionByShares(uint256 _amount) internal {

        // We need to take a defined percentage of the staking reward as a fee, and we do
        // this by minting new token shares corresponding to the fee portion received
        // The total cost value of the newly-minted token shares exactly corresponds to the fee taken
        // Mints to Treasury in amount based upon the fee and ratio
        uint256 tokens = _amount.mul(1e18).div(priceRatio());
        IToken(getSFToken()).mint(getTreasury(), tokens);

        _validatorStakeRedistribution(_amount);

        emit DistributedProtocolFee(getTreasury(), tokens, _amount, priceRatio());
    }

    /**
    * @notice This handles the pool staking to validators
    * @dev Process the normal delegation of funds and redistribution 
    * @param _amount the value amount to be staked 
    */
    function _validatorStakeRedistribution(uint256 _amount) internal {

        address currentValidator = _getCurrentValidator();
        uint256 validatorDelegatedAmount = IConsensus(consensus()).stakeAmount(currentValidator);
        uint256 availableAmount = IConsensus(consensus()).getMaxStake().sub(validatorDelegatedAmount);
        
        if (availableAmount >= _amount) {
            address payable consensusContract = payable(consensus());
            IConsensus(consensusContract).delegate{value: _amount}(currentValidator);  
        } else {
            address payable consensusContract = payable(consensus());
            IConsensus(consensusContract).delegate{value: availableAmount}(currentValidator);  
            
            uint256 remaining = _amount.sub(availableAmount);

            address[] memory validatorList = getValidators();
            uint256 currentDelegated = 0;
            uint256 currentAvailable = 0;

            for (uint256 i = 0; i < validatorList.length; i++) {

                currentDelegated = IConsensus(consensus()).stakeAmount(validatorList[i]);
                currentAvailable  = IConsensus(consensus()).getMaxStake().sub(currentDelegated);
                
                if (currentAvailable >= remaining) {
                    IConsensus(consensusContract).delegate{value: remaining}(validatorList[i]);
                    _setValidatorIndex(i);

                    break;

                } else {
                    IConsensus(consensusContract).delegate{value: currentAvailable}(validatorList[i]); 
                    
                    remaining = remaining.sub(currentAvailable);
                } 
            }
        }
    }

    /**
    * @dev Sets the value of the exchange rate ratio
    * @param _ratio the value of the ratio
    */
    function _setPriceRatio(uint256 _ratio) internal {
        uintStorage[PRICE_RATIO] = _ratio;
    }

    /**
    * @dev Sets the epoch
    * @param _amount the value of the epoch
    */
    function _setEpoch(uint256 _amount) internal {
        uintStorage[EPOCH] = _amount;
    }

    /**
    * @dev Sets the epoch interval
    * @param _interval the time value of the interval
    */
    function _setEpochInterval(uint256 _interval) internal {
        uintStorage[EPOCH_INTERVAL] = _interval;
    }

    /**
    * @dev Sets the time of update from latest epoch
    * @param _time the time value to be logged
    */
    function _setLastUpdateTime(uint256 _time) internal {
        uintStorage[LAST_UPDATE_TIME] = _time;
    }

    /**
    * @dev Sets the prootocol staking limit
    * @param _limit the new limit amount
    */
    function _setSystemStakeLimit(uint256 _limit) internal {
        uintStorage[SYSTEM_STAKE_LIMIT] = _limit;
    }

    /**
    * @dev Sets the prootocol total staked
    * @param _newTotal the amount of total staked by protocol
    */
    function _setSystemTotalStaked(uint256 _newTotal) internal {
        uintStorage[SYSTEM_TOTAL_STAKED] = _newTotal;
    }

    /**
    * @dev Sets the on or off value for the limit safeguard
    * @param _isEnabled the value indicating whether it is turned on or off
    */
    function _setSafeguardLimitEnabled(bool _isEnabled) internal {
        boolStorage[SAFEGUARD_LIMIT_ENABLED] = _isEnabled;
    }

    /**
    * @dev Sets whether or not the protocol is over its staking limit
    * @param _isOverLimit the value indicating whether it is over the limit or not
    */
    function _setOverLimit(bool _isOverLimit) internal {
        boolStorage[OVER_LIMIT] = _isOverLimit;
    }

    /**
    * @dev Sets the address of Treasury
    * @param _vault the address of the Treasury
    */
    function _setTreasury(address _vault) internal {
        addressStorage[TREASURY] = _vault;
    }

    /**
    * @dev Sets the address of the Consensus Contract
    * @param _consensus the address of the consensus contract
    */
    function _setConsensus(address _consensus) internal {
        addressStorage[CONSENSUS] = _consensus;
    }

    /**
    * @dev Sets the address of the Token Contract
    * @param _token the address of the token contract
    */
    function _setSFToken(address _token) internal {
        addressStorage[SF_TOKEN] = _token;
    }

    /**
    * @dev Adds a new validator to the protocol's list
    * @param _newValidator the address of the new validator
    */
    function _addValidator(address _newValidator) internal {
        addressArrayStorage[VALIDATORS].push(_newValidator);
    }
 
    /**
    * @dev Sets the validator list of the protocol
    * @param _list the list of validator represented by an array of entities
    */
    function _setValidatorList(address[] memory _list) internal {
        addressArrayStorage[VALIDATORS] = _list;
    }

    /**
    * @dev Sets the validator index of the protocol
    * @param _index the value to set the current index to
    */
    function _setValidatorIndex(uint256 _index) internal {
        uintStorage[VALIDATOR_INDEX] = _index;
    }

    /**
    * @dev Sets the protocol's fee 
    * @param _feeBasis the value of the protocol fee percentage expressed in basis points
    */
    function _setProtocolFeeBasis(uint256 _feeBasis) internal {
        uintStorage[PROTOCOL_FEE_BASIS] = _feeBasis;
    }

    /**
    * @dev Set Pause
    * can only be called if not paused
    */
    function _pause() internal whenNotStopped {
        boolStorage[PAUSE_FLAG_POSITION] = true;
    }

    /**
    * @dev Set Unpause
    * can only be called if currently paused
    */
    function _unpause() internal whenStopped {
        boolStorage[PAUSE_FLAG_POSITION] = false;
    }

    /**
    * @dev Gets the validator address at a certain position
    * @param _position the index value to look up
    */
    function _getValidatorAt(uint256 _position) internal view returns(address) {
        address[] memory list = getValidators();

        return list[_position];
    }

    /**
    * @dev Gets the validator address corresponding to current index
    */
    function _getCurrentValidator() internal view returns(address) {
        address[] memory list = getValidators();
        uint256 index = getValidatorIndex();

        return list[index];
    }
}