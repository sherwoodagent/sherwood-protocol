// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IStakedWood
/// @notice Interface for the StakedWood (sWOOD) contract — the sole WOOD-token
///         custodian. sWOOD absorbs guardian staking, DPoS delegation, owner
///         bonds, vote checkpoints, and slashing, all of which previously
///         lived in `GuardianRegistry`. The slimmed `GuardianRegistry`,
///         `SyndicateGovernor`, and `SyndicateFactory` call sWOOD through
///         this interface.
/// @dev See `docs/superpowers/specs/2026-05-21-swood-staking-split-design.md`.
///      Staking/delegation/owner-bond signatures are carried verbatim from the
///      pre-split `IGuardianRegistry`. Checkpoint reads are timestamp-keyed
///      (EIP-6372 timestamp-mode clock).
interface IStakedWood {
    // ── Guardian stake ──
    function stakeAsGuardian(uint256 amount, uint256 agentId) external;
    function requestUnstakeGuardian() external;
    function cancelUnstakeGuardian() external;
    function claimUnstakeGuardian() external;

    // ── Owner bonds ──
    function prepareOwnerStake(uint256 amount) external;
    function cancelPreparedStake() external;
    function bindOwnerStake(address owner, address vault) external;
    function requestUnstakeOwner(address vault) external;
    function claimUnstakeOwner(address vault) external;
    function transferOwnerStakeSlot(address vault, address newOwner) external;

    /// @notice The owner bond a vault must hold. TVL scaling is not implemented
    ///         in V1; the bond is unconditionally `minOwnerStake`. The `vault`
    ///         parameter is retained for forward-compatibility.
    function requiredOwnerBond(address vault) external view returns (uint256);

    // ── Delegation ──
    function delegateStake(address delegate, uint256 amount) external;
    function requestUnstakeDelegation(address delegate) external;
    function cancelUnstakeDelegation(address delegate) external;
    function claimUnstakeDelegation(address delegate) external;
    function setCommission(uint256 newBps) external;

    // ── Snapshot-compatible vote-read surface (timestamp-keyed) ──
    //
    // `getVotes` / `getPastVotes` / `getPastTotalSupply` form the read surface
    // Snapshot's `erc20-votes` strategy consumes. sWOOD intentionally does NOT
    // implement the full OZ `IVotes` (no `delegate` / `delegates` /
    // `delegateBySig`) — sWOOD delegation is the custodial DPoS mechanism, a
    // different concept. Vote weight = own staked + delegated-inbound.

    /// @notice An account's CURRENT vote weight: own votable stake + delegated
    ///         inbound. Live counterpart of `getPastVotes`.
    function getVotes(address account) external view returns (uint256);

    /// @notice Guardian's own + delegated vote weight at a past timestamp.
    function getPastVotes(address guardian, uint256 timestamp) external view returns (uint256);

    /// @notice Total guardian vote weight (quorum denominator) at a past timestamp.
    function getPastTotalVotes(uint256 timestamp) external view returns (uint256);

    /// @notice Total system vote weight at a past timestamp — own-stake total
    ///         plus delegated total. Snapshot quorum/total denominator.
    function getPastTotalSupply(uint256 timestamp) external view returns (uint256);

    /// @notice Total delegated stake at a past timestamp — `totalDelegatedStake`
    ///         frozen against the global delegation history checkpoint. Used
    ///         by `GuardianRegistry.openReview` so the quorum denominator is
    ///         read at the same `t-1` anchor as the per-voter weight lookups
    ///         (closes Sherlock #35 / Run-1 #18 timestamp asymmetry).
    function getPastTotalDelegated(uint256 timestamp) external view returns (uint256);

    /// @notice Total ACTIVE-ONLY delegated stake at a past timestamp — sum of
    ///         `poolTokens[g]` over guardians g that were active at `timestamp`.
    ///         Used by `GuardianRegistry.openReview` to exclude dead-weight
    ///         delegations to inactive guardians from the quorum denominator
    ///         (Sherlock #39 / Run-1 #22).
    function getPastTotalActiveDelegated(uint256 timestamp) external view returns (uint256);

    /// @notice A delegate's DPoS commission rate (bps) frozen at a past timestamp.
    function getPastCommission(address delegate, uint256 timestamp) external view returns (uint256);

    /// @notice A delegator's stake delegated to `delegate` at a past timestamp.
    function getPastDelegation(address delegator, address delegate, uint256 timestamp) external view returns (uint256);

    /// @notice A delegate's total inbound delegated WOOD at a past timestamp.
    function getPastDelegatedInbound(address delegate, uint256 timestamp) external view returns (uint256);

    // ── Live reads ──
    /// @notice The WOOD ERC20 token sWOOD custodies. The registry reads this
    ///         for its own slash-appeal reserve (the only WOOD it touches).
    function wood() external view returns (address);
    function isActiveGuardian(address guardian) external view returns (bool);
    function guardianStake(address guardian) external view returns (uint256);
    function ownerStake(address vault) external view returns (uint256);
    function totalGuardianStake() external view returns (uint256);
    function totalDelegatedStake() external view returns (uint256);
    function delegationOf(address delegator, address delegate) external view returns (uint256);
    function delegatedInbound(address delegate) external view returns (uint256);
    function commissionOf(address delegate) external view returns (uint256);
    function preparedStakeOf(address owner) external view returns (uint256);
    function canCreateVault(address owner) external view returns (bool);

    /// @notice The guardian unstake cooldown period. The registry reads this
    ///         in `setReviewPeriod` to enforce the `coolDownPeriod >=
    ///         reviewPeriod` cross-contract invariant (Sherlock #16).
    function coolDownPeriod() external view returns (uint256);

    /// @notice Lower clamp bound (bps) for the graduated slash severity.
    function minSlashBps() external view returns (uint256);

    /// @notice Upper clamp bound (bps) for the graduated slash severity.
    function maxSlashBps() external view returns (uint256);

    // ── Registry-only mutations ──
    /// @notice Slash `approvers` by `slashBps` for a blocked proposal. Burns
    ///         each approver's own stake plus a pro-rata share of their
    ///         delegated pool. Registry-only.
    /// @param proposalId The blocked proposal whose approvers are slashed.
    /// @param approvers  Plain `address[]` of approver addresses to slash.
    /// @param slashBps   Slash fraction in basis points.
    function slashGuardians(uint256 proposalId, address[] calldata approvers, uint256 slashBps) external;

    /// @notice Burn the owner bond bound to `vault` (emergency-settle failure).
    ///         Registry-only.
    function slashOwnerBond(address vault) external;

    /// @notice Snapshot a voter's vote weight for a proposal so a later
    ///         `slashGuardians` can slash the exact amount voted with.
    ///         Registry-only.
    function recordVoteStake(uint256 proposalId, address voter, uint128 weight) external;

    // ── Admin (owner-instant; owner is a multisig with external delay) ──
    function setMinGuardianStake(uint256 newMin) external;
    function setMinOwnerStake(uint256 newMin) external;
    function setCooldownPeriod(uint256 newPeriod) external;
    function setDelegationEnabled(bool enabled) external;
    function setMinSlashBps(uint256 newBps) external;
    function setMaxSlashBps(uint256 newBps) external;
}
