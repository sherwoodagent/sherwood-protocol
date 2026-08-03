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

    /// @notice A verdict slash was settled: what it took, all of which was
    ///         destroyed.
    /// @dev ONE FIELD, BECAUSE THERE IS ONE LEG. `gross == burned` by
    ///      construction — the slash has no payee — so there is no split for an
    ///      indexer to re-derive. `burned` is also `slashVerdict`'s return
    ///      value. Replaces the `VerdictSlashRouted` /
    ///      `VerdictSlashUncompensated` pair, whose whole purpose was to report
    ///      WHETHER victims were paid — a question with one answer now. The
    ///      prosecutor's fee is a separate leg on a separate contract and
    ///      surfaces as `IProposerBondEscrow.ProsecutorFeePaid`.
    event VerdictSlashBurned(bytes32 indexed caseKey, uint256 burned);

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

    /// @notice Consent to having your prepared owner stake bound to `vault` by
    ///         the factory's owner-rotation flow (issue #98). Callable only by
    ///         the prospective owner themselves; one approved vault per
    ///         address, overwritten on re-approval, consumed by the bind.
    function approveOwnerStakeBinding(address vault) external;

    /// @notice Withdraw a previously granted binding consent.
    function revokeOwnerStakeBinding() external;

    /// @notice Re-point a vault's owner-stake slot to `newOwner`'s prepared
    ///         stake. Reverts `BindingNotApproved` unless `newOwner` approved
    ///         exactly `vault` first.
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

    /// @notice The single vault `owner` has consented to have their prepared
    ///         stake bound to. Zero when there is no standing consent.
    function approvedBindVault(address owner) external view returns (address);

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
    /// @return total  WOOD burned across all approvers. The slash pays no one;
    ///                the prosecutor is paid from the convicted proposer's bond
    ///                by `ProposerBondEscrow`, the one pot a prosecutor cannot
    ///                fund for itself.
    function slashVerdict(
        bytes32 caseKey,
        uint256 openedAt,
        address[] calldata approvers,
        uint256[] calldata slashBpsPer
    ) external returns (uint256 total);

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
