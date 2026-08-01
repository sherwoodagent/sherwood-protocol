// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IExposureLedger
/// @notice Dollar-denominated aggregate exposure cap + covered-TVL cap +
///         approve-quorum arithmetic (spec 2026-07-22 §3.3, §3.3a, §3.7).
///         Singleton; consumed by GuardianRegistry (exposure recording at
///         approve-vote time) and SyndicateGovernor (covered-TVL check at
///         propose, approve-quorum check at execute).
interface IExposureLedger {
    // ── Errors ──
    /// @notice RETAINED FOR ABI STABILITY, no longer thrown. The exposure cap
    ///         is enforced by booking zero rather than by reverting the vote
    ///         (review N1); indexers and off-chain decoders that already know
    ///         this selector keep working.
    error ExposureCapExceeded();
    error CoveredTvlCapExceeded();

    /// @notice Reverts when a proposal's settlement (`executeBy +
    ///         strategyDuration`) lands further ahead than the ledger will book
    ///         a commitment for. Signals a duration ceiling set out of step with
    ///         the epoch length, rather than silently under-covering the tail.
    error CoverageHorizonExceeded();

    /// @notice `settleCoverage` called before the review window shut, while the
    ///         approver set can still change.
    error ReviewNotClosed();

    /// @notice Emitted when reservations collapse to allocations for a proposal.
    event CoverageSettled(bytes32 indexed reviewKey, uint256 reservedTotal, uint256 allocatedTotal);
    error InsufficientApproveCoverage();
    error NotGuardianRegistry();
    error FeedNotConfigured();
    error StalePrice();
    error InvalidParameter();
    error ZeroAddress();
    error NotCoverageFreezer();
    error CoverageFrozen();

    // ── Events ──
    event WoodUsdPriceSet(uint256 oldPriceX8, uint256 newPriceX8);
    event WoodFeedSet(address indexed feed, uint256 maxDelay);
    event GuardianRegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event AssetFeedSet(address indexed asset, address feed, uint256 maxDelay, uint8 assetDecimals);
    event ExposureRecorded(address indexed guardian, bytes32 indexed reviewKey, uint256 usd, uint256 epoch);
    event ExposureReleased(address indexed guardian, bytes32 indexed reviewKey, uint256 usd, uint256 epoch);
    event ParameterChangeFinalized(bytes32 indexed paramKey, uint256 oldValue, uint256 newValue);
    event CoverageFreezerSet(address indexed oldFreezer, address indexed newFreezer);
    event CoverageFrozenSet(address indexed governor, uint256 indexed proposalId, bool frozen);

    // ── Registry-only mutations ──
    function recordApproval(address governor, uint256 proposalId, address guardian) external;
    function releaseApproval(address governor, uint256 proposalId, address guardian) external;

    // ── Governor-consumed checks (view) ──
    function requireWithinCoveredTvlCap(address asset, uint256 requiredCoverage) external view;

    /// @notice Reverts when a proposal's settlement lands beyond the ledger's
    ///         booking horizon. Called at propose so the error lands on the
    ///         proposer rather than on the guardian cohort.
    function requireWithinCoverageHorizon(uint256 executeBy, uint256 strategyDuration) external view;
    function requireApproveQuorum(address governor, uint256 proposalId, address asset, uint256 requiredCoverage)
        external
        view;

    // ── Coverage freeze (challenge game, spec §3.4) ──
    function freezeCoverage(address governor, uint256 proposalId) external;
    function unfreezeCoverage(address governor, uint256 proposalId) external;
    function isCoverageFrozen(address governor, uint256 proposalId) external view returns (bool);
    /// @notice Whether ANY frozen proposal names this guardian as a covering
    ///         approver. sWOOD gates the unstake CLAIM on it, which is what
    ///         makes the freeze load-bearing rather than decorative: epoch
    ///         buckets age out on wall-clock and a disputed challenge outlives
    ///         them, so `openExposureUsd` alone let an accused guardian claim
    ///         its bond mid-accusation (review 🔴F2 / 🟠F6).
    function hasFrozenCoverage(address guardian) external view returns (bool);
    /// @dev Zero is legal and deliberate — it is the UNWIRE switch, which
    ///      closes the freeze surface when the challenge game is replaced. Not
    ///      an oversight: with no freezer wired there is no filing, so the
    ///      unwired state fails closed for the game rather than open.
    ///
    ///      REFUSED WHILE ANY COVERAGE IS FROZEN (review 🟠F11). Failing closed
    ///      for NEW filings is not the same as being safe for the LIVE ones:
    ///      `unfreezeCoverage` is `onlyFreezer` and the game is its only caller,
    ///      so rotating the role mid-challenge orphaned that freeze — the game's
    ///      `resolve()` reverted forever, both bonds stranded with no withdrawal
    ///      path, and every accused approver was permanently barred from
    ///      `claimUnstakeGuardian`. The rotation is therefore DEFERRED, not
    ///      forbidden: drain the live challenges until `frozenCoverageCount()`
    ///      is zero, then re-point.
    function setCoverageFreezer(address freezer) external;
    function coverageFreezer() external view returns (address);
    /// @notice How many proposals are frozen right now, across every guardian.
    ///         Zero is the precondition for rotating `coverageFreezer`, so this
    ///         is the read governance sequences a role change against.
    function frozenCoverageCount() external view returns (uint256);

    // ── Views ──
    /// @notice The covering approvers of a proposal and the USD each committed.
    ///         A released commitment reports a zero share rather than being
    ///         dropped, so a caller sees the full historical set.
    function approversOf(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory committedUsd);

    /// @notice Per-approver slash rates for a proposal, in bps of each
    ///         guardian's own slashable stake, positionally aligned with the
    ///         returned approver list.
    /// @dev    Feeds `IStakedWood.slashVerdict` directly. PUNITIVE: every
    ///         approver still holding a live commitment returns the full
    ///         `BPS_DENOMINATOR`, which `_slashOne` then clamps into
    ///         `[minSlashBps, maxSlashBps]` — so the severity ceiling is
    ///         applied at one governance-controlled site rather than read
    ///         twice. A guardian who booked nothing, or released by changing
    ///         their vote, returns 0 and is slashed nothing.
    ///
    ///         The rate is INDEPENDENT of the loss: it reads no required
    ///         coverage, no allocation, and no price feed. That last point is
    ///         a liveness property worth keeping — the allocation this
    ///         replaced priced both operands, so a stale asset feed made a
    ///         conviction unpriceable and reverted this view, precisely during
    ///         the market stress a drain happens in.
    function slashBpsFor(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory bps);
    /// @notice What `guardian` actually carries on this proposal, after the
    ///         pro-rata scale-back — as opposed to the deliberately over-sized
    ///         amount `recordApproval` reserved.
    /// @dev    Reservations are per-approver and each may run up to the full
    ///         coverage, so the real split is computed at read time from
    ///         whoever is still an approver. This is the number a conviction
    ///         should slash against; the raw reservation would over-slash.
    function allocatedUsd(address governor, uint256 proposalId, address guardian) external view returns (uint256);

    /// @notice What a conviction on this proposal can ACTUALLY take, in USD-18 —
    ///         the cohort's whole liability, not the sum of what it reserved.
    /// @dev    Summing `approversOf` overstates this by a factor that GROWS WITH
    ///         THE APPROVER COUNT: `recordApproval` deliberately reserves up to
    ///         the full coverage from every approver, because at vote time any
    ///         one of them might end up carrying it alone. `allocatedUsd`
    ///         prices against the allocation for exactly that reason.
    ///         (`slashBpsFor` once did too; it is now punitive and prices
    ///         against nothing.)
    ///
    ///         This exposes the same figure as ONE number, so callers outside
    ///         the ledger need not re-derive the reservation/allocation
    ///         distinction — re-deriving it is how `ChallengeGame.file()` came
    ///         to size the challenger's bond off reservations, charging more to
    ///         challenge a proposal the better covered it was (review 🟡F13).
    ///
    ///         `min(needUsd, effectiveTotal)`: allocations sum to the need when
    ///         the cohort can cover it, and are bounded by what the cohort can
    ///         actually pay when it cannot.
    function liabilityUsd(address governor, uint256 proposalId) external view returns (uint256);

    /// @notice Return each approver's over-reservation once the review has shut
    ///         and the approver set is final. Permissionless; safe to skip.
    /// @dev    RE-RUNNABLE, and a caller that prices money off a settled
    ///         proposal should re-run it first. Each pass re-derives the whole
    ///         split from the pledges recorded at vote time, at the CURRENT
    ///         price, so a pass taken while WOOD or the vault asset was
    ///         depressed leaves a stale number the next pass corrects rather
    ///         than a permanent one. It was one-shot originally, which let any
    ///         caller pick an instant that permanently reduced what a conviction
    ///         could recover (review H1). No pass can book a guardian above its
    ///         own pledge, in either direction.
    function settleCoverage(address governor, uint256 proposalId) external;

    function slashableBondUsd(address guardian) external view returns (uint256);
    function openExposureUsd(address guardian) external view returns (uint256);
    function coverageUsd(address asset, uint256 amount) external view returns (uint256);
    function proposerBondWood(address asset, uint256 requiredCoverage) external view returns (uint256);
    function currentEpoch() external view returns (uint256);
    function woodUsdPriceX8() external view returns (uint256);
    function woodPriceX8() external view returns (uint256);

    /// @notice The WOOD price plus whether it came from the fallback rather than
    ///         the feed — so monitoring can observe the degraded path.
    function woodPriceDetail() external view returns (uint256 price, bool usingFallback);
    function woodHaircutBps() external view returns (uint256);
    function epochLength() external view returns (uint256);
    function challengeWindow() external view returns (uint256);
    function kNumerator() external view returns (uint256);
    function coveredTvlCapUsd() external view returns (uint256);
    function quorumTierThreshold() external view returns (uint8);
    function proposerBondBps() external view returns (uint256);

    // ── Owner setters ──
    function setWoodUsdPrice(uint256 newPriceX8) external;
    function setWoodFeed(address feed, uint256 maxDelay) external;
    function setWoodHaircutBps(uint256 newBps) external;
    function setAssetFeed(address asset, address feed, uint256 maxDelay) external;
    function setGuardianRegistry(address registry) external;
    function setChallengeWindow(uint256 newWindow) external;
    function setKNumerator(uint256 newK) external;
    function setCoveredTvlCapUsd(uint256 newCap) external;
    function setQuorumTierThreshold(uint8 newThreshold) external;
    function setProposerBondBps(uint256 newBps) external;
}
