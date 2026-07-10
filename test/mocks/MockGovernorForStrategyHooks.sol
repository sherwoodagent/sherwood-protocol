// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";

/// @notice Minimal mock governor for SyndicateVault.StrategyHooks tests.
///         Exposes only the two selectors the vault's `_activeStrategy()` reads:
///         `getActiveProposal()` and `getProposal(uint256)`. Per-vault (#421):
///         a governor serves exactly one vault, so `getActiveProposal` is
///         zero-arg. `setActiveProposal` keeps the vault param for call-site
///         compatibility but writes a single slot.
contract MockGovernorForStrategyHooks {
    uint256 private _activeProposal;
    mapping(uint256 => ISyndicateGovernor.StrategyProposal) private _proposals;

    function setActiveProposal(address, uint256 pid) external {
        _activeProposal = pid;
    }

    function setStrategy(uint256 pid, address strategy) external {
        _proposals[pid].strategy = strategy;
    }

    function getActiveProposal() external view returns (uint256) {
        return _activeProposal;
    }

    function getProposal(uint256 pid) external view returns (ISyndicateGovernor.StrategyProposal memory) {
        return _proposals[pid];
    }
}
