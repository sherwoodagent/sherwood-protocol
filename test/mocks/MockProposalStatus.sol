// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IProposalStatus} from "../../src/interfaces/IProposalStatus.sol";
import {deployTierRegistry} from "../helpers/TierRegistryFixture.sol";

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
    ///      TierRegistry through its governor for the callee and
    ///      value-moving-selector guards in `executeGovernorBatch`.
    ///
    ///      DEFAULTS TO A WIRED, PERMISSIVE REGISTRY (pashov finding #1). It
    ///      used to default to address(0), which turned the whole of PART 2 off
    ///      — that is now a hard `TierRegistryUnresolved` revert, so an unset
    ///      default would fail every batch in every suite using this adapter.
    ///      Tests pinning the fail-closed behavior itself call
    ///      `setTierRegistry(address(0))` explicitly, which still models a
    ///      pre-fix governor.
    address public tierRegistry;

    constructor() {
        tierRegistry = address(deployTierRegistry(address(this)));
    }

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

    /// @dev The vault reads this as the upper bound on what a settled strategy
    ///      may still owe (`_residueCap`). Defaults high so fixtures that do not
    ///      care about the cap are not silently clamped to zero; a test probing
    ///      the bound sets it explicitly.
    uint256 public capitalSnapshot = type(uint128).max;

    function setCapitalSnapshot(uint256 v) external {
        capitalSnapshot = v;
    }

    function getCapitalSnapshot(uint256) external view returns (uint256) {
        return capitalSnapshot;
    }

    /// @dev The vault bounds a residue report by the TIGHTER of this and the
    ///      capital snapshot. Defaults high for the same reason.
    uint256 public effectiveMaxCapital = type(uint128).max;

    function setEffectiveMaxCapital(uint256 v) external {
        effectiveMaxCapital = v;
    }

    function getEffectiveMaxCapital(uint256) external view returns (uint256) {
        return effectiveMaxCapital;
    }

    function openProposalCount() external view returns (uint256) {
        return openCount;
    }

    function strategyOf(uint256) external view returns (address) {
        return strategy;
    }
}
