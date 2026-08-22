// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateGovernor} from "./ISyndicateGovernor.sol";

interface ISyndicateFactory {
    // ── Events ──
    event OwnerRotated(address indexed vault, address indexed newOwner);
    event WithdrawalQueueDeployed(address indexed vault, address indexed queue);

    // ── Errors ──
    error VaultStillStaked();
    error VaultImplMismatch();
    error InvalidSyndicateConfig();

    // ── Errors (guardian economic-security) ──
    /// @dev `pushWiring` target is not a governor this factory deployed.
    error NotFactoryGovernor();

    // ── Events (guardian economic-security) ──
    event ExposureLedgerSet(address indexed oldLedger, address indexed newLedger);
    event BondEscrowSet(address indexed oldEscrow, address indexed newEscrow);
    event WiringPushed(address indexed governor);

    // ── Events (issue #43 — executor migration) ──
    /// @notice Emitted by `setExecutorImpl` — the shared `BatchExecutorLib`
    ///         new syndicates are wired to at `createSyndicate`.
    event ExecutorImplUpdated(address oldImpl, address newImpl);
    /// @notice Emitted when `pushExecutor` re-points an existing vault at the
    ///         factory's current `executorImpl`.
    event ExecutorPushed(address indexed vault, address indexed executorImpl);

    // ── Views ──
    function governorOf(address vault) external view returns (address);
    /// @notice Shared `BatchExecutorLib` new syndicates are wired to at
    ///         `createSyndicate`. Existing vaults keep whatever they were
    ///         wired with until `pushExecutor` re-points them individually.
    function executorImpl() external view returns (address);
    /// @notice Number of syndicates this factory has created — i.e. the number
    ///         of LIVE governor `BeaconProxy`s reading their implementation
    ///         from `beacon()`. Non-zero means a governor-impl swap on that
    ///         beacon is a live-state migration, not a fresh deployment; see
    ///         `DeployPlanB`'s beacon pre-flight.
    function syndicateCount() external view returns (uint256);
    function beacon() external view returns (address);
    function protocolConfig() external view returns (address);
    function vaultImpl() external view returns (address);
    function vaultToSyndicate(address vault) external view returns (uint256);
    function guardianRegistry() external view returns (address);
    function tierRegistry() external view returns (address);
    /// @notice Exposure ledger pushed into governors at `createSyndicate` / `pushWiring`.
    function exposureLedger() external view returns (address);
    /// @notice Proposer-bond escrow pushed into governors at `createSyndicate` / `pushWiring`.
    function bondEscrow() external view returns (address);
    /// @notice Whether `governor` is a per-vault governor deployed by this factory.
    function isFactoryGovernor(address governor) external view returns (bool);

    // ── Admin ──
    function rotateOwner(address vault, address newOwner) external;
    function setParamsOverride(address vault, ISyndicateGovernor.GovernorParams calldata params) external;
    function setTierRegistry(address newRegistry) external;
    function setExposureLedger(address newLedger) external;
    function setBondEscrow(address newEscrow) external;
    /// @notice Push the factory's current tierRegistry / exposureLedger / bondEscrow
    ///         into an EXISTING factory-deployed governor.
    function pushWiring(address governor) external;
    /// @notice Update the shared `BatchExecutorLib` new syndicates are wired
    ///         to at `createSyndicate` (issue #43). Existing vaults are
    ///         untouched — re-point them individually via `pushExecutor`.
    function setExecutorImpl(address newExecutorImpl) external;
    /// @notice Re-point an EXISTING factory-deployed vault at the factory's
    ///         current `executorImpl`, lifecycle-gated on the vault's
    ///         governor (`getActiveProposal() == 0 && openProposalCount() ==
    ///         0`) — a re-point under a live proposal would swap the
    ///         metering library out from under stored, coverage-priced calls.
    function pushExecutor(address vault) external;
}
