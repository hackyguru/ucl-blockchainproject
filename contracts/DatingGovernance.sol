// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";

/**
 * @title DatingGovernance
 * @dev Governance contract for the dating protocol with support for matching parameters
 */
contract DatingGovernance is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    // Matching parameters that can be governed
    struct MatchingParameters {
        uint256 weeklyStakeAmount;
        uint256 matchingInterval;
        uint256 minCompatibilityScore;
        uint256 maxMatchesPerWeek;
        uint256 stakingBonusRate;
    }

    MatchingParameters public matchingParams;

    // Events
    event MatchingParametersUpdated(
        uint256 weeklyStakeAmount,
        uint256 matchingInterval,
        uint256 minCompatibilityScore,
        uint256 maxMatchesPerWeek,
        uint256 stakingBonusRate
    );

    constructor(
        IVotes _token,
        TimelockController _timelock,
        uint256 _votingDelay,
        uint256 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumPercentage
    )
        Governor("Dating Protocol Governance")
        GovernorSettings(
            _votingDelay,
            _votingPeriod,
            _proposalThreshold
        )
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(_quorumPercentage)
        GovernorTimelockControl(_timelock)
    {
        // Initialize default matching parameters
        matchingParams = MatchingParameters({
            weeklyStakeAmount: 1 ether,
            matchingInterval: 7 days,
            minCompatibilityScore: 60, // 60% minimum compatibility
            maxMatchesPerWeek: 1,
            stakingBonusRate: 5 // 5% bonus for consecutive stakes
        });
    }

    /**
     * @dev Update matching parameters through governance
     * @param _params New matching parameters
     */
    function updateMatchingParameters(MatchingParameters memory _params)
        external
        onlyGovernance
    {
        require(_params.weeklyStakeAmount > 0, "Invalid stake amount");
        require(_params.matchingInterval > 0, "Invalid interval");
        require(_params.minCompatibilityScore <= 100, "Invalid compatibility score");
        require(_params.maxMatchesPerWeek > 0, "Invalid max matches");
        require(_params.stakingBonusRate <= 100, "Invalid bonus rate");

        matchingParams = _params;

        emit MatchingParametersUpdated(
            _params.weeklyStakeAmount,
            _params.matchingInterval,
            _params.minCompatibilityScore,
            _params.maxMatchesPerWeek,
            _params.stakingBonusRate
        );
    }

    /**
     * @dev Get current matching parameters
     */
    function getMatchingParameters() external view returns (MatchingParameters memory) {
        return matchingParams;
    }

    /**
     * @dev Override of the propose function to include matching parameter proposals
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override(Governor, IGovernor) returns (uint256) {
        return super.propose(targets, values, calldatas, description);
    }

    /**
     * @dev Get voting delay in blocks
     */
    function votingDelay()
        public
        view
        override(IGovernor, GovernorSettings)
        returns (uint256)
    {
        return super.votingDelay();
    }

    /**
     * @dev Get voting period in blocks
     */
    function votingPeriod()
        public
        view
        override(IGovernor, GovernorSettings)
        returns (uint256)
    {
        return super.votingPeriod();
    }

    /**
     * @dev Get proposal threshold
     */
    function proposalThreshold()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    /**
     * @dev Get quorum
     */
    function quorum(uint256 blockNumber)
        public
        view
        override(IGovernor, GovernorVotesQuorumFraction)
        returns (uint256)
    {
        return super.quorum(blockNumber);
    }

    /**
     * @dev Get proposal state
     */
    function state(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    /**
     * @dev Execute proposal
     */
    function _execute(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._execute(proposalId, targets, values, calldatas, descriptionHash);
    }

    /**
     * @dev Cancel proposal
     */
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    /**
     * @dev Get executor
     */
    function _executor()
        internal
        view
        override(Governor, GovernorTimelockControl)
        returns (address)
    {
        return super._executor();
    }

    /**
     * @dev Check if account has voted
     */
    function hasVoted(uint256 proposalId, address account)
        public
        view
        override(Governor)
        returns (bool)
    {
        return super.hasVoted(proposalId, account);
    }
} 