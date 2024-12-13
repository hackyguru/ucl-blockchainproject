const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("DatingProtocol", function () {
    let DatingProtocol;
    let datingProtocol;
    let owner;
    let user1;
    let user2;
    let user3;
    let MockWorldID;
    let mockWorldID;
    let MockToken;
    let mockToken;
    let teamWallet;
    let rewardsPool;
    let treasuryWallet;

    const QUESTIONS_COUNT = 10;
    const WEEKLY_STAKE_AMOUNT = ethers.utils.parseEther("1");
    const MATCHING_INTERVAL = 7 * 24 * 60 * 60; // 7 days in seconds

    beforeEach(async function () {
        // Get signers
        [owner, user1, user2, user3, teamWallet, rewardsPool, treasuryWallet] = await ethers.getSigners();

        // Deploy mock WorldID contract
        MockWorldID = await ethers.getContractFactory("MockWorldID");
        mockWorldID = await MockWorldID.deploy();
        await mockWorldID.deployed();

        // Deploy mock ERC20 token
        MockToken = await ethers.getContractFactory("MockERC20");
        mockToken = await MockToken.deploy("Governance Token", "GOV");
        await mockToken.deployed();

        // Deploy DatingProtocol contract
        DatingProtocol = await ethers.getContractFactory("DatingProtocol");
        datingProtocol = await DatingProtocol.deploy(
            mockWorldID.address,
            123, // external nullifier
            mockToken.address
        );
        await datingProtocol.deployed();

        // Set treasury addresses
        await datingProtocol.setTreasuryAddresses(
            teamWallet.address,
            rewardsPool.address,
            treasuryWallet.address
        );

        // Mint tokens to users for testing
        await mockToken.mint(user1.address, ethers.utils.parseEther("100"));
        await mockToken.mint(user2.address, ethers.utils.parseEther("100"));
        await mockToken.mint(user3.address, ethers.utils.parseEther("100"));

        // Approve token spending
        await mockToken.connect(user1).approve(datingProtocol.address, ethers.utils.parseEther("100"));
        await mockToken.connect(user2).approve(datingProtocol.address, ethers.utils.parseEther("100"));
        await mockToken.connect(user3).approve(datingProtocol.address, ethers.utils.parseEther("100"));
    });

    describe("Deployment", function () {
        it("Should set the right owner", async function () {
            expect(await datingProtocol.owner()).to.equal(owner.address);
        });

        it("Should set the correct token address", async function () {
            expect(await datingProtocol.governanceToken()).to.equal(mockToken.address);
        });

        it("Should set the correct WorldID address", async function () {
            expect(await datingProtocol.worldId()).to.equal(mockWorldID.address);
        });
    });

    describe("WorldID Verification", function () {
        it("Should verify user with WorldID", async function () {
            const root = 123;
            const groupId = 1;
            const signalHash = 456;
            const nullifierHash = 789;
            const proof = Array(8).fill(ethers.constants.Zero);

            await datingProtocol.connect(user1).verifyWithWorldID(
                root,
                groupId,
                signalHash,
                nullifierHash,
                proof
            );

            expect(await datingProtocol.verifiedUsers(user1.address)).to.be.true;
        });
    });

    describe("Profile Management", function () {
        const ipfsHash = "QmTest123";
        const publicKey = "0x123456";
        const answers = Array(QUESTIONS_COUNT).fill(true);
        const preferences = Array(QUESTIONS_COUNT).fill(false);

        it("Should create a new profile", async function () {
            await datingProtocol.connect(user1).createProfile(ipfsHash, publicKey, answers, preferences);
            
            const profile = await datingProtocol.getProfile(user1.address);
            expect(profile.ipfsHash).to.equal(ipfsHash);
            expect(profile.isActive).to.be.true;
            expect(profile.publicKey).to.equal(publicKey);
        });

        it("Should fail if answers count is incorrect", async function () {
            const invalidAnswers = Array(QUESTIONS_COUNT - 1).fill(true);
            await expect(
                datingProtocol.connect(user1).createProfile(ipfsHash, publicKey, invalidAnswers, preferences)
            ).to.be.revertedWith("Invalid answers count");
        });

        it("Should update existing profile", async function () {
            await datingProtocol.connect(user1).createProfile(ipfsHash, publicKey, answers, preferences);
            
            const newIpfsHash = "QmTest456";
            await datingProtocol.connect(user1).createProfile(newIpfsHash, publicKey, answers, preferences);
            
            const profile = await datingProtocol.getProfile(user1.address);
            expect(profile.ipfsHash).to.equal(newIpfsHash);
        });

        it("Should fail with empty IPFS hash", async function () {
            await expect(
                datingProtocol.connect(user1).createProfile("", publicKey, answers, preferences)
            ).to.be.revertedWith("Invalid IPFS hash");
        });

        it("Should fail with empty public key", async function () {
            await expect(
                datingProtocol.connect(user1).createProfile(ipfsHash, "", answers, preferences)
            ).to.be.revertedWith("Invalid public key");
        });
    });

    describe("Staking and Matching", function () {
        const ipfsHash = "QmTest123";
        const publicKey = "0x123456";
        const answers = Array(QUESTIONS_COUNT).fill(true);
        const preferences = Array(QUESTIONS_COUNT).fill(false);

        beforeEach(async function () {
            // Create profiles for testing
            await datingProtocol.connect(user1).createProfile(ipfsHash, publicKey, answers, preferences);
            await datingProtocol.connect(user2).createProfile(ipfsHash, publicKey, preferences, answers);
        });

        it("Should allow users to stake for matching", async function () {
            await datingProtocol.connect(user1).stakeForMatching();
            
            const profile = await datingProtocol.getProfile(user1.address);
            expect(profile.isStaked).to.be.true;
            expect(await datingProtocol.getQueueLength()).to.equal(1);
        });

        it("Should not allow staking without an active profile", async function () {
            await expect(
                datingProtocol.connect(user3).stakeForMatching()
            ).to.be.revertedWith("Profile not active");
        });

        it("Should not allow double staking", async function () {
            await datingProtocol.connect(user1).stakeForMatching();
            await expect(
                datingProtocol.connect(user1).stakeForMatching()
            ).to.be.revertedWith("Already staked");
        });

        it("Should calculate compatibility correctly", async function () {
            const score = await datingProtocol.calculateCompatibility(user1.address, user2.address);
            // Since user1's answers are opposite to user2's preferences and vice versa,
            // the compatibility score should be 0
            expect(score).to.equal(0);
        });

        it("Should execute weekly matching successfully", async function () {
            // Stake for both users
            await datingProtocol.connect(user1).stakeForMatching();
            await datingProtocol.connect(user2).stakeForMatching();

            // Fast forward time
            await time.increase(MATCHING_INTERVAL);

            // Execute matching
            await datingProtocol.connect(owner).executeWeeklyMatching();
            
            // Check matches
            const user1Matches = await datingProtocol.getUserMatches(user1.address);
            expect(user1Matches).to.include(user2.address);

            // Check that users are no longer staked
            const profile1 = await datingProtocol.getProfile(user1.address);
            const profile2 = await datingProtocol.getProfile(user2.address);
            expect(profile1.isStaked).to.be.false;
            expect(profile2.isStaked).to.be.false;
        });

        it("Should not allow matching before interval", async function () {
            await datingProtocol.connect(user1).stakeForMatching();
            await datingProtocol.connect(user2).stakeForMatching();

            await expect(
                datingProtocol.connect(owner).executeWeeklyMatching()
            ).to.be.revertedWith("Too early");
        });
    });

    describe("Fee Distribution", function () {
        const ipfsHash = "QmTest123";
        const publicKey = "0x123456";
        const answers = Array(QUESTIONS_COUNT).fill(true);
        const preferences = Array(QUESTIONS_COUNT).fill(false);

        beforeEach(async function () {
            await datingProtocol.connect(user1).createProfile(ipfsHash, publicKey, answers, preferences);
            await datingProtocol.connect(user1).stakeForMatching();
        });

        it("Should distribute fees correctly", async function () {
            const initialTeamBalance = await mockToken.balanceOf(teamWallet.address);
            const initialRewardsBalance = await mockToken.balanceOf(rewardsPool.address);
            const initialTreasuryBalance = await mockToken.balanceOf(treasuryWallet.address);

            await datingProtocol.connect(owner).withdrawFees();

            const finalTeamBalance = await mockToken.balanceOf(teamWallet.address);
            const finalRewardsBalance = await mockToken.balanceOf(rewardsPool.address);
            const finalTreasuryBalance = await mockToken.balanceOf(treasuryWallet.address);

            expect(finalTeamBalance.sub(initialTeamBalance)).to.equal(WEEKLY_STAKE_AMOUNT.mul(20).div(100));
            expect(finalRewardsBalance.sub(initialRewardsBalance)).to.equal(WEEKLY_STAKE_AMOUNT.mul(30).div(100));
            expect(finalTreasuryBalance.sub(initialTreasuryBalance)).to.equal(WEEKLY_STAKE_AMOUNT.mul(50).div(100));
        });

        it("Should fail to withdraw fees with zero balance", async function () {
            // First withdraw all fees
            await datingProtocol.connect(owner).withdrawFees();

            // Try to withdraw again
            await expect(
                datingProtocol.connect(owner).withdrawFees()
            ).to.be.revertedWith("No fees to withdraw");
        });

        it("Should fail to withdraw fees without treasury addresses set", async function () {
            // Deploy new contract without treasury addresses
            const newDatingProtocol = await DatingProtocol.deploy(
                mockWorldID.address,
                123,
                mockToken.address
            );
            await newDatingProtocol.deployed();

            // Try to withdraw fees
            await expect(
                newDatingProtocol.connect(owner).withdrawFees()
            ).to.be.revertedWith("Treasury addresses not set");
        });
    });
}); 