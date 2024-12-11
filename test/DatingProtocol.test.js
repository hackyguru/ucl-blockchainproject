const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Dating Protocol", function () {
  let DatingProtocol;
  let DatingGovernanceToken;
  let DatingGovernance;
  let datingProtocol;
  let datingToken;
  let datingGovernance;
  let owner;
  let user1;
  let user2;
  let worldcoinMock;
  let timelock;

  const INITIAL_SUPPLY = ethers.utils.parseEther("100000000"); // 100M tokens
  const PROFILE_FEE = ethers.utils.parseEther("0.01"); // 0.01 ETH
  const MATCHING_FEE = ethers.utils.parseEther("0.001"); // 0.001 ETH

  beforeEach(async function () {
    // Get signers
    [owner, user1, user2] = await ethers.getSigners();

    // Deploy mock WorldID contract
    const WorldIDMock = await ethers.getContractFactory("WorldIDMock");
    worldcoinMock = await WorldIDMock.deploy();
    await worldcoinMock.deployed();

    // Deploy governance token
    const DatingGovernanceToken = await ethers.getContractFactory("DatingGovernanceToken");
    datingToken = await DatingGovernanceToken.deploy();
    await datingToken.deployed();

    // Deploy timelock
    const TimelockController = await ethers.getContractFactory("TimelockController");
    timelock = await TimelockController.deploy(
      1, // Minimum delay
      [owner.address], // Proposers
      [owner.address], // Executors
      owner.address // Admin
    );
    await timelock.deployed();

    // Deploy governance contract
    const DatingGovernance = await ethers.getContractFactory("DatingGovernance");
    datingGovernance = await DatingGovernance.deploy(
      datingToken.address,
      timelock.address,
      1, // 1 block voting delay
      5760, // ~1 day voting period
      ethers.utils.parseEther("100000"), // 100k tokens for proposal threshold
      4 // 4% quorum
    );
    await datingGovernance.deployed();

    // Deploy main protocol
    const DatingProtocol = await ethers.getContractFactory("DatingProtocol");
    datingProtocol = await DatingProtocol.deploy(
      worldcoinMock.address,
      ethers.utils.formatBytes32String("dating_app"),
      datingToken.address,
      PROFILE_FEE,
      MATCHING_FEE
    );
    await datingProtocol.deployed();
  });

  describe("Profile Management", function () {
    it("Should create a profile with correct fee", async function () {
      const ipfsHash = "QmTest123";
      const publicKey = "0x123456789";

      await expect(
        datingProtocol.connect(user1).createProfile(ipfsHash, publicKey, {
          value: PROFILE_FEE
        })
      )
        .to.emit(datingProtocol, "ProfileCreated")
        .withArgs(user1.address, ipfsHash);

      const profile = await datingProtocol.getProfile(user1.address);
      expect(profile.ipfsHash).to.equal(ipfsHash);
      expect(profile.isActive).to.be.true;
      expect(profile.reputationScore).to.equal(100);
      expect(profile.publicKey).to.equal(publicKey);
    });

    it("Should fail to create profile with insufficient fee", async function () {
      await expect(
        datingProtocol.connect(user1).createProfile(
          "QmTest123",
          "0x123456789",
          {
            value: ethers.utils.parseEther("0.005") // Less than required fee
          }
        )
      ).to.be.revertedWith("Insufficient profile creation fee");
    });
  });

  describe("Verification", function () {
    it("Should verify user with Worldcoin", async function () {
      const signal = user1.address;
      const root = 123;
      const nullifierHash = 456;
      const proof = Array(8).fill(789);

      await expect(
        datingProtocol.connect(user1).verifyWithWorldcoin(
          signal,
          root,
          nullifierHash,
          proof
        )
      )
        .to.emit(datingProtocol, "UserVerified")
        .withArgs(user1.address, true, false);

      const status = await datingProtocol.verificationStatus(user1.address);
      expect(status.worldcoinVerified).to.be.true;
    });
  });

  describe("Matching", function () {
    beforeEach(async function () {
      // Create profiles and verify users
      await datingProtocol.connect(user1).createProfile(
        "QmUser1",
        "0x123",
        { value: PROFILE_FEE }
      );
      await datingProtocol.connect(user2).createProfile(
        "QmUser2",
        "0x456",
        { value: PROFILE_FEE }
      );

      // Mock verification
      await datingProtocol.connect(user1).verifyWithWorldcoin(
        user1.address,
        123,
        456,
        Array(8).fill(789)
      );
      await datingProtocol.connect(user2).verifyWithWorldcoin(
        user2.address,
        123,
        457,
        Array(8).fill(789)
      );

      // Mock Privy verification
      const messageHash = ethers.utils.solidityKeccak256(
        ["address", "string"],
        [user1.address, "PRIVY_VERIFIED"]
      );
      const signature = await owner.signMessage(ethers.utils.arrayify(messageHash));
      await datingProtocol.updatePrivyVerification(user1.address, signature);

      const messageHash2 = ethers.utils.solidityKeccak256(
        ["address", "string"],
        [user2.address, "PRIVY_VERIFIED"]
      );
      const signature2 = await owner.signMessage(ethers.utils.arrayify(messageHash2));
      await datingProtocol.updatePrivyVerification(user2.address, signature2);
    });

    it("Should create a match between verified users", async function () {
      await expect(
        datingProtocol.connect(user1).createMatch(user2.address, {
          value: MATCHING_FEE
        })
      )
        .to.emit(datingProtocol, "MatchCreated")
        .withArgs(user1.address, user2.address);

      const matches = await datingProtocol.userMatches(user1.address, 0);
      expect(matches).to.equal(user2.address);
    });

    it("Should fail to match unverified users", async function () {
      const [, , unverifiedUser] = await ethers.getSigners();
      await expect(
        datingProtocol.connect(unverifiedUser).createMatch(user2.address, {
          value: MATCHING_FEE
        })
      ).to.be.revertedWith("User not verified with Worldcoin");
    });
  });

  describe("Governance", function () {
    it("Should allow token holders to create proposals", async function () {
      // Transfer tokens to user1
      await datingToken.transfer(user1.address, ethers.utils.parseEther("200000"));
      await datingToken.connect(user1).delegate(user1.address);

      // Create proposal
      const proposalDescription = "Update matching fee";
      const encodedFunctionCall = datingProtocol.interface.encodeFunctionData(
        "updateFees",
        [PROFILE_FEE, ethers.utils.parseEther("0.002")]
      );

      await expect(
        datingGovernance.connect(user1).propose(
          [datingProtocol.address],
          [0],
          [encodedFunctionCall],
          proposalDescription
        )
      ).to.emit(datingGovernance, "ProposalCreated");
    });
  });

  describe("Token Economics", function () {
    it("Should allow users to stake tokens", async function () {
      const stakeAmount = ethers.utils.parseEther("1000");
      await datingToken.transfer(user1.address, stakeAmount);
      await datingToken.connect(user1).approve(datingToken.address, stakeAmount);

      await expect(
        datingToken.connect(user1).stake(stakeAmount)
      )
        .to.emit(datingToken, "Staked")
        .withArgs(user1.address, stakeAmount);

      const stakedBalance = await datingToken.stakedBalance(user1.address);
      expect(stakedBalance).to.equal(stakeAmount);
    });

    it("Should distribute rewards correctly", async function () {
      const stakeAmount = ethers.utils.parseEther("1000");
      await datingToken.transfer(user1.address, stakeAmount);
      await datingToken.connect(user1).approve(datingToken.address, stakeAmount);
      await datingToken.connect(user1).stake(stakeAmount);

      // Simulate time passing
      await ethers.provider.send("evm_increaseTime", [365 * 24 * 60 * 60]); // 1 year
      await ethers.provider.send("evm_mine");

      await expect(
        datingToken.connect(user1).claimRewards()
      ).to.emit(datingToken, "RewardsClaimed");

      const rewards = await datingToken.calculateRewards(user1.address);
      expect(rewards).to.be.gt(0);
    });
  });
}); 