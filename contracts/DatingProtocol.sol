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

    constructor(
        address _worldId,
        uint256 _externalNullifier,
        address _governanceToken
    ) {
        worldId = IWorldID(_worldId);
        externalNullifier = _externalNullifier;
        governanceToken = IERC20(_governanceToken);
        lastMatchingTime = block.timestamp;
    }

    /**
     * @dev Create or update user profile with questionnaire answers
     * @param _ipfsHash IPFS hash of encrypted profile data
     * @param _publicKey Public key for encrypted messaging
     * @param _answers User's answers to questions
     * @param _preferences User's preferred partner answers
     */
    function createProfile(
        string memory _ipfsHash,
        string memory _publicKey,
        bool[] memory _answers,
        bool[] memory _preferences
    ) external nonReentrant {
        require(_answers.length == QUESTIONS_COUNT, "Invalid answers count");
        require(_preferences.length == QUESTIONS_COUNT, "Invalid preferences count");
        
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
        UserProfile storage profile1 = profiles[user1];
        UserProfile storage profile2 = profiles[user2];
        
        uint256 score = 0;
        for (uint256 i = 0; i < QUESTIONS_COUNT; i++) {
            // Check if user1's answers match user2's preferences
            if (profile1.answers[i] == profile2.preferences[i]) {
                score += 1;
            }
            // Check if user2's answers match user1's preferences
            if (profile2.answers[i] == profile1.preferences[i]) {
                score += 1;
            }
        }
        
        // Score is out of 20 (10 questions * 2 directions)
        return (score * 100) / (QUESTIONS_COUNT * 2);
    }

    /**
     * @dev Execute weekly matching process
     */
    function executeWeeklyMatching() external onlyOwner {
        require(block.timestamp >= lastMatchingTime + MATCHING_INTERVAL, "Too early");
        
        // Clear expired stakes
        for (uint256 i = matchingQueue.length; i > 0; i--) {
            address user = matchingQueue[i - 1];
            if (block.timestamp > profiles[user].stakeExpiry) {
                profiles[user].isStaked = false;
                // Remove from queue by swapping with last element and popping
                matchingQueue[i - 1] = matchingQueue[matchingQueue.length - 1];
                matchingQueue.pop();
            }
        }
        
        // Match users
        uint256 matchesCount = 0;
        while (matchingQueue.length >= 2) {
            address bestMatch1;
            address bestMatch2;
            uint256 highestScore = 0;
            
            // Find best matching pair
            for (uint256 i = 0; i < matchingQueue.length; i++) {
                for (uint256 j = i + 1; j < matchingQueue.length; j++) {
                    uint256 score = calculateCompatibility(matchingQueue[i], matchingQueue[j]);
                    if (score > highestScore) {
                        highestScore = score;
                        bestMatch1 = matchingQueue[i];
                        bestMatch2 = matchingQueue[j];
                    }
                }
            }
            
            if (bestMatch1 != address(0) && bestMatch2 != address(0)) {
                // Create match
                bytes32 matchId = keccak256(abi.encodePacked(bestMatch1, bestMatch2, block.timestamp));
                matches[matchId] = Match({
                    user1: bestMatch1,
                    user2: bestMatch2,
                    timestamp: block.timestamp,
                    compatibilityScore: highestScore,
                    active: true
                });
                
                userMatches[bestMatch1].push(bestMatch2);
                userMatches[bestMatch2].push(bestMatch1);
                
                // Remove matched users from queue
                removeFromQueue(bestMatch1);
                removeFromQueue(bestMatch2);
                
                emit MatchCreated(bestMatch1, bestMatch2, highestScore);
                matchesCount++;
            }
        }
        
        lastMatchingTime = block.timestamp;
        emit WeeklyMatchingCompleted(matchesCount);
    }

    /**
     * @dev Remove user from matching queue
     */
    function removeFromQueue(address user) internal {
        for (uint256 i = 0; i < matchingQueue.length; i++) {
            if (matchingQueue[i] == user) {
                matchingQueue[i] = matchingQueue[matchingQueue.length - 1];
                matchingQueue.pop();
                break;
            }
        }
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

    /**
     * @dev Withdraw accumulated fees
     */
    function withdrawFees() external onlyOwner {
        uint256 balance = governanceToken.balanceOf(address(this));
        require(balance > 0, "No fees to withdraw");
        governanceToken.transfer(owner(), balance);
    }
} 