// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IProposalStatus} from "../../src/interfaces/IProposalStatus.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";

/// @notice Canonical test adapter for the vault↔governance seam: satisfies
///         `IProposalStatus` (the ONLY governance surface the vault reads) in a
///         few lines. Prefer this over hand-mocking governor selectors with
///         `vm.mockCall` — one `set(...)` per state change instead of 3-5
///         mockCalls per test file.
contract MockProposalStatus is IProposalStatus {
    uint256 public activePid;
    uint256 public openCount;
    address public strategy;

    /// @dev Mirrors `SyndicateGovernor.tierRegistry()` — the vault resolves the
    ///      TierRegistry through its governor for the value-moving-selector
    ///      guard in `executeGovernorBatch`. address(0) (the default) means the
    ///      guard is off, matching the unset-registry safe-default posture.
    address public tierRegistry;

    function setTierRegistry(address registry) external {
        tierRegistry = registry;
    }

    /// @dev One call drives the whole seam: pid=0 ⇒ unlocked; pid!=0 locks the
    ///      vault with `strategy_` as the active proposal's strategy.
    function set(uint256 pid, uint256 openCount_, address strategy_) external {
        activePid = pid;
        openCount = openCount_;
        strategy = strategy_;
    }

    function getActiveProposal() external view returns (uint256) {
        return activePid;
    }

    function openProposalCount() external view returns (uint256) {
        return openCount;
    }

    function getProposal(uint256) external view returns (ISyndicateGovernor.StrategyProposal memory p) {
        p.id = activePid;
        p.strategy = strategy;
    }
}
