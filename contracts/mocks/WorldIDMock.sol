// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@worldcoin/world-id-contracts/src/interfaces/IWorldID.sol";

contract WorldIDMock is IWorldID {
    function verifyProof(
        uint256 root,
        uint256 groupId,
        uint256 signalHash,
        uint256 nullifierHash,
        uint256[8] calldata proof
    ) external pure override {
        // Mock implementation that accepts any proof
        // In production, this would verify the zero-knowledge proof
        require(root != 0, "Invalid root");
        require(nullifierHash != 0, "Invalid nullifier hash");
        require(proof.length == 8, "Invalid proof length");
    }
} 