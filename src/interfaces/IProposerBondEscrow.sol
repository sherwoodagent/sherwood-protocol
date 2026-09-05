// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IProposerBondEscrow
/// @notice WOOD escrow for the risk-scaled proposer bond. Governor-only
///         lock/release, and ONE non-release exit: `forfeitBond`, driven by
///         a passed challenge.
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
    /// @notice `forfeitBond` was handed a prosecutor-fee rate above
    ///         `MAX_PROSECUTOR_FEE_BPS`. Reverts rather than clamping: a
    ///         caller-chosen payee must not be laundered into a
    ///         smaller-but-still-caller-chosen one.
    error FeeBpsTooHigh();

    event BondLocked(address indexed governor, uint256 indexed proposalId, address indexed proposer, uint256 amount);
    event BondReleased(address indexed governor, uint256 indexed proposalId, address indexed proposer, uint256 amount);
    /// @notice A bond was confiscated rather than returned. `proposer` is the
    ///         address that would have been paid on release, recorded so the
    ///         loss is attributable on-chain; the WOOD itself went to the burn
    ///         address and has no recipient.
    event BondForfeited(address indexed governor, uint256 indexed proposalId, address indexed proposer, uint256 amount);
    /// @notice The prosecutor's cut of a forfeited bond. `amount` here plus the
    ///         burned remainder equal `BondForfeited`'s gross.
    event ProsecutorFeePaid(
        address indexed governor, uint256 indexed proposalId, address indexed feeTo, uint256 amount
    );

    function lockBond(uint256 proposalId, address proposer, uint256 amount) external;
    function releaseBond(uint256 proposalId) external;
    /// @notice Confiscate a convicted proposal's bond, paying `feeBps` of it to
    ///         `feeTo` and burning the remainder.
    /// @dev    The fee is the prosecutor's, and this is the pot it comes from
    ///         precisely because a prosecutor cannot fund it: self-dealing
    ///         requires BEING the proposer, which means paying yourself a
    ///         fraction of a bond you forfeit in full. `feeBps` is bounded by
    ///         `MAX_PROSECUTOR_FEE_BPS` here rather than trusted from the
    ///         convictor, so a compromised game can divert at most that
    ///         fraction of any one bond. `amount` is the GROSS forfeited bond;
    ///         `ProsecutorFeePaid` carries the fee leg.
    function forfeitBond(address governor, uint256 proposalId, address feeTo, uint256 feeBps)
        external
        returns (address proposer, uint256 amount);

    /// @notice Ceiling on `forfeitBond`'s `feeBps`. Read this rather than
    ///         restating the literal elsewhere, so a caller's own clamp and the
    ///         escrow's enforced one cannot drift apart.
    function MAX_PROSECUTOR_FEE_BPS() external view returns (uint256);
    function bondOf(address governor, uint256 proposalId) external view returns (address proposer, uint256 amount);

    /// @notice The ledger this escrow trusts to authorize `forfeitBond` —
    ///         immutable, fixed at the escrow's own deployment. A governor
    ///         must not lock a bond into an escrow whose `exposureLedger`
    ///         differs from the ledger it is pricing/pinning that bond
    ///         against, or the escrow will reject every forfeiture attempt
    function exposureLedger() external view returns (address);
}
