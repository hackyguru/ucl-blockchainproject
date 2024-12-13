// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@worldcoin/world-id-contracts/src/interfaces/IWorldID.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title DatingProtocol
 * @dev A decentralized dating protocol with questionnaire-based matching
 */
contract DatingProtocol is Ownable, ReentrancyGuard {
    using ECDSA for bytes32;

    // Constants
    uint256 public constant QUESTIONS_COUNT = 10;
    uint256 public constant WEEKLY_STAKE_AMOUNT = 1 ether; // 1 token
    uint256 public constant MATCHING_INTERVAL = 7 days;
    uint256 public constant TEAM_SHARE = 20;
    uint256 public constant REWARDS_SHARE = 30;
    uint256 public constant TREASURY_SHARE = 50;

    // Worldcoin integration
    IWorldID public worldId;
    uint256 public immutable externalNullifier;
    mapping(address => bool) public verifiedUsers;
    
    // User profile structure
    struct UserProfile {
        string ipfsHash;  // Encrypted profile data hash
        bool isActive;
        uint256 reputationScore;
        uint256 lastUpdateTime;
        string publicKey;  // For encrypted messaging
        bool[] answers;    // User's answers to questions (yes/no)
        bool[] preferences; // User's preferred partner answers
        uint256 lastMatchTime; // Last time user was matched
        bool isStaked;     // Whether user has staked for current week
        uint256 stakeExpiry; // When current stake expires
    }

    // Match structure
    struct Match {
        address user1;
        address user2;
        uint256 timestamp;
        uint256 compatibilityScore;
        bool active;
    }

    // State variables
    mapping(address => UserProfile) public profiles;
    mapping(bytes32 => Match) public matches;
    mapping(address => address[]) public userMatches;
    mapping(address => uint256) public userStakes;
    
    // Weekly matching queue
    address[] public matchingQueue;
    uint256 public lastMatchingTime;
    
    // Platform token
    IERC20 public governanceToken;
    
    // Events
    event ProfileCreated(address indexed user, string ipfsHash);
    event ProfileUpdated(address indexed user, string newIpfsHash);
    event MatchCreated(address indexed user1, address indexed user2, uint256 compatibilityScore);
    event UserVerified(address indexed user, bool worldcoin, bool privy);
    event StakeUpdated(address indexed user, uint256 amount, uint256 expiry);
    event WeeklyMatchingCompleted(uint256 matchesCount);
    event FeesDistributed(uint256 teamAmount, uint256 rewardsAmount, uint256 treasuryAmount);

    // Treasury addresses
    address public teamWallet;
    address public rewardsPool;
    address public treasuryWallet;

    constructor(
        address _worldId,
        uint256 _externalNullifier,
        address _governanceToken
    ) {
        require(_worldId != address(0), "Invalid WorldID address");
        require(_governanceToken != address(0), "Invalid token address");
        
        worldId = IWorldID(_worldId);
        externalNullifier = _externalNullifier;
        governanceToken = IERC20(_governanceToken);
        lastMatchingTime = block.timestamp;
    }

    /**
     * @dev Verify user with WorldID
     */
    function verifyWithWorldID(
        uint256 root,
        uint256 groupId,
        uint256 signalHash,
        uint256 nullifierHash,
        uint256[8] calldata proof
    ) external {
        bytes memory signal = abi.encode(msg.sender);
        
        worldId.verifyProof(
            root,
            groupId,
            abi.encode(signal),
            signalHash,
            nullifierHash,
            proof
        );
        verifiedUsers[msg.sender] = true;
        emit UserVerified(msg.sender, true, false);
    }

    /**
     * @dev Create or update user profile with questionnaire answers
     */
    function createProfile(
        string memory _ipfsHash,
        string memory _publicKey,
        bool[] memory _answers,
        bool[] memory _preferences
    ) external nonReentrant {
        require(_answers.length == QUESTIONS_COUNT, "Invalid answers count");
        require(_preferences.length == QUESTIONS_COUNT, "Invalid preferences count");
        require(bytes(_ipfsHash).length > 0, "Invalid IPFS hash");
        require(bytes(_publicKey).length > 0, "Invalid public key");
        
        if (!profiles[msg.sender].isActive) {
            profiles[msg.sender] = UserProfile({
                ipfsHash: _ipfsHash,
                isActive: true,
                reputationScore: 100,
                lastUpdateTime: block.timestamp,
                publicKey: _publicKey,
                answers: new bool[](0),
                preferences: new bool[](0),
                lastMatchTime: 0,
                isStaked: false,
                stakeExpiry: 0
            });
            emit ProfileCreated(msg.sender, _ipfsHash);
        }

        UserProfile storage profile = profiles[msg.sender];
        profile.answers = _answers;
        profile.preferences = _preferences;
        profile.ipfsHash = _ipfsHash;
        profile.publicKey = _publicKey;
        profile.lastUpdateTime = block.timestamp;

        emit ProfileUpdated(msg.sender, _ipfsHash);
    }

    /**
     * @dev Stake tokens for weekly matching
     */
    function stakeForMatching() external nonReentrant {
        require(profiles[msg.sender].isActive, "Profile not active");
        require(!profiles[msg.sender].isStaked, "Already staked");
        
        governanceToken.transferFrom(msg.sender, address(this), WEEKLY_STAKE_AMOUNT);
        
        profiles[msg.sender].isStaked = true;
        profiles[msg.sender].stakeExpiry = block.timestamp + MATCHING_INTERVAL;
        matchingQueue.push(msg.sender);
        
        emit StakeUpdated(msg.sender, WEEKLY_STAKE_AMOUNT, profiles[msg.sender].stakeExpiry);
    }

    /**
     * @dev Calculate compatibility score between two users
     */
    function calculateCompatibility(address user1, address user2) public view returns (uint256) {
        require(profiles[user1].isActive && profiles[user2].isActive, "Invalid users");
        
        UserProfile storage profile1 = profiles[user1];
        UserProfile storage profile2 = profiles[user2];
        
        uint256 score = 0;
        for (uint256 i = 0; i < QUESTIONS_COUNT; i++) {
            if (profile1.answers[i] == profile2.preferences[i]) {
                score += 1;
            }
            if (profile2.answers[i] == profile1.preferences[i]) {
                score += 1;
            }
        }
        
        return (score * 100) / (QUESTIONS_COUNT * 2);
    }

    /**
     * @dev Execute weekly matching process
     */
    function executeWeeklyMatching() external onlyOwner nonReentrant {
        require(block.timestamp >= lastMatchingTime + MATCHING_INTERVAL, "Too early");
        
        uint256 matchesCount = 0;
        uint256 queueLength = matchingQueue.length;
        
        // Clear expired stakes and create a temporary array of valid users
        address[] memory validUsers = new address[](queueLength);
        uint256 validCount = 0;
        
        for (uint256 i = 0; i < queueLength; i++) {
            address user = matchingQueue[i];
            if (block.timestamp <= profiles[user].stakeExpiry) {
                validUsers[validCount] = user;
                validCount++;
            } else {
                profiles[user].isStaked = false;
            }
        }
        
        // Clear the matching queue
        delete matchingQueue;
        
        // Match valid users
        for (uint256 i = 0; i < validCount; i++) {
            for (uint256 j = i + 1; j < validCount; j++) {
                address user1 = validUsers[i];
                address user2 = validUsers[j];
                
                if (profiles[user1].isStaked && profiles[user2].isStaked) {
                    uint256 compatibilityScore = calculateCompatibility(user1, user2);
                    
                    bytes32 matchId = keccak256(abi.encodePacked(user1, user2, block.timestamp));
                    matches[matchId] = Match({
                        user1: user1,
                        user2: user2,
                        timestamp: block.timestamp,
                        compatibilityScore: compatibilityScore,
                        active: true
                    });
                    
                    userMatches[user1].push(user2);
                    userMatches[user2].push(user1);
                    
                    profiles[user1].isStaked = false;
                    profiles[user2].isStaked = false;
                    
                    emit MatchCreated(user1, user2, compatibilityScore);
                    matchesCount++;
                }
            }
        }
        
        lastMatchingTime = block.timestamp;
        emit WeeklyMatchingCompleted(matchesCount);
    }

    /**
     * @dev Set treasury addresses for fee distribution
     */
    function setTreasuryAddresses(
        address _teamWallet,
        address _rewardsPool,
        address _treasuryWallet
    ) external onlyOwner {
        require(_teamWallet != address(0), "Invalid team wallet");
        require(_rewardsPool != address(0), "Invalid rewards pool");
        require(_treasuryWallet != address(0), "Invalid treasury wallet");
        
        teamWallet = _teamWallet;
        rewardsPool = _rewardsPool;
        treasuryWallet = _treasuryWallet;
    }

    /**
     * @dev Withdraw and distribute accumulated fees
     */
    function withdrawFees() external nonReentrant {
        uint256 balance = governanceToken.balanceOf(address(this));
        require(balance > 0, "No fees to withdraw");
        require(teamWallet != address(0) && rewardsPool != address(0) && treasuryWallet != address(0), 
                "Treasury addresses not set");

        uint256 teamShare = (balance * TEAM_SHARE) / 100;
        uint256 rewardsShare = (balance * REWARDS_SHARE) / 100;
        uint256 treasuryShare = (balance * TREASURY_SHARE) / 100;

        require(governanceToken.transfer(teamWallet, teamShare), "Team transfer failed");
        require(governanceToken.transfer(rewardsPool, rewardsShare), "Rewards transfer failed");
        require(governanceToken.transfer(treasuryWallet, treasuryShare), "Treasury transfer failed");

        emit FeesDistributed(teamShare, rewardsShare, treasuryShare);
    }

    /**
     * @dev Get user's profile data
     */
    function getProfile(address _user) external view returns (
        string memory ipfsHash,
        bool isActive,
        uint256 reputationScore,
        uint256 lastUpdateTime,
        string memory publicKey,
        bool[] memory answers,
        bool[] memory preferences,
        bool isStaked,
        uint256 stakeExpiry
    ) {
        UserProfile storage profile = profiles[_user];
        return (
            profile.ipfsHash,
            profile.isActive,
            profile.reputationScore,
            profile.lastUpdateTime,
            profile.publicKey,
            profile.answers,
            profile.preferences,
            profile.isStaked,
            profile.stakeExpiry
        );
    }

    /**
     * @dev Get user's matches
     */
    function getUserMatches(address _user) external view returns (address[] memory) {
        return userMatches[_user];
    }

    /**
     * @dev Get matching queue length
     */
    function getQueueLength() external view returns (uint256) {
        return matchingQueue.length;
    }
} 