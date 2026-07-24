// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IProposerBondEscrow
/// @notice WOOD escrow for the risk-scaled proposer bond (spec 2026-07-22
///         §3.9). Governor-only lock/release; forfeiture (to the compensation
///         escrow, spec §3.8) is Plan C — v1a's only exit is release-to-proposer.
interface IProposerBondEscrow {
    error NotAuthorizedGovernor();
    error BondAlreadyLocked();
    error NoBond();
    error ZeroAddress();
    error AmountTooLarge();

    event BondLocked(address indexed governor, uint256 indexed proposalId, address indexed proposer, uint256 amount);
    event BondReleased(address indexed governor, uint256 indexed proposalId, address indexed proposer, uint256 amount);

    function lockBond(uint256 proposalId, address proposer, uint256 amount) external;
    function releaseBond(uint256 proposalId) external;
    function bondOf(address governor, uint256 proposalId) external view returns (address proposer, uint256 amount);
}
