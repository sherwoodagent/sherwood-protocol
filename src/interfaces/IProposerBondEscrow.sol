// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IProposerBondEscrow
/// @notice WOOD escrow for the risk-scaled proposer bond (spec 2026-07-22
///         §3.9). Governor-only lock/release, and ONE non-release exit:
///         `forfeitBond`, driven by a passed challenge (spec §3.8, Plan C).
interface IProposerBondEscrow {
    error NotAuthorizedGovernor();
    error BondAlreadyLocked();
    error NoBond();
    error ZeroAddress();
    error AmountTooLarge();
    /// @notice `forfeitBond` called by anything other than the live coverage
    ///         freezer of the wired exposure ledger — i.e. by something that is
    ///         not the challenge game. Confiscation is a verdict, so only the
    ///         contract that reaches verdicts may trigger it.
    error NotAuthorizedConvictor();

    event BondLocked(address indexed governor, uint256 indexed proposalId, address indexed proposer, uint256 amount);
    event BondReleased(address indexed governor, uint256 indexed proposalId, address indexed proposer, uint256 amount);
    /// @notice A bond was confiscated rather than returned. `proposer` is the
    ///         address that would have been paid on release, recorded so the
    ///         loss is attributable on-chain; the WOOD itself went to the burn
    ///         address and has no recipient.
    event BondForfeited(address indexed governor, uint256 indexed proposalId, address indexed proposer, uint256 amount);

    function lockBond(uint256 proposalId, address proposer, uint256 amount) external;
    function releaseBond(uint256 proposalId) external;
    function forfeitBond(address governor, uint256 proposalId) external returns (address proposer, uint256 amount);
    function bondOf(address governor, uint256 proposalId) external view returns (address proposer, uint256 amount);
}
