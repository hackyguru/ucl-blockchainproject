// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@worldcoin/world-id-contracts/src/interfaces/IWorldID.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title DatingProtocol
 * @dev A decentralized dating protocol that ensures user authenticity and privacy
 */
contract DatingProtocol is Ownable, ReentrancyGuard {
    using ECDSA for bytes32;

    // Worldcoin integration
    IWorldID public worldId;
    uint256 public immutable externalNullifier;
    mapping(address => bool) public verifiedUsers;
    
    // IPFS data structure
    struct UserProfile {
        string ipfsHash;  // Encrypted profile data hash
        bool isActive;
        uint256 reputationScore;
        uint256 lastUpdateTime;
        string publicKey;  // For encrypted messaging
    }

    // User verification status
    struct VerificationStatus {
        bool worldcoinVerified;
        bool privyVerified;
        uint256 verificationTimestamp;
    }

    // Matching and interaction structures
    struct Match {
        address user1;
        address user2;
        uint256 timestamp;
        bool active;
    }

    // State variables
    mapping(address => UserProfile) public profiles;
    mapping(address => VerificationStatus) public verificationStatus;
    mapping(bytes32 => Match) public matches;
    mapping(address => address[]) public userMatches;
    
    // Platform economics
    uint256 public profileCreationFee;
    uint256 public matchingFee;
    IERC20 public governanceToken;
    
    // Events
    event ProfileCreated(address indexed user, string ipfsHash);
    event ProfileUpdated(address indexed user, string newIpfsHash);
    event MatchCreated(address indexed user1, address indexed user2);
    event UserVerified(address indexed user, bool worldcoin, bool privy);
    event ReputationUpdated(address indexed user, uint256 newScore);

    // Modifiers
    modifier onlyVerifiedUser() {
        require(verificationStatus[msg.sender].worldcoinVerified, "User not verified with Worldcoin");
        require(verificationStatus[msg.sender].privyVerified, "User not verified with Privy");
        _;
    }

    constructor(
        address _worldId,
        uint256 _externalNullifier,
        address _governanceToken,
        uint256 _profileCreationFee,
        uint256 _matchingFee
    ) {
        worldId = IWorldID(_worldId);
        externalNullifier = _externalNullifier;
        governanceToken = IERC20(_governanceToken);
        profileCreationFee = _profileCreationFee;
        matchingFee = _matchingFee;
    }

    /**
     * @dev Create a new user profile
     * @param _ipfsHash IPFS hash of encrypted profile data
     * @param _publicKey Public key for encrypted messaging
     */
    function createProfile(
        string memory _ipfsHash,
        string memory _publicKey
    ) external payable nonReentrant {
        require(msg.value >= profileCreationFee, "Insufficient profile creation fee");
        require(!profiles[msg.sender].isActive, "Profile already exists");
        
        profiles[msg.sender] = UserProfile({
            ipfsHash: _ipfsHash,
            isActive: true,
            reputationScore: 100,
            lastUpdateTime: block.timestamp,
            publicKey: _publicKey
        });

        emit ProfileCreated(msg.sender, _ipfsHash);
    }

    /**
     * @dev Verify user with Worldcoin
     * @param signal User's signal for verification
     * @param root Root of the Merkle tree
     * @param nullifierHash Hash to prevent double signaling
     * @param proof Zero-knowledge proof
     */
    function verifyWithWorldcoin(
        address signal,
        uint256 root,
        uint256 nullifierHash,
        uint256[8] calldata proof
    ) external {
        worldId.verifyProof(
            root,
            externalNullifier,
            uint256(uint160(signal)),
            nullifierHash,
            proof
        );
        
        verificationStatus[msg.sender].worldcoinVerified = true;
        verificationStatus[msg.sender].verificationTimestamp = block.timestamp;
        
        emit UserVerified(msg.sender, true, verificationStatus[msg.sender].privyVerified);
    }

    /**
     * @dev Update user's Privy verification status
     * @param _user User address
     * @param _signature Signed message from Privy
     */
    function updatePrivyVerification(
        address _user,
        bytes memory _signature
    ) external {
        bytes32 messageHash = keccak256(abi.encodePacked(_user, "PRIVY_VERIFIED"));
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedMessageHash.recover(_signature);
        
        require(signer == owner(), "Invalid signature");
        
        verificationStatus[_user].privyVerified = true;
        emit UserVerified(_user, verificationStatus[_user].worldcoinVerified, true);
    }

    /**
     * @dev Create a match between two users
     * @param _user2 Address of the second user
     */
    function createMatch(address _user2) external payable onlyVerifiedUser nonReentrant {
        require(msg.value >= matchingFee, "Insufficient matching fee");
        require(profiles[msg.sender].isActive && profiles[_user2].isActive, "Invalid users");
        
        bytes32 matchId = keccak256(abi.encodePacked(msg.sender, _user2, block.timestamp));
        matches[matchId] = Match({
            user1: msg.sender,
            user2: _user2,
            timestamp: block.timestamp,
            active: true
        });

        userMatches[msg.sender].push(_user2);
        userMatches[_user2].push(msg.sender);

        emit MatchCreated(msg.sender, _user2);
    }

    /**
     * @dev Update user's reputation score
     * @param _user User address
     * @param _score New reputation score
     */
    function updateReputation(address _user, uint256 _score) external onlyOwner {
        require(_score <= 100, "Score must be <= 100");
        profiles[_user].reputationScore = _score;
        emit ReputationUpdated(_user, _score);
    }

    /**
     * @dev Get user's profile data
     * @param _user User address
     */
    function getProfile(address _user) external view returns (
        string memory ipfsHash,
        bool isActive,
        uint256 reputationScore,
        uint256 lastUpdateTime,
        string memory publicKey
    ) {
        UserProfile memory profile = profiles[_user];
        return (
            profile.ipfsHash,
            profile.isActive,
            profile.reputationScore,
            profile.lastUpdateTime,
            profile.publicKey
        );
    }

    /**
     * @dev Update platform fees
     * @param _newProfileFee New profile creation fee
     * @param _newMatchingFee New matching fee
     */
    function updateFees(uint256 _newProfileFee, uint256 _newMatchingFee) external onlyOwner {
        profileCreationFee = _newProfileFee;
        matchingFee = _newMatchingFee;
    }

    /**
     * @dev Withdraw platform fees
     * @param _to Address to send fees to
     */
    function withdrawFees(address payable _to) external onlyOwner {
        uint256 balance = address(this).balance;
        (bool success, ) = _to.call{value: balance}("");
        require(success, "Transfer failed");
    }
} 