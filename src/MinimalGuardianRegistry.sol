// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BatchExecutorLib} from "./BatchExecutorLib.sol";
import {IStakedWood} from "./interfaces/IStakedWood.sol";

/// @title MinimalGuardianRegistry
/// @notice Stub registry for beta deploys where WOOD is not yet live and the
///         guardian network is intentionally disabled. Implements only the
///         methods the governor and factory actually call:
///
///           - `reviewPeriod() = 0` collapses GuardianReview to a 0-second
///             window so proposals advance Pending -> Approved as soon as
///             voting ends.
///           - `resolveReview` / `getReviewState` return "resolved, not
///             blocked" so any review-state read short-circuits to Approved.
///           - `isEmergencyOpen` always false; emergency entrypoints revert.
///           - Owner-stake fns are no-ops (`canCreateVault = true` so anyone
///             can create a vault without staking; `hasOwnerStake = false` so
///             `rotateOwner` is unblocked).
///
///         Any non-stub call (delegation, slashing, parameter setters,
///         claims, fees) reverts with `Disabled()` so an accidental
///         production deploy fails loudly.
contract MinimalGuardianRegistry {
    error Disabled();

    /// @notice Sherlock #28 — `setGuardianRegistry` on the factory checks
    ///         the new registry's `factory()`. Returning `address(0)`
    ///         signals "stateless beta stub, no factory alignment check
    ///         needed". The production `GuardianRegistry` returns its
    ///         actual factory.
    function factory() external pure returns (address) {
        return address(0);
    }

    /// @notice Sherlock run #3 #7 — `SyndicateFactory.createSyndicate` and
    ///         `rotateOwner` route their owner-stake calls through
    ///         `reg.swood().canCreateVault(...)` / `bindOwnerStake(...)` /
    ///         `transferOwnerStakeSlot(...)`. Pre-fix the stub didn't expose
    ///         `swood()` and both factory paths reverted with "selector not
    ///         found" on any BETA_MODE deploy.
    ///
    ///         The stub points sWOOD back at ITSELF — `IStakedWood(address(
    ///         this))`. The three sWOOD methods the factory dispatches to
    ///         (`canCreateVault`, `bindOwnerStake`, `transferOwnerStakeSlot`)
    ///         are already implemented on this contract from the pre-split
    ///         era as no-op stubs, so the indirection collapses cleanly.
    ///         Any other `IStakedWood` method dispatched here will hit
    ///         either the no-op stubs below (`ownerStake`) or the `Disabled`
    ///         loud-revert wall — both desired in beta.
    function swood() external view returns (IStakedWood) {
        return IStakedWood(address(this));
    }

    /// @notice Lets the governor `IGuardianRegistry(_).reviewPeriod()` cast
    ///         resolve to 0, skipping the review phase.
    function reviewPeriod() external pure returns (uint256) {
        return 0;
    }

    /// @notice Always returns `blocked == false`.
    function resolveReview(uint256) external pure returns (bool) {
        return false;
    }

    /// @notice (opened, resolved, blocked, cohortTooSmall) — review is
    ///         pre-resolved as not-blocked.
    function getReviewState(uint256) external pure returns (bool, bool, bool, bool) {
        return (true, true, false, false);
    }

    function isEmergencyOpen(uint256) external pure returns (bool) {
        return false;
    }

    /// @notice Permissionless review opener — no-op in beta.
    function openReview(uint256) external pure {}

    /// @notice Governor-only cancel during GuardianReview — no-op in beta
    ///         because reviews never open. Mirrors the IGuardianRegistry
    ///         signature so governor's `cancelProposal` GuardianReview branch
    ///         still compiles against this stub.
    /// @dev Production `GuardianRegistry.cancelReview` reverts after
    ///      `reviewEnd` to block proposer-races-resolveReview slashing.
    ///      The stub has no review state and no slash path, so the post-
    ///      reviewEnd guard is meaningless here — silent no-op is
    ///      sufficient and matches the `openReview` no-op above.
    function cancelReview(uint256) external pure {}

    /// @notice Required by the factory's vault-create gate.
    function canCreateVault(address) external pure returns (bool) {
        return true;
    }

    /// @notice Factory-only; no-op in beta because there is no WOOD to bind.
    function bindOwnerStake(address, address) external pure {}

    /// @notice Factory-only `rotateOwner` slot transfer — no-op in beta.
    function transferOwnerStakeSlot(address, address) external pure {}

    /// @notice Used by `rotateOwner` (factory inlines `ownerStake > 0`) and
    ///         `GovernorEmergency` bond check. Stub always returns 0.
    function ownerStake(address) external pure returns (uint256) {
        return 0;
    }

    // ── Loud reverts on the disabled surface ──

    function openEmergency(uint256, bytes32, BatchExecutorLib.Call[] calldata) external pure {
        revert Disabled();
    }

    function cancelEmergency(uint256) external pure {
        revert Disabled();
    }

    function finalizeEmergency(uint256) external pure returns (bool, BatchExecutorLib.Call[] memory) {
        revert Disabled();
    }

    function fundProposalGuardianPool(uint256, address, uint256) external pure {
        revert Disabled();
    }

    function stakeAsGuardian(uint256, uint256) external pure {
        revert Disabled();
    }

    function prepareOwnerStake(uint256) external pure {
        revert Disabled();
    }
}
