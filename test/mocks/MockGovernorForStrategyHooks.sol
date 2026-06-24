// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";

/// @notice Minimal mock governor for SyndicateVault.StrategyHooks tests.
///         Exposes only the two selectors the vault's `_activeStrategy()` reads:
///         `getActiveProposal(address)` and `getProposal(uint256)`.
contract MockGovernorForStrategyHooks {
    mapping(address => uint256) private _activeProposals;
    mapping(uint256 => ISyndicateGovernor.StrategyProposal) private _proposals;

    function setActiveProposal(address vault, uint256 pid) external {
        _activeProposals[vault] = pid;
    }

    function setStrategy(uint256 pid, address strategy) external {
        _proposals[pid].strategy = strategy;
    }

    function getActiveProposal(address vault) external view returns (uint256) {
        return _activeProposals[vault];
    }

    function getProposal(uint256 pid) external view returns (ISyndicateGovernor.StrategyProposal memory) {
        return _proposals[pid];
    }
}
