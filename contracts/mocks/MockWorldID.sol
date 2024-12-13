// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@worldcoin/world-id-contracts/src/interfaces/IWorldID.sol";

contract MockWorldID is IWorldID {
    function verifyProof(
        uint256 root,
        uint256 groupId,
        bytes memory signal,
        uint256 signalHash,
        uint256 nullifierHash,
        uint256[8] calldata proof
    ) external pure override returns (bool) {
        // Mock implementation that always returns true
        // Parameters are unused but kept for interface compatibility
        root;
        groupId;
        signal;
        signalHash;
        nullifierHash;
        proof;
        return true;
    }
} 