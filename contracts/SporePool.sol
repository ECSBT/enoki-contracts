// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/math/Math.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

import "./Defensible.sol";
import "./interfaces/IMushroomFactory.sol";
import "./interfaces/IMission.sol";
import "./interfaces/IMiniMe.sol";
import "./interfaces/ISporeToken.sol";
import "./BannedContractList.sol";

/*
    Staking can be paused by the owner (withdrawing & harvesting cannot be paused)
    
    The mushroomFactory must be set by the owner before mushrooms can be harvested (optionally)
    It and can be modified, to use new mushroom spawning logic

    The rateVote contract has control over the spore emission rate. 
    It can be modified, to change the voting logic around rate changes.
*/
contract SporePool is OwnableUpgradeSafe, ReentrancyGuardUpgradeSafe, PausableUpgradeSafe, Defensible {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    ISporeToken public sporeToken;
    IERC20 public stakingToken;
    uint256 public sporesPerSecond = 0;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    uint256 public constant MAX_PERCENTAGE = 100;
    uint256 public devRewardPercentage;
    address public devRewardAddress;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    mapping(address => uint256) public startOfStake;
    mapping(address => uint256) public endOfStake;
    mapping(address => uint256) public totalStaked;

    uint256 internal _totalSupply;
    mapping(address => uint256) internal _balances;

    IMushroomFactory public mushroomFactory;
    IMission public mission;
    BannedContractList public bannedContractList;

    uint256 public stakingEnabledTime;

    uint256 public yieldCap = 5184000; //60 days in seconds
    uint256 public weightDefault = 100; //representatvie of percent

    address public rateVote;

    IMiniMe public enokiToken;
    address public enokiDaoAgent;

    /* ========== CONSTRUCTOR ========== */

    function initialize(
        address _sporeToken,
        address _stakingToken,
        address _mission,
        address _bannedContractList,
        address _devRewardAddress,
        address _enokiDaoAgent,
        uint256[3] memory uintParams
    ) public virtual initializer {
        __Context_init_unchained();
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();
        __Ownable_init_unchained();

        sporeToken = ISporeToken(_sporeToken);
        stakingToken = IERC20(_stakingToken);

        mission = IMission(_mission);
        bannedContractList = BannedContractList(_bannedContractList);

        /*
            [0] uint256 _devRewardPercentage,
            [1] uint256 stakingEnabledTime_,
            [2] uint256 initialRewardRate_,
        */

        devRewardPercentage = uintParams[0];
        devRewardAddress = _devRewardAddress;

        stakingEnabledTime = uintParams[1];
        sporesPerSecond = uintParams[2];

        enokiDaoAgent = _enokiDaoAgent;

        emit SporeRateChange(sporesPerSecond);
    }

    /* ========== VIEWS ========== */

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    // Rewards are turned off at the mission level
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp;
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }

        // Time difference * sporesPerSecond
        return rewardPerTokenStored.add(lastTimeRewardApplicable().sub(lastUpdateTime).mul(sporesPerSecond).mul(1e18).div(_totalSupply));
    }

    function earned(address account) public view returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount) external virtual nonReentrant defend(bannedContractList) whenNotPaused updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        require(now > stakingEnabledTime, "Cannot stake before staking enabled");
        if (endOfStake[msg.sender] > 0) {
            require(now < endOfStake[msg.sender], "Cannot stake at the end of a staking period");
        }
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        totalStaked[msg.sender] = totalStaked[msg.sender].add(amount);
        uint256 stakeWeight = amount.mul(100).div(totalStaked[msg.sender]);
        uint256 stakeHeight = weightDefault.sub(stakeWeight);
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        if (startOfStake[msg.sender] > 0) {
            uint256 heightOfStart = startOfStake[msg.sender].div(100).mul(stakeHeight);
            uint256 newStart = lastTimeRewardApplicable();
            uint256 weightOfStart = newStart.div(100).mul(stakeWeight);
            startOfStake[msg.sender] = heightOfStart.add(weightOfStart);
        } else {
            startOfStake[msg.sender] = lastTimeRewardApplicable();
        }

        if (endOfStake[msg.sender] > 0) {
            uint256 heightOfEnd = endOfStake[msg.sender].div(100).mul(stakeHeight);
            uint256 newEnd = startOfStake[msg.sender].add(yieldCap);
            uint256 weightOfEnd = newEnd.div(100).mul(stakeWeight);
            endOfStake[msg.sender] = heightOfEnd.add(weightOfEnd);
        } else {
            endOfStake[msg.sender] = startOfStake[msg.sender].add(yieldCap);
        }

        emit Staked(msg.sender, amount, endOfStake[msg.sender]);
    }

    // Withdrawing does not harvest, the rewards must be harvested separately
    function withdraw(uint256 amount) public virtual updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Redeem collected spore for mushrooms. Spore can no longer be withdrawn directly, only redeemed for mushrooms.
    function harvest(uint256 mushroomsToGrow)
        public
        nonReentrant
        updateReward(msg.sender)
        returns (
            uint256 toDev,
            uint256 toDao,
            uint256 remainingReward
        )
    {
        uint256 reward = rewards[msg.sender];

        require(reward > 0, "No harvestable reward");
        //require(mushroomsToGrow > 0, "Must harvest at least one mushroom");

        remainingReward = reward;
        toDev = 0;
        toDao = 0;

        // Burn some rewards for mushrooms if desired
        uint256 totalCost = mushroomFactory.costPerMushroom().mul(mushroomsToGrow);

        require(reward >= totalCost, "Not enough rewards to grow the number of mushrooms specified");

        toDev = totalCost.mul(devRewardPercentage).div(MAX_PERCENTAGE);

        if (toDev > 0) {
            mission.sendSpores(devRewardAddress, toDev);
            emit DevRewardPaid(devRewardAddress, toDev);
        }

        toDao = totalCost.sub(toDev);

        mission.sendSpores(enokiDaoAgent, toDao);
        emit DaoRewardPaid(enokiDaoAgent, toDao);

        remainingReward = reward.sub(totalCost);
        mushroomFactory.growMushrooms(msg.sender, mushroomsToGrow);
        emit MushroomsGrown(msg.sender, mushroomsToGrow);

        // Return remaining spore to user

        uint256 remainingReturn = remainingReward.mul(1e18);
        stakingToken.safeTransfer(msg.sender, remainingReturn);
        rewards[msg.sender] = rewards[msg.sender].sub(totalCost).sub(remainingReward);
        emit ReturnReward(msg.sender, remainingReturn);
    }

    // Withdraw, forfietting all rewards
    function emergencyWithdraw() external nonReentrant {
        withdraw(_balances[msg.sender]);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        // Cannot recover the staking token or the rewards token
        require(tokenAddress != address(stakingToken) && tokenAddress != address(sporeToken), "Cannot withdraw the staking or rewards tokens");

        //TODO: Add safeTransfer
        IERC20(tokenAddress).transfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setMushroomFactory(address mushroomFactory_) external onlyOwner {
        mushroomFactory = IMushroomFactory(mushroomFactory_);
    }

    function pauseStaking() external onlyOwner {
        _pause();
    }

    function unpauseStaking() external onlyOwner {
        _unpause();
    }

    function setRateVote(address _rateVote) external onlyOwner {
        rateVote = _rateVote;
    }

    function changeRate(uint256 percentage) external onlyRateVote {
        sporesPerSecond = sporesPerSecond.mul(percentage).div(MAX_PERCENTAGE);
        emit SporeRateChange(sporesPerSecond);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0) && endOfStake[account] > lastUpdateTime) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    modifier onlyRateVote() {
        require(msg.sender == rateVote, "onlyRateVote");
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount, uint256 end);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event ReturnReward(address indexed user, uint256 amount);
    event DevRewardPaid(address indexed user, uint256 reward);
    event DaoRewardPaid(address indexed user, uint256 reward);
    event MushroomsGrown(address indexed user, uint256 number);
    event Recovered(address token, uint256 amount);
    event SporeRateChange(uint256 newRate);
}
