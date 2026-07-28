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
    /// @notice Reverts when a non-slasher calls the verdict slash path.
    error NotAuthorizedSlasher();

    /// @notice Reverts when `slashToEscrow` runs with no `compensationEscrow`
    ///         configured. The sink is owner-set state, never a caller argument.
    error CompensationEscrowNotSet();

    /// @notice Reverts when the requested compensation snapshot is LATER than
    ///         the verdict's own open timestamp.
    error SnapshotAfterVerdict();

    /// @notice Reverts when `slashToEscrow` is handed a rate array whose length
    ///         does not match `approvers`. Positional alignment is the only
    ///         thing binding a guardian to their own rate, so a mismatch is a
    ///         caller bug that would otherwise slash the tail of the batch at a
    ///         rate nobody chose.
    error SlashBpsLengthMismatch();

    /// @notice Reverts when `slashToEscrow`'s `openedAt` is in the future — the
    ///         at-open anchor the slash legs are sized against must be a real
    ///         past instant.
    error VerdictNotPast();

    /// @notice Reverts when `slashToEscrow`'s `approvers` names an address
    ///         twice — the dedup that keeps a repeated approver from
    ///         compounding past `maxSlashBps`. Order is NOT constrained
    ///         (`ExposureLedger.slashBpsFor` feeds vote-order arrays).
    error DuplicateApprover();

    /// @notice Reverts when `slashToEscrow` names an approver already slashed
    ///         under the same `caseKey` by an EARLIER call (PR #24 review 🟠N2).
    /// @dev The intra-call dedup only bounds ONE array, so the severity ceiling
    ///      bound per CALL rather than per verdict: `_slashOne` re-reads the
    ///      live stake each time while sizing off the same `openedAt`
    ///      checkpoint, so three sequential 5,000-bps calls against one
    ///      approver take 8,750 bps of the bond they held at open — against a
    ///      50% ceiling governance set. Splitting a quorum-sized batch across
    ///      transactions stays legal (the natural workaround for a 100-approver
    ///      batch that does not fit a block); replaying an approver does not.
    ///      Also makes an honest retried transaction idempotent per approver.
    error ApproverAlreadySlashed();

    /// @dev `slashToEscrow`'s `vault` does not resolve to a governor in the
    ///      factory (`governorOf(vault) == 0`). The escrow apportions against
    ///      the vault's ERC20Votes checkpoints, and every safety claim about
    ///      that population assumes OZ semantics — which only factory-deployed
    ///      vaults are known to carry (PR #24 round-4 N-4).
    error VaultNotFactoryDeployed();

    event AuthorizedSlasherSet(address indexed slasher);
    event CompensationEscrowSet(address indexed escrow);

    /// @notice Correlates a verdict slash with the escrow case it funded, so
    ///         Plan D and indexers can join the two without scraping the escrow.
    event VerdictSlashRouted(bytes32 indexed caseKey, address indexed vault, uint256 total, uint256 caseId);

    /// @notice A verdict slash whose compensation case could not be opened
    ///         (`openCase` reverted); the proceeds were burned instead. The
    ///         guardian is still slashed; the case's victims go uncompensated.
    event VerdictSlashUncompensated(bytes32 indexed caseKey, address indexed vault, uint256 total);

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
    // different concept. Vote weight = AGE-WEIGHTED own staked +
    // delegated-inbound capped at `delegatedWeightCapX ×` aged own.

    /// @notice An account's CURRENT vote weight: age-weighted own votable
    ///         stake + k-capped delegated inbound. Live counterpart of
    ///         `getPastVotes`.
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
    /// @notice Slash `approvers` for a blocked proposal. Burns `slashBps` of
    ///         each approver's own stake plus `min(slashBps,
    ///         maxDelegatedSlashBps)` of their delegated pools (pro-rata via
    ///         the share model); the uncovered delegated remainder spills onto
    ///         the approver's own remaining stake (first-loss bond, spec
    ///         2026-07-19 Part A). Registry-only.
    /// @param reviewKey  Composite review key keccak256(abi.encode(governor, proposalId)) whose approvers are slashed.
    /// @param openedAt   The review's open timestamp. `_slashOne` sizes each
    ///                   approver's own slash off their raw own-stake
    ///                   checkpoint at this instant and the delegated legs off
    ///                   `getPastDelegatedInbound(approver, openedAt)` — two
    ///                   disjoint at-open snapshots (Sherlock run #3 #6: no
    ///                   double-slash of the delegated contribution).
    /// @param approvers  Plain `address[]` of approver addresses to slash.
    /// @param slashBps   Slash fraction in basis points.
    function slashGuardians(bytes32 reviewKey, uint256 openedAt, address[] calldata approvers, uint256 slashBps)
        external;

    /// @notice Burn the owner bond bound to `vault` (emergency-settle failure).
    ///         Registry-only.
    function slashOwnerBond(address vault) external;

    // ── Slasher-only mutations (verdict path) ──
    /// @notice Verdict-driven slash whose proceeds fund victim compensation
    ///         instead of burning (spec §3.8 + §4 authorized-slasher entrypoint).
    /// @dev The escrow is NOT a parameter: it is owner-set state
    ///      (`compensationEscrow`), because sWOOD custodies every WOOD bond in
    ///      the protocol and a caller-named sink would carry an allowance
    ///      against that balance. Each non-zero rate is clamped to
    ///      `[minSlashBps, maxSlashBps]` — the same severity envelope the
    ///      review path's `_severityBps` enforces. `approvers` must be
    ///      duplicate-free (any order) AND must not repeat an approver already
    ///      slashed under this `caseKey` by an earlier call
    ///      (`ApproverAlreadySlashed`) — one verdict takes one slash per
    ///      approver, so the envelope binds per VERDICT and not merely per
    ///      call. `openedAt` must not be in the future
    ///      and `snapshotTimestamp` must be at or before `openedAt` — honest-
    ///      caller sanity bounds; they do NOT bind a compromised slasher, which
    ///      chooses both timestamps freely (see the implementation natspec).
    ///      If `openCase` reverts (unpriceable vault), the slash stands and the
    ///      proceeds BURN (`VerdictSlashUncompensated`), so a bad vault cannot
    ///      brick the verdict.
    /// @return total  WOOD routed to the escrow across all approvers.
    /// @return caseId The escrow case funded, or 0 when nothing was recovered.
    function slashToEscrow(
        bytes32 caseKey,
        uint256 openedAt,
        address[] calldata approvers,
        uint256[] calldata slashBpsPer,
        address vault,
        uint256 snapshotTimestamp
    ) external returns (uint256 total, uint256 caseId);

    function setAuthorizedSlasher(address slasher) external;
    function authorizedSlasher() external view returns (address);
    function setCompensationEscrow(address escrow) external;
    function compensationEscrow() external view returns (address);

    /// @notice Whether `approver` has already been slashed under `caseKey`.
    /// @dev Lets a slasher (Plan D, or a keeper resuming a batch that ran out
    ///      of gas) resume a split verdict without re-slashing anyone.
    function verdictSlashed(bytes32 caseKey, address approver) external view returns (bool);

    // ── Admin (owner-instant; owner is a multisig with external delay) ──
    function setMinGuardianStake(uint256 newMin) external;
    function setMinOwnerStake(uint256 newMin) external;
    function setCooldownPeriod(uint256 newPeriod) external;
    function setDelegationEnabled(bool enabled) external;
    function setMinSlashBps(uint256 newBps) external;
    function setMaxSlashBps(uint256 newBps) external;
}
