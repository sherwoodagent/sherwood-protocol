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

    /// @notice Reverts when `slashToEscrow` runs with no `compensationEscrow`
    ///         configured. The sink is owner-set state, never a caller argument.
    error CompensationEscrowNotSet();

    /// @notice Reverts when the requested compensation snapshot is LATER than
    ///         the verdict's own open timestamp.
    error SnapshotAfterVerdict();

    /// @notice Reverts when `slashToEscrow`'s rate array length does not match
    ///         `approvers`. Positional alignment binds each guardian to their
    ///         own rate.
    error SlashBpsLengthMismatch();

    /// @notice Reverts when `slashToEscrow`'s `openedAt` is in the future — the
    ///         at-open anchor the slash legs are sized against must be a real
    ///         past instant.
    error VerdictNotPast();

    /// @notice Reverts when `slashToEscrow`'s `approvers` names an address
    ///         twice — the dedup keeps a repeated approver from compounding
    ///         past `maxSlashBps`. Order is not constrained
    ///         (`ExposureLedger.slashBpsFor` feeds vote-order arrays).
    error DuplicateApprover();

    /// @notice Reverts when `slashToEscrow` names an approver already slashed
    ///         under the same `caseKey` by an earlier call.
    /// @dev The intra-call dedup only bounds one array, so the severity
    ///      ceiling binds per CALL, not per verdict: `_slashOne` re-reads the
    ///      live stake each time while sizing off the same `openedAt`
    ///      checkpoint, so repeated calls against one approver can exceed the
    ///      governance-set ceiling. Splitting a quorum-sized batch across
    ///      transactions stays legal; replaying an approver does not. Also
    ///      makes a retried transaction idempotent per approver.
    error ApproverAlreadySlashed();

    /// @dev `slashToEscrow`'s `vault` does not resolve to a governor in the
    ///      factory (`governorOf(vault) == 0`). The escrow apportions against
    ///      the vault's ERC20Votes checkpoints, which only factory-deployed
    ///      vaults are guaranteed to carry OZ semantics for.
    error VaultNotFactoryDeployed();

    event AuthorizedSlasherSet(address indexed slasher);
    event CompensationEscrowSet(address indexed escrow);

    /// @notice Correlates a verdict slash with the escrow case it funded, so
    ///         indexers can join the two without scraping the escrow.
    /// @dev `total` is NET of any conviction bounty — it equals the escrow's
    ///      own `proceeds` for this case.
    event VerdictSlashRouted(bytes32 indexed caseKey, address indexed vault, uint256 total, uint256 caseId);

    /// @notice A verdict slash whose compensation case could not be opened
    ///         (`openCase` reverted); the proceeds were burned instead. The
    ///         guardian is still slashed; the case's victims go uncompensated.
    /// @dev `total` is NET of any conviction bounty. The bounty is paid on
    ///      this path too (see `slashToEscrow`'s dev block) — depositors
    ///      recover 0% of `total` either way, so paying it first costs them
    ///      nothing.
    event VerdictSlashUncompensated(bytes32 indexed caseKey, address indexed vault, uint256 total);

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
    /// @notice Verdict-driven slash whose proceeds fund victim compensation
    ///         instead of burning.
    /// @dev The escrow is not a parameter: it is owner-set state
    ///      (`compensationEscrow`), because sWOOD custodies every WOOD bond in
    ///      the protocol and a caller-named sink would carry an allowance
    ///      against that balance. Each non-zero rate is clamped to
    ///      `[minSlashBps, maxSlashBps]`, the same severity envelope the
    ///      review path enforces. `approvers` must be duplicate-free and must
    ///      not repeat an approver already slashed under this `caseKey` by an
    ///      earlier call (`ApproverAlreadySlashed`). `openedAt` must not be in
    ///      the future and `snapshotTimestamp` must be at or before
    ///      `openedAt` — honest-caller sanity bounds; they do not bind a
    ///      compromised slasher, which chooses both timestamps freely. If
    ///      `openCase` reverts (unpriceable vault), the slash stands and the
    ///      proceeds burn (`VerdictSlashUncompensated`), so a bad vault cannot
    ///      brick the verdict.
    /// @dev    The conviction bounty is the prosecutor's fee: paid only when a
    ///         slash recovers WOOD, deducted before `openCase` so the
    ///         escrow's `proceeds` equal what claimants can redeem.
    ///         `bountyTo == address(0)` or `bountyBps == 0` disables it,
    ///         routing the whole slash to the escrow. Paid even on the burn
    ///         fallback, since depositors recover nothing on that path
    ///         either way. `bountyBps` is enforced by sWOOD itself against
    ///         `[0, MAX_CONVICTION_BOUNTY_BPS]` (reverts, not silently
    ///         clamped) — a compromised or buggy slasher can divert at most
    ///         that fraction of any one call's slash to a caller-named
    ///         `bountyTo`; the remainder can only reach the owner-set
    ///         `compensationEscrow` or burn. The bound is per call, not per
    ///         guardian: `verdictSlashed` keys on a caller-chosen `caseKey`,
    ///         so repeated verdicts against the same approver under fresh
    ///         case keys compound.
    /// @param  bountyTo   Recipient of the conviction bounty, or `address(0)`.
    /// @param  bountyBps  Slice of the recovered total, in bps. Rejected
    ///                     outside `[0, MAX_CONVICTION_BOUNTY_BPS]` by sWOOD
    ///                     itself (reverts, not silently clamped down).
    /// @return total  WOOD routed to the escrow across all approvers, NET of
    ///                the conviction bounty. `VerdictSlashRouted` and
    ///                `VerdictSlashUncompensated` both report this NET figure.
    /// @return caseId The escrow case funded, or 0 when nothing was recovered.
    function slashToEscrow(
        bytes32 caseKey,
        uint256 openedAt,
        address[] calldata approvers,
        uint256[] calldata slashBpsPer,
        address vault,
        uint256 snapshotTimestamp,
        address bountyTo,
        uint256 bountyBps
    ) external returns (uint256 total, uint256 caseId);

    /// @notice The authoritative ceiling on `slashToEscrow`'s `bountyBps` —
    ///         read this rather than restating the literal bps value
    ///         elsewhere (e.g. in `ChallengeGame`), so a caller's own clamp
    ///         and sWOOD's enforced one cannot silently drift apart.
    function MAX_CONVICTION_BOUNTY_BPS() external view returns (uint256);

    function setAuthorizedSlasher(address slasher) external;
    function authorizedSlasher() external view returns (address);
    function setCompensationEscrow(address escrow) external;
    function compensationEscrow() external view returns (address);

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
