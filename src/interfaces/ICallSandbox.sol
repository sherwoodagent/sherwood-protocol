// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStrategyDelivery} from "./IStrategyDelivery.sol";

/**
 * @title ICallSandbox
 * @notice The isolation boundary that makes a tier-2 target's identity stop
 *         mattering.
 *
 *         A governor batch executes under `delegatecall`, so every sub-call
 *         reaches its target carrying `msg.sender == vault`. That is why
 *         `SyndicateVault._guardBatchCalls` refuses any callee the TierRegistry
 *         owner has not allowlisted: reaching an arbitrary address AS THE VAULT
 *         licenses spending the vault's standing allowances, moving vault-held
 *         position tokens through selectors no allowlist enumerates, and
 *         satisfying any `msg.sender == vault` gate on a third-party contract.
 *
 *         A sandbox executes the same calldata one hop further out, from a
 *         contract that holds nothing but the capital it was explicitly funded
 *         with. The callee sees the sandbox, not the vault. Maximum loss stops
 *         being a figure the per-call meter has to observe and becomes a
 *         structural fact — the funded amount — which is exactly what tier-2
 *         coverage already charges for at full notional.
 *
 *         That is the whole reason no owner ceremony admits a sandbox target:
 *         there is nothing for an owner to attest, because the blast radius is
 *         set by the funding rather than by the callee's reputation. Review moves
 *         to the guardian cohort, which underwrites the proposal with slashable
 *         stake against a call set stored at propose time and readable through
 *         the whole review period.
 *
 * @dev    Extends `IStrategyDelivery` because the vault's residue machinery must
 *         reach a sandbox exactly as it reaches a settled strategy — a sandbox
 *         holding value after settlement is the finding-#3 shape reintroduced
 *         through a new path, and routing it through the same probes means the
 *         deposit gate, the residue bound and the permissionless collection all
 *         apply with no parallel implementation.
 *
 *         See `openspec/changes/permissionless-tier2-sandbox/` — capability
 *         `sandbox-execution`.
 */
interface ICallSandbox is IStrategyDelivery {
    /// @notice One arbitrary call. NO `value` FIELD, deliberately:
    ///         `BatchExecutorLib.Call` carries one and native value would open a
    ///         transfer channel with no metering story, so v1 refuses it by
    ///         construction rather than by a check (design.md Non-Goals).
    struct Call {
        address target;
        bytes data;
    }

    /// @notice A stored call named an address the sandbox must never reach.
    error DeniedTarget(address target);
    /// @notice Call `index` reverted. The whole run reverts with it — a partial
    ///         run is a different proposal than the one guardians approved.
    error CallFailed(uint256 index);
    /// @notice `run` was already invoked. Funding is one-shot, and so is this.
    error AlreadyRun();
    /// @notice Caller is not the vault that initialized this sandbox.
    error NotVault();
    /// @notice `init` was already invoked on this clone.
    error AlreadyInitialized();
    /// @notice The call set was empty, or a call named the zero address.
    error InvalidCallSet();

    /// @notice Emitted once per successful run, naming what was dispatched.
    event SandboxRun(address indexed vault, uint256 callCount, uint256 funded);
    /// @notice The sandbox returned assets to the vault.
    event SandboxSwept(uint256 assets);

    /// @notice Bind this clone to its vault and freeze its payload.
    /// @dev    Callable once. The payload is written here and has no setter: the
    ///         guardian coverage quorum IS the review that replaces the owner's
    ///         allowlist decision, and that substitution only holds if what runs
    ///         cannot change after it was approved.
    function init(address vault_, Call[] calldata calls_, address[] calldata declaredTokens_) external;

    /// @notice Dispatch the stored calls. Vault-only, one-shot.
    function run() external;

    /// @notice Return the sandbox's vault-asset balance to the vault.
    /// @dev    Permissionless and reached by a DIRECT call from the vault, never
    ///         through a governor batch — which is what lets capital come home
    ///         with no registry standing and no owner action, even after a
    ///         demotion that would wedge a batch-reachable strategy.
    /// @return assets Amount returned by this call.
    function sweep() external returns (uint256 assets);

    /// @notice The vault this sandbox was bound to at `init`.
    function vault() external view returns (address);

    /// @notice The full stored call set — the guardians' review artifact.
    function calls() external view returns (Call[] memory);

    /// @notice Tokens the proposer declared this sandbox may come to hold.
    /// @dev    A contract cannot enumerate every ERC-20 it holds, so without a
    ///         declaration `hasUnvaluedResidue()` could only be a constant. An
    ///         UNDER-declared leftover is stranded here and never counted as
    ///         vault value — the safe direction, and the proposer's own loss.
    function declaredTokens() external view returns (address[] memory);

    /// @notice True once `run` has executed.
    function hasRun() external view returns (bool);
}
