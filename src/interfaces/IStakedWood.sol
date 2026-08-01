// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IStakedWood
/// @notice Interface for the StakedWood (sWOOD) contract — the sole WOOD-token
///         custodian, holding guardian staking, owner bonds, vote
///         checkpoints, and slashing. `GuardianRegistry`, `SyndicateGovernor`,
///         and `SyndicateFactory` call sWOOD through this interface.
/// @dev See `openspec/specs/guardian-staking/spec.md`. Checkpoint reads are
///      timestamp-keyed (EIP-6372 timestamp-mode clock).
interface IStakedWood {
    /// @notice Reverts when a non-slasher calls the verdict slash path.
    error NotAuthorizedSlasher();

    /// @notice Reverts when `slashVerdict` is handed a rate array whose length
    ///         does not match `approvers`. Positional alignment is the only
    ///         thing binding a guardian to their own rate, so a mismatch is a
    ///         caller bug that would otherwise slash the tail of the batch at a
    ///         rate nobody chose.
    error SlashBpsLengthMismatch();

    /// @notice Reverts when `slashVerdict`'s `openedAt` is in the future — the
    ///         at-open anchor the slash legs are sized against must be a real
    ///         past instant.
    error VerdictNotPast();

    /// @notice Reverts when `slashVerdict`'s `approvers` names an address
    ///         twice — the dedup that keeps a repeated approver from
    ///         compounding past `maxSlashBps`. Order is NOT constrained
    ///         (`ExposureLedger.slashBpsFor` feeds vote-order arrays).
    error DuplicateApprover();

    /// @notice Reverts when `slashVerdict` names an approver already slashed
    ///         under the same `caseKey` by an EARLIER call.
    /// @dev The intra-call dedup only bounds ONE array, so the severity ceiling
    ///      bound per CALL rather than per verdict: `_slashOne` re-reads the
    ///      live stake each time while sizing off the same `openedAt`
    ///      checkpoint, so repeated calls against one approver can exceed the
    ///      governance-set ceiling. Splitting a quorum-sized batch across
    ///      transactions stays legal; replaying an approver does not. Also
    ///      makes a retried transaction idempotent per approver.
    error ApproverAlreadySlashed();

    event AuthorizedSlasherSet(address indexed slasher);

    /// @notice A verdict slash was settled: what it took, what the prosecutor
    ///         was paid, and what was destroyed.
    /// @dev `gross == bounty + burned` by construction, so an indexer never has
    ///      to re-derive the split. `burned` is also `slashVerdict`'s return
    ///      value. Replaces the `VerdictSlashRouted` / `VerdictSlashUncompensated`
    ///      pair, whose whole purpose was to report WHETHER victims were paid —
    ///      a question with one answer now.
    event VerdictSlashBurned(bytes32 indexed caseKey, uint256 gross, uint256 bounty, uint256 burned);

    /// @notice A conviction bounty was paid out of a verdict slash before the
    ///         remainder opened a compensation case.
    event ConvictionBountyPaid(bytes32 indexed caseKey, address indexed bountyTo, uint256 amount);

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

    // ── Snapshot-compatible vote-read surface (timestamp-keyed) ──
    //
    // `getVotes` / `getPastVotes` / `getPastTotalSupply` form the read surface
    // Snapshot's `erc20-votes` strategy consumes. sWOOD does not implement the
    // full OZ `IVotes` (no `delegate` / `delegates` / `delegateBySig`). Vote
    // weight = age-weighted own staked WOOD; there is no delegated component.

    /// @notice An account's CURRENT vote weight: age-weighted own votable
    ///         stake. Live counterpart of `getPastVotes`.
    function getVotes(address account) external view returns (uint256);

    /// @notice Guardian's age-weighted own vote weight at a past timestamp.
    /// @dev    Not a term of `getPastTotalVotes`: the total sums RAW own
    ///         stake; this applies `_ageFactorBps` on top, so the two are
    ///         different measures of the same WOOD. Correct for weighing a
    ///         vote; wrong for a subtraction against the total — use
    ///         `getPastStake` there. Aging only ever shrinks weight, so
    ///         per-account weight is bounded above by raw stake, biasing
    ///         `TokenCourt._participationFloor` too HIGH when the accused are
    ///         freshly staked (favoring an inconclusive result).
    function getPastVotes(address guardian, uint256 timestamp) external view returns (uint256);

    /// @notice A guardian's RAW votable own stake at a past timestamp — the same
    ///         basis `getPastTotalVotes` sums, so the two are comparable and
    ///         subtractable. This is the operand `TokenCourt._participationFloor`
    ///         needs; `getPastVotes` there would let delegation drive the floor
    ///         to zero.
    function getPastStake(address guardian, uint256 timestamp) external view returns (uint256);

    /// @notice Total guardian vote weight (quorum denominator) at a past timestamp.
    /// @dev    A sum of RAW own stake. Pair it with `getPastStake`, never with
    ///         `getPastVotes`.
    function getPastTotalVotes(uint256 timestamp) external view returns (uint256);

    /// @notice Total system vote weight at a past timestamp — the raw own-stake
    ///         total. Snapshot quorum/total denominator.
    function getPastTotalSupply(uint256 timestamp) external view returns (uint256);

    // ── Live reads ──
    /// @notice The WOOD ERC20 token sWOOD custodies. The registry reads this
    ///         for its own slash-appeal reserve (the only WOOD it touches).
    function wood() external view returns (address);
    function isActiveGuardian(address guardian) external view returns (bool);
    function guardianStake(address guardian) external view returns (uint256);
    function ownerStake(address vault) external view returns (uint256);
    function totalGuardianStake() external view returns (uint256);
    function preparedStakeOf(address owner) external view returns (uint256);
    function canCreateVault(address owner) external view returns (bool);

    /// @notice The guardian unstake cooldown period. The registry reads this
    ///         in `setReviewPeriod` to enforce the cross-contract invariant
    ///         `coolDownPeriod >= reviewPeriod`.
    function coolDownPeriod() external view returns (uint256);

    /// @notice Lower clamp bound (bps) for the graduated slash severity.
    function minSlashBps() external view returns (uint256);

    /// @notice Upper clamp bound (bps) for the graduated slash severity.
    function maxSlashBps() external view returns (uint256);

    // ── Registry-only mutations ──
    /// @notice Slash `approvers` for a blocked proposal. Burns `slashBps` of
    ///         each approver's own stake. Registry-only.
    /// @param reviewKey  Composite review key keccak256(abi.encode(governor, proposalId)) whose approvers are slashed.
    /// @param openedAt   The review's open timestamp. `_slashOne` sizes each
    ///                   approver's slash off their raw own-stake checkpoint
    ///                   at this instant.
    /// @param approvers  Plain `address[]` of approver addresses to slash.
    /// @param slashBps   Slash fraction in basis points.
    function slashGuardians(bytes32 reviewKey, uint256 openedAt, address[] calldata approvers, uint256 slashBps)
        external;

    /// @notice Burn the owner bond bound to `vault` (emergency-settle failure).
    ///         Registry-only.
    function slashOwnerBond(address vault) external;

    // ── Slasher-only mutations (verdict path) ──
    /// @notice Verdict-driven slash whose proceeds are BURNED (spec §3.8 + §4
    ///         authorized-slasher entrypoint).
    /// @dev PUNITIVE, NOT COMPENSATORY. Nothing is paid to the harmed vault or
    ///      its holders — the protocol makes no compensation promise. Each
    ///      non-zero rate is clamped to `[minSlashBps, maxSlashBps]`, the same
    ///      severity envelope the review path's `_severityBps` enforces, and
    ///      the production feed (`ExposureLedger.slashBpsFor`) supplies the
    ///      ceiling for every approver still holding a live commitment.
    ///
    ///      `approvers` must be duplicate-free (any order) AND must not repeat
    ///      an approver already slashed under this `caseKey` by an earlier call
    ///      (`ApproverAlreadySlashed`) — one verdict takes one slash per
    ///      approver, so the envelope binds per VERDICT and not merely per
    ///      call. `openedAt` must not be in the future: an honest-caller sanity
    ///      bound that does NOT bind a compromised slasher, which chooses it
    ///      freely (see the implementation natspec).
    ///
    ///      NO EXTERNAL SINK. The burn is unconditional and internal, so there
    ///      is no child call whose revert could hold a conviction hostage, no
    ///      allowance against sWOOD's custody balance, and no gas to reserve
    ///      for a callee.
    /// @dev    THE BOUNTY IS THE PROSECUTOR'S FEE (spec 2026-07-29 §2). It is
    ///         paid only when a slash actually recovers WOOD, and it is
    ///         deducted BEFORE the burn. `bountyTo == address(0)` or
    ///         `bountyBps == 0` disables it and the whole slash burns — which
    ///         is how the caller expresses "this path pays no bounty" (see
    ///         `ChallengeGame._settle`: only an ESCALATED conviction pays,
    ///         never the silence settle).
    ///
    ///         `bountyBps` IS NOT TRUSTED FROM THE CALLER. sWOOD rejects it
    ///         outside `[0, MAX_CONVICTION_BOUNTY_BPS]` itself
    ///         (`InvalidParameter`, including any value `>= 10_000`) — the
    ///         same MOTIVATION as re-checking `slashBpsPer` against
    ///         `[minSlashBps, maxSlashBps]` rather than trusting it from
    ///         `ExposureLedger`, though the MECHANISM differs: `slashBpsPer`
    ///         is silently clamped, `bountyBps` reverts. `ChallengeGame` also
    ///         pins its own rate to this range at filing, but that bound
    ///         lives in the CALLER; sWOOD is the contract that actually moves
    ///         the WOOD, so a compromised or buggy slasher can divert at most
    ///         `MAX_CONVICTION_BOUNTY_BPS` of any ONE CALL's slash to a
    ///         caller-named `bountyTo` — that call's remainder can only ever
    ///         reach `BURN_ADDRESS`, never an arbitrary destination of the
    ///         slasher's own choosing. PER CALL, NOT PER GUARDIAN:
    ///         `verdictSlashed` keys on a caller-chosen `caseKey`, so repeated
    ///         verdicts against the same approver under fresh case keys
    ///         compound.
    /// @param  bountyTo   Recipient of the conviction bounty, or `address(0)`.
    /// @param  bountyBps  Slice of the recovered total, in bps. Rejected
    ///                     outside `[0, MAX_CONVICTION_BOUNTY_BPS]` by sWOOD
    ///                     itself (reverts, not silently clamped down).
    /// @return total  WOOD burned across all approvers, NET of the conviction
    ///                bounty — the `burned` leg of `VerdictSlashBurned`.
    /// @param  contestors Positionally aligned with `approvers`: true where that
    ///         approver funded the counter-bond. Their SUMMED slash caps the
    ///         bounty, so staging a contest can never pay more than it costs
    ///         the stager — the bound the punitive rate would otherwise break,
    ///         since the bounty is a share of the whole cohort's bonds while a
    ///         faker risks only its own.
    function slashVerdict(
        bytes32 caseKey,
        uint256 openedAt,
        address[] calldata approvers,
        uint256[] calldata slashBpsPer,
        bool[] calldata contestors,
        address bountyTo,
        uint256 bountyBps
    ) external returns (uint256 total);

    /// @notice The authoritative ceiling on `slashVerdict`'s `bountyBps` —
    ///         read this rather than restating the literal bps value
    ///         elsewhere (e.g. in `ChallengeGame`), so a caller's own clamp
    ///         and sWOOD's enforced one cannot silently drift apart.
    function MAX_CONVICTION_BOUNTY_BPS() external view returns (uint256);

    function setAuthorizedSlasher(address slasher) external;
    function authorizedSlasher() external view returns (address);

    /// @notice Whether `approver` has already been slashed under `caseKey`.
    /// @dev Lets a slasher (e.g. a keeper resuming a batch that ran out of
    ///      gas) resume a split verdict without re-slashing anyone.
    function verdictSlashed(bytes32 caseKey, address approver) external view returns (bool);

    // ── Admin (owner-instant; owner is a multisig with external delay) ──
    function setMinGuardianStake(uint256 newMin) external;
    function setMinOwnerStake(uint256 newMin) external;
    function setCooldownPeriod(uint256 newPeriod) external;
    function setMinSlashBps(uint256 newBps) external;
    function setMaxSlashBps(uint256 newBps) external;
}
