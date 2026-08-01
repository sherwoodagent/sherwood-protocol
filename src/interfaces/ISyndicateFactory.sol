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
    event CompensationEscrowSet(address indexed oldEscrow, address indexed newEscrow);

    // ── Views ──
    function governorOf(address vault) external view returns (address);
    /// @notice Number of syndicates this factory has created — i.e. the number
    ///         of LIVE governor `BeaconProxy`s reading their implementation
    ///         from `beacon()`. Non-zero means a governor-impl swap on that
    ///         beacon is a live-state migration, not a fresh deployment; see
    ///         `DeployPlanB`'s beacon pre-flight.
    function syndicateCount() external view returns (uint256);
    function beacon() external view returns (address);
    function protocolConfig() external view returns (address);
    function priceRouter() external view returns (address);
    function vaultImpl() external view returns (address);
    function vaultToSyndicate(address vault) external view returns (uint256);
    function guardianRegistry() external view returns (address);
    function tierRegistry() external view returns (address);
    /// @notice Exposure ledger pushed into governors at `createSyndicate` / `pushWiring`.
    function exposureLedger() external view returns (address);
    /// @notice Proposer-bond escrow pushed into governors at `createSyndicate` / `pushWiring`.
    function bondEscrow() external view returns (address);
    /// @notice Protocol `CompensationEscrow` the withdrawal queues this
    ///         factory deployed pay their custody claims out of. Read LIVE by
    ///         `VaultWithdrawalQueue.claimCompensation`, never caller-supplied.
    function compensationEscrow() external view returns (address);
    /// @notice Whether `governor` is a per-vault governor deployed by this factory.
    function isFactoryGovernor(address governor) external view returns (bool);

    // ── Admin ──
    function rotateOwner(address vault, address newOwner) external;
    function setParamsOverride(address vault, ISyndicateGovernor.GovernorParams calldata params) external;
    function setTierRegistry(address newRegistry) external;
    function setExposureLedger(address newLedger) external;
    function setBondEscrow(address newEscrow) external;
    /// @notice Point every queue this factory deployed at the compensation
    ///         escrow their cases are funded into.
    function setCompensationEscrow(address newEscrow) external;
    /// @notice Push the factory's current tierRegistry / exposureLedger / bondEscrow
    ///         into an EXISTING factory-deployed governor.
    function pushWiring(address governor) external;
}
