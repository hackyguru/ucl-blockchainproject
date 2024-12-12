// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DatingGovernanceToken
 * @dev Governance token for the dating protocol with voting capabilities and weekly matching stakes
 */
contract DatingGovernanceToken is ERC20, ERC20Votes, Ownable {
    uint256 public constant INITIAL_SUPPLY = 100_000_000 * 10**18; // 100 million tokens
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18; // 1 billion tokens
    
    // Emission rate: 2% per year
    uint256 public constant EMISSION_RATE = 2;
    uint256 public constant WEEKLY_STAKE_BONUS = 5; // 5% bonus for weekly staking
    uint256 public lastEmissionTime;
    
    // Protocol address
    address public datingProtocol;
    
    // Staking rewards
    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public stakingTimestamp;
    mapping(address => uint256) public weeklyStakeCount; // Track consecutive weekly stakes
    
    // Events
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event WeeklyStakeBonus(address indexed user, uint256 amount);
    event ProtocolAddressUpdated(address indexed newProtocol);

    constructor() ERC20("Dating Governance Token", "DATE") ERC20Permit("Dating Governance Token") {
        _mint(msg.sender, INITIAL_SUPPLY);
        lastEmissionTime = block.timestamp;
    }

    /**
     * @dev Set the protocol address
     * @param _protocol Address of the dating protocol
     */
    function setProtocolAddress(address _protocol) external onlyOwner {
        require(_protocol != address(0), "Invalid protocol address");
        datingProtocol = _protocol;
        emit ProtocolAddressUpdated(_protocol);
    }

    /**
     * @dev Stake tokens for governance participation
     * @param amount Amount of tokens to stake
     */
    function stake(uint256 amount) external {
        require(amount > 0, "Cannot stake 0 tokens");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        _transfer(msg.sender, address(this), amount);
        
        if (stakedBalance[msg.sender] > 0) {
            claimRewards();
        }
        
        stakedBalance[msg.sender] += amount;
        stakingTimestamp[msg.sender] = block.timestamp;
        
        emit Staked(msg.sender, amount);
    }

    /**
     * @dev Unstake tokens
     * @param amount Amount of tokens to unstake
     */
    function unstake(uint256 amount) external {
        require(amount > 0, "Cannot unstake 0 tokens");
        require(stakedBalance[msg.sender] >= amount, "Insufficient staked balance");
        
        claimRewards();
        stakedBalance[msg.sender] -= amount;
        _transfer(address(this), msg.sender, amount);
        
        emit Unstaked(msg.sender, amount);
    }

    /**
     * @dev Calculate weekly stake bonus
     * @param user Address of the user
     */
    function calculateWeeklyBonus(address user) public view returns (uint256) {
        if (weeklyStakeCount[user] == 0) return 0;
        
        uint256 baseBonus = (stakedBalance[user] * WEEKLY_STAKE_BONUS) / 100;
        uint256 multiplier = weeklyStakeCount[user] > 52 ? 52 : weeklyStakeCount[user];
        return (baseBonus * multiplier) / 52;
    }

    /**
     * @dev Claim staking rewards including weekly bonus
     */
    function claimRewards() public {
        uint256 rewards = calculateRewards(msg.sender);
        uint256 weeklyBonus = calculateWeeklyBonus(msg.sender);
        uint256 totalRewards = rewards + weeklyBonus;
        
        if (totalRewards > 0) {
            require(totalSupply() + totalRewards <= MAX_SUPPLY, "Max supply exceeded");
            _mint(msg.sender, totalRewards);
            stakingTimestamp[msg.sender] = block.timestamp;
            
            emit RewardsClaimed(msg.sender, rewards);
            if (weeklyBonus > 0) {
                emit WeeklyStakeBonus(msg.sender, weeklyBonus);
            }
        }
    }

    /**
     * @dev Calculate staking rewards for a user
     * @param user Address of the user
     */
    function calculateRewards(address user) public view returns (uint256) {
        if (stakedBalance[user] == 0) {
            return 0;
        }
        
        uint256 timeStaked = block.timestamp - stakingTimestamp[user];
        uint256 rewardRate = (EMISSION_RATE * 10**18) / (365 days);
        return (stakedBalance[user] * rewardRate * timeStaked) / 10**18;
    }

    /**
     * @dev Update weekly stake count for a user
     * @param user Address of the user
     */
    function updateWeeklyStakeCount(address user) external {
        require(msg.sender == datingProtocol, "Only protocol can update");
        weeklyStakeCount[user]++;
    }

    /**
     * @dev Reset weekly stake count for a user
     * @param user Address of the user
     */
    function resetWeeklyStakeCount(address user) external {
        require(msg.sender == datingProtocol, "Only protocol can update");
        weeklyStakeCount[user] = 0;
    }

    /**
     * @dev Get current voting power of an account
     * @param account Address of the account
     */
    function getVotes(address account) public view override returns (uint256) {
        return stakedBalance[account];
    }

    // Required overrides
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Votes) {
        super._afterTokenTransfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._mint(to, amount);
    }

    function _burn(address account, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._burn(account, amount);
    }
} 