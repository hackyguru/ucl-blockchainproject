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
  let teamWallet;
  let rewardsPool;
  let treasuryWallet;
  let worldcoinMock;
  let timelock;

  const INITIAL_SUPPLY = ethers.utils.parseEther("100000000"); // 100M tokens
  const WEEKLY_STAKE_AMOUNT = ethers.utils.parseEther("1"); // 1 TOKEN
  const TEAM_SHARE = 30;
  const REWARDS_SHARE = 40;
  const TREASURY_SHARE = 30;

  beforeEach(async function () {
    [owner, user1, user2, teamWallet, rewardsPool, treasuryWallet] = await ethers.getSigners();

    // Deploy mock WorldID contract
    const WorldIDMock = await ethers.getContractFactory("WorldIDMock");
    worldcoinMock = await WorldIDMock.deploy();
    await worldcoinMock.deployed();

    // Deploy governance token
    DatingGovernanceToken = await ethers.getContractFactory("DatingGovernanceToken");
    datingToken = await DatingGovernanceToken.deploy();
    await datingToken.deployed();

    // Deploy timelock
    const TimelockController = await ethers.getContractFactory("TimelockController");
    timelock = await TimelockController.deploy(
      1, // minDelay
      [owner.address],
      [owner.address],
      owner.address
    );
    await timelock.deployed();

    // Deploy governance contract
    DatingGovernance = await ethers.getContractFactory("DatingGovernance");
    datingGovernance = await DatingGovernance.deploy(
      datingToken.address,
      timelock.address,
      1, // votingDelay
      5760, // votingPeriod
      ethers.utils.parseEther("100000"), // proposalThreshold
      4 // quorumPercentage
    );
    await datingGovernance.deployed();

    // Deploy main protocol
    DatingProtocol = await ethers.getContractFactory("DatingProtocol");
    datingProtocol = await DatingProtocol.deploy(
      worldcoinMock.address,
      ethers.utils.formatBytes32String("dating_app"),
      datingToken.address
    );
    await datingProtocol.deployed();

    // Setup treasury addresses
    await datingProtocol.setTreasuryAddresses(
      teamWallet.address,
      rewardsPool.address,
      treasuryWallet.address
    );

    // Transfer tokens to users for testing
    await datingToken.transfer(user1.address, ethers.utils.parseEther("1000"));
    await datingToken.transfer(user2.address, ethers.utils.parseEther("1000"));
  });

  describe("Profile Management", function () {
    it("Should create a profile with questionnaire answers", async function () {
      const answers = Array(10).fill(true);
      const preferences = Array(10).fill(false);

      await datingProtocol.connect(user1).createProfile(
        "QmTest123",
        "0x123456789",
        answers,
        preferences
      );

      const profile = await datingProtocol.getProfile(user1.address);
      expect(profile.answers).to.deep.equal(answers);
      expect(profile.preferences).to.deep.equal(preferences);
      expect(profile.isActive).to.be.true;
    });

    it("Should fail to create profile with invalid answers count", async function () {
      const answers = Array(9).fill(true); // Only 9 answers instead of 10
      const preferences = Array(10).fill(false);

      await expect(
        datingProtocol.connect(user1).createProfile(
          "QmTest123",
          "0x123456789",
          answers,
          preferences
        )
      ).to.be.revertedWith("Invalid answers count");
    });

    it("Should update existing profile", async function () {
      const answers = Array(10).fill(true);
      const preferences = Array(10).fill(false);
      const newAnswers = Array(10).fill(false);
      const newPreferences = Array(10).fill(true);

      // Create initial profile
      await datingProtocol.connect(user1).createProfile(
        "QmTest123",
        "0x123456789",
        answers,
        preferences
      );

      // Update profile
      await datingProtocol.connect(user1).createProfile(
        "QmTest456",
        "0x987654321",
        newAnswers,
        newPreferences
      );

      const profile = await datingProtocol.getProfile(user1.address);
      expect(profile.answers).to.deep.equal(newAnswers);
      expect(profile.preferences).to.deep.equal(newPreferences);
      expect(profile.ipfsHash).to.equal("QmTest456");
      expect(profile.publicKey).to.equal("0x987654321");
    });
  });

  describe("WorldID Verification", function () {
    it("Should verify user with WorldID", async function () {
      const root = 123;
      const groupId = 1;
      const signalHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("test"));
      const nullifierHash = 456;
      const proof = Array(8).fill(ethers.BigNumber.from(1));

      await datingProtocol.connect(user1).verifyWithWorldID(
        root,
        groupId,
        signalHash,
        nullifierHash,
        proof
      );

      expect(await datingProtocol.verifiedUsers(user1.address)).to.be.true;
    });

    it("Should fail verification with invalid proof", async function () {
      const root = 0; // Invalid root
      const groupId = 1;
      const signalHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("test"));
      const nullifierHash = 456;
      const proof = Array(8).fill(ethers.BigNumber.from(1));

      await expect(
        datingProtocol.connect(user1).verifyWithWorldID(
          root,
          groupId,
          signalHash,
          nullifierHash,
          proof
        )
      ).to.be.revertedWith("Invalid root");
    });
  });

  describe("Matching System", function () {
    beforeEach(async function () {
      // Setup profiles for testing
      const answers1 = Array(10).fill(true);
      const preferences1 = Array(10).fill(false);
      const answers2 = Array(10).fill(false);
      const preferences2 = Array(10).fill(true);

      await datingProtocol.connect(user1).createProfile(
        "QmUser1",
        "0x123",
        answers1,
        preferences1
      );

      await datingProtocol.connect(user2).createProfile(
        "QmUser2",
        "0x456",
        answers2,
        preferences2
      );
    });

    it("Should calculate compatibility score correctly", async function () {
      const score = await datingProtocol.calculateCompatibility(
        user1.address,
        user2.address
      );
      expect(score).to.equal(100); // Perfect match
    });

    it("Should handle weekly matching process", async function () {
      // Approve and stake tokens
      await datingToken.connect(user1).approve(datingProtocol.address, WEEKLY_STAKE_AMOUNT);
      await datingToken.connect(user2).approve(datingProtocol.address, WEEKLY_STAKE_AMOUNT);

      await datingProtocol.connect(user1).stakeForMatching();
      await datingProtocol.connect(user2).stakeForMatching();

      // Time travel to next matching interval
      await ethers.provider.send("evm_increaseTime", [7 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine");

      await datingProtocol.executeWeeklyMatching();

      const matches = await datingProtocol.getUserMatches(user1.address);
      expect(matches).to.include(user2.address);
    });

    it("Should not match users before stake expiry", async function () {
      await datingToken.connect(user1).approve(datingProtocol.address, WEEKLY_STAKE_AMOUNT);
      await datingToken.connect(user2).approve(datingProtocol.address, WEEKLY_STAKE_AMOUNT);

      await datingProtocol.connect(user1).stakeForMatching();
      await datingProtocol.connect(user2).stakeForMatching();

      // Try matching before interval
      await expect(
        datingProtocol.executeWeeklyMatching()
      ).to.be.revertedWith("Too early");
    });
  });

  describe("Fee Distribution", function () {
    it("Should distribute fees correctly", async function () {
      const stakeAmount = ethers.utils.parseEther("10");
      await datingToken.transfer(datingProtocol.address, stakeAmount);

      // Get initial balances
      const initialTeamBalance = await datingToken.balanceOf(teamWallet.address);
      const initialRewardsBalance = await datingToken.balanceOf(rewardsPool.address);
      const initialTreasuryBalance = await datingToken.balanceOf(treasuryWallet.address);

      // Withdraw fees
      await datingProtocol.withdrawFees();

      // Calculate expected amounts
      const teamAmount = stakeAmount.mul(TEAM_SHARE).div(100);
      const rewardsAmount = stakeAmount.mul(REWARDS_SHARE).div(100);
      const treasuryAmount = stakeAmount.mul(TREASURY_SHARE).div(100);

      // Verify balances
      expect(await datingToken.balanceOf(teamWallet.address))
        .to.equal(initialTeamBalance.add(teamAmount));
      expect(await datingToken.balanceOf(rewardsPool.address))
        .to.equal(initialRewardsBalance.add(rewardsAmount));
      expect(await datingToken.balanceOf(treasuryWallet.address))
        .to.equal(initialTreasuryBalance.add(treasuryAmount));
    });

    it("Should fail to withdraw fees with zero balance", async function () {
      await expect(datingProtocol.withdrawFees())
        .to.be.revertedWith("No fees to withdraw");
    });
  });

  describe("Staking and Rewards", function () {
    it("Should handle weekly staking correctly", async function () {
      await datingToken.connect(user1).approve(datingProtocol.address, WEEKLY_STAKE_AMOUNT);
      await datingProtocol.connect(user1).stakeForMatching();

      const profile = await datingProtocol.getProfile(user1.address);
      expect(profile.isStaked).to.be.true;
      expect(profile.stakeExpiry).to.be.gt(0);
    });

    it("Should not allow double staking", async function () {
      await datingToken.connect(user1).approve(datingProtocol.address, WEEKLY_STAKE_AMOUNT.mul(2));
      await datingProtocol.connect(user1).stakeForMatching();

      await expect(
        datingProtocol.connect(user1).stakeForMatching()
      ).to.be.revertedWith("Already staked");
    });

    it("Should handle stake expiry correctly", async function () {
      await datingToken.connect(user1).approve(datingProtocol.address, WEEKLY_STAKE_AMOUNT);
      await datingProtocol.connect(user1).stakeForMatching();

      // Time travel past stake expiry
      await ethers.provider.send("evm_increaseTime", [8 * 24 * 60 * 60]); // 8 days
      await ethers.provider.send("evm_mine");

      // Execute matching to clear expired stakes
      await datingProtocol.executeWeeklyMatching();

      const profile = await datingProtocol.getProfile(user1.address);
      expect(profile.isStaked).to.be.false;
    });
  });

  // Helper functions
  async function setupUsersForMatching() {
    const answers = Array(10).fill(true);
    const preferences = Array(10).fill(false);

    for (const user of [user1, user2]) {
      await datingProtocol.connect(user).createProfile(
        `QmTest${user.address}`,
        "0x123",
        answers,
        preferences
      );
      await datingToken.connect(user).approve(datingProtocol.address, WEEKLY_STAKE_AMOUNT);
      await datingProtocol.connect(user).stakeForMatching();
    }
  }
});