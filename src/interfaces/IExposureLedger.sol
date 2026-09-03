// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IExposureLedger
/// @notice WOOD-denominated guardian coverage locks + covered-TVL cap +
///         approve-quorum arithmetic. A guardian DECLARES a WOOD amount on
///         approve and the ledger locks `min(declared, k x stake - open)`; that
///         one lock is the guardian's booking, pledge and slash base for the
///         proposal. Singleton; consumed by GuardianRegistry (lock recording at
///         approve-vote time), SyndicateGovernor (covered-TVL check at propose,
///         approve-quorum check at execute) and ChallengeGame (slash rates and
///         bond sizing).
interface IExposureLedger {
    // ── Errors ──
    /// @notice Retained for ABI stability; no longer thrown. The exposure cap
    ///         is enforced by booking zero rather than by reverting the vote,
    ///         so indexers and off-chain decoders that already know this
    ///         selector keep working.
    error ExposureCapExceeded();
    error CoveredTvlCapExceeded();

    /// @notice Reverts when a proposal's settlement (`executeBy +
    ///         strategyDuration`) lands further ahead than the ledger will book
    ///         a commitment for. Signals a duration ceiling set out of step with
    ///         the epoch length, rather than silently under-covering the tail.
    error CoverageHorizonExceeded();

    error InsufficientApproveCoverage();
    error NotGuardianRegistry();
    error FeedNotConfigured();
    error StalePrice();
    error InvalidParameter();
    error ZeroAddress();
    error NotCoverageFreezer();
    error CoverageFrozen();

    /// @notice A non-zero `coverageFreezer` (the challenge game) that cannot
    ///         answer `challengeWindow()` — codeless, reverting, or returning
    ///         anything but one word. Raised by `setCoverageFreezer` on the
    ///         incoming address and by `setChallengeWindow` on the wired one
    ///         when lowering (SHE-214): the window floor is a security gate, so
    ///         an unreadable game is refused rather than waved through.
    ///         Recoverable by unwiring (`setCoverageFreezer(address(0))`).
    error CoverageFreezerUnreadable();

    /// @notice `retireApproval` called on a guardian still within an active
    ///         `pinCoverageUntil` deadline (issue #95) — a re-armable
    ///         challenge may still legally reach this commitment, so the
    ///         sweep is refused until the pin decays on its own.
    error CoveragePinnedActive();

    /// @notice `retireApproval` called before the booked epoch's challenge
    ///         window has elapsed — the same expiry `openExposure` itself
    ///         uses. Retire only what is provably past challengeability.
    error ChallengeWindowOpen();

    /// @notice No source could price WOOD: the Chainlink WOOD feed is unwired or
    ///         degraded AND the TWAP oracle is unwired or unavailable — or the
    ///         price CAP `woodUsdPriceX8` is zero.
    /// @dev    THE CAP IS NEVER SERVED AS A PRICE, so there is no branch in which
    ///         a hand-maintained scalar becomes the valuation. That is what makes
    ///         its staleness tolerable, and it is why no-market-data has to be a
    ///         revert rather than a fallback. A zero cap lands here too rather
    ///         than meaning uncapped: an unset cap would admit an unbounded market
    ///         price and hand a ~$438k pool the valuation of every guardian bond.
    ///
    ///         HALTING SEMANTICS. Every consumer lets this propagate.
    ///         `recordApproval` never reads it — the lock and the cap are WOOD —
    ///         so the approve vote keeps landing through a WOOD outage. Execution,
    ///         proposal creation, challenge filing and the fee-weight view all
    ///         halt, which is correct: no price means no proof of coverage.
    error NoWoodPrice();

    // ── Events ──
    event WoodUsdPriceSet(uint256 oldPriceX8, uint256 newPriceX8);
    event WoodFeedSet(address indexed feed, uint256 maxDelay);
    event WoodTwapOracleSet(address indexed oldOracle, address indexed newOracle);
    event GuardianRegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event AssetFeedSet(address indexed asset, address feed, uint256 maxDelay, uint8 assetDecimals);
    /// @notice `guardian` locked `wood` WOOD behind `reviewKey`, booked into
    ///         epoch bucket `epoch`. `wood` is `min(declared, free budget)`.
    event ExposureRecorded(address indexed guardian, bytes32 indexed reviewKey, uint256 wood, uint256 epoch);
    /// @notice A vote-change unwind released `guardian`'s lock of `wood` from
    ///         bucket `epoch`.
    event ExposureReleased(address indexed guardian, bytes32 indexed reviewKey, uint256 wood, uint256 epoch);
    /// @notice A dead lock was swept by `retireApproval` (audit #181 finding 11)
    ///         — a lock past its challenge window, unfrozen, and unpinned,
    ///         released from its bucket the same way `ExposureReleased` releases
    ///         a vote-change unwind.
    event ExposureRetired(address indexed guardian, bytes32 indexed reviewKey, uint256 wood, uint256 epoch);
    /// @notice A freeze, unfreeze or pin moved `guardian`'s lock between buckets (SHE-213).
    event ExposureRebucketed(
        address indexed guardian, bytes32 indexed reviewKey, uint256 wood, uint256 fromEpoch, uint256 toEpoch
    );
    event ParameterChangeFinalized(bytes32 indexed paramKey, uint256 oldValue, uint256 newValue);
    event CoverageFreezerSet(address indexed oldFreezer, address indexed newFreezer);
    event CoverageFrozenSet(address indexed governor, uint256 indexed proposalId, bool frozen);
    /// @notice A proposal's coverage was pinned open through `deadline`,
    ///         independent of whether it is currently frozen.
    event CoveragePinned(address indexed governor, uint256 indexed proposalId, uint256 deadline);

    // ── Registry-only mutations ──
    /// @notice Lock `min(lockWood, kNumerator x slashableStake(guardian) -
    ///         openExposure(guardian))` WOOD behind (governor, proposalId) for
    ///         `guardian`. Idempotent per (proposal, guardian). NEVER REVERTS on
    ///         a booking failure: a zero `lockWood`, zero required coverage, an
    ///         unpriceable vault asset, zero free budget, or settlement beyond the
    ///         coverage horizon all lock nothing and return, so the approve vote
    ///         still lands and any shortfall surfaces at the execute-time quorum.
    ///         Reads NO WOOD price. There is no cohort cap: locks across a
    ///         proposal's approvers may sum above its requirement, and nothing
    ///         reduces a lock other than `releaseApproval`/`retireApproval`.
    /// @param  lockWood The WOOD the guardian declares. Clamped, never rejected.
    function recordApproval(address governor, uint256 proposalId, address guardian, uint256 lockWood) external;
    function releaseApproval(address governor, uint256 proposalId, address guardian) external;

    /// @notice Permissionless sweep of a dead lock: once a key's booked epoch
    ///         is past its challenge window, its coverage is not frozen, and
    ///         `guardian` is not within an active `pinCoverageUntil` deadline ON
    ///         THIS (governor, proposalId) PAIR SPECIFICALLY — a pin from an
    ///         unrelated proposal the same guardian also approved does not block
    ///         this sweep — anyone may retire it.
    /// @dev    WHY THIS EXISTS: `releaseApproval` has exactly one caller, gated on
    ///         the review still being open, so a lock that survives its own
    ///         review has NO release path at all. The BUDGET recycles on its own
    ///         (`openExposure` decays every challenge window); what does not is
    ///         the lock record and the approver listing, which the freeze/pin
    ///         walks and every accused-set derivation read. Retiring bounds those
    ///         by commitments that can still be collected on.
    ///
    ///         PERMISSIONLESS AND SAFE TO SKIP: the preconditions themselves gate
    ///         correctness, and an unswept dead lock costs only list length.
    function retireApproval(address governor, uint256 proposalId, address guardian) external;

    // ── Governor-consumed checks (view) ──
    function requireWithinCoveredTvlCap(address asset, uint256 requiredCoverage) external view;

    /// @notice Reverts when a proposal's settlement lands beyond the ledger's
    ///         booking horizon. Called at propose so the error lands on the
    ///         proposer rather than on the guardian cohort.
    function requireWithinCoverageHorizon(uint256 executeBy, uint256 strategyDuration) external view;
    /// @notice Measures the covering approvers' aggregate bond against the
    ///         proposal's required coverage instead of gating all-or-nothing:
    ///         returns `(coverageRaisedUsd, requiredCoverageUsd)`, both USD-18
    ///         from the same price read, so the caller can size execution to a
    ///         coverage-proportional effective capital. Reverts only when the
    ///         approver set is empty or the raised aggregate is exactly zero.
    function requireApproveQuorum(address governor, uint256 proposalId, address asset, uint256 requiredCoverage)
        external
        view
        returns (uint256 coverageRaisedUsd, uint256 requiredCoverageUsd);

    // ── Coverage freeze (challenge game) ──
    /// @notice Freeze one proposal's coverage while a challenge is live and
    ///         re-bucket each approver's lock (raise-only) to the bucket
    ///         containing `liveUntil` (SHE-213).
    /// @param  liveUntil The challenge's worst-case end, `filedAt + disputeTimeout`.
    function freezeCoverage(address governor, uint256 proposalId, uint256 liveUntil) external;
    /// @notice Release the freeze; each lock returns to max(current, booked, pinned) bucket.
    function unfreezeCoverage(address governor, uint256 proposalId) external;
    function isCoverageFrozen(address governor, uint256 proposalId) external view returns (bool);
    /// @notice Whether ANY frozen proposal names this guardian as a covering
    ///         approver, OR this guardian is within a `pinCoverageUntil` deadline
    ///         on ANY proposal it ever approved (the guardian-scoped max). sWOOD
    ///         gates the unstake CLAIM on it, which is what makes the freeze
    ///         load-bearing: epoch buckets age out on wall-clock and a disputed
    ///         challenge outlives them.
    /// @dev    INCLUSIVE of `deadline`, matching `ChallengeGame.file`'s own
    ///         inclusive filing-deadline check, so this cannot go clean one
    ///         instant before a still-legal filing could reach it.
    function hasFrozenCoverage(address guardian) external view returns (bool);
    /// @notice Pin every approver of (governor, proposalId) as frozen through
    ///         `deadline`, regardless of freeze state. Raises BOTH the
    ///         guardian-scoped max `hasFrozenCoverage` reads and a
    ///         per-(governor, proposalId, guardian) value `retireApproval` reads
    ///         instead — a pin issued against one stale proposal must not block
    ///         sweeping a guardian's OTHER commitments. Only ever RAISES either
    ///         value; each decays on its own, so no unpin call exists or is needed.
    ///         Also re-buckets each lock to `deadline`, raise-only (SHE-213).
    function pinCoverageUntil(address governor, uint256 proposalId, uint256 deadline) external;
    /// @dev Zero is legal and deliberate — the UNWIRE switch, closing the freeze
    ///      surface when the challenge game is replaced: with no freezer wired
    ///      there is no filing, so the unwired state fails closed for the game.
    ///
    ///      Reverts while any coverage is frozen. `unfreezeCoverage` is
    ///      `onlyFreezer` and the game is its only caller, so rotating the role
    ///      mid-challenge would orphan the freeze: `resolve()` would revert
    ///      forever, both bonds would be stranded, and every accused approver
    ///      would be permanently barred from `claimUnstakeGuardian`.
    function setCoverageFreezer(address freezer) external;
    function coverageFreezer() external view returns (address);
    /// @notice How many proposals are frozen right now, across every guardian.
    ///         Zero is the precondition for rotating `coverageFreezer`, so this
    ///         is the read governance sequences a role change against.
    function frozenCoverageCount() external view returns (uint256);

    // Views
    /// @notice The covering approvers of a proposal and the WOOD each has LOCKED
    ///         behind it.
    /// @dev    NOT A HISTORICAL SET. `releaseApproval`/`retireApproval`
    ///         swap-and-pop the guardian out of the list, so a released lock is
    ///         DROPPED, not reported as zero. Every listed guardian holds a
    ///         non-zero lock, and that lock is the guardian's booking, pledge and
    ///         slash base at once — there is no second number it could differ
    ///         from. Identical to `pledgedOf`.
    function approversOf(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory lockedWood);

    /// @notice The covering approvers of a proposal and the WOOD each PLEDGED —
    ///         the same lock `approversOf` reports, under the name the
    ///         "did this guardian underwrite it?" question asks for.
    /// @dev    Historically the settle-immune half of a booking/pledge pair. With
    ///         one lock per (proposal, guardian) the pair has collapsed; this
    ///         selector survives because `ChallengeGame.file` and `TokenCourt`
    ///         derive the accused set from it, and the lock is written once by
    ///         `recordApproval` and erased only by `releaseApproval` (which reverts
    ///         `CoverageFrozen` for the whole life of a challenge) or
    ///         `retireApproval` (refused while frozen or pinned).
    function pledgedOf(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory lockedWood);

    /// @notice `guardian`'s WOOD lock behind (governor, proposalId); 0 when it
    ///         holds none (never approved, released, or retired).
    function lockOf(address governor, uint256 proposalId, address guardian) external view returns (uint256);

    /// @notice Per-approver slash rates for a proposal, in bps of each guardian's
    ///         own slashable stake, positionally aligned with the approver list.
    /// @dev    Feeds `IStakedWood.slashVerdict` directly. Each rate is the
    ///         approver's LOCK for this proposal over its slash basis
    ///         (`slashableStakeAt(g, executedAt)` once executed, live stake
    ///         before), rounded UP so the burn never falls below the lock by
    ///         truncation, saturating at 10_000 when the lock meets or exceeds the
    ///         basis or the basis is zero. A guardian with a zero lock returns 0.
    ///         `StakedWood` then clamps every non-zero rate into
    ///         `[minSlashBps, maxSlashBps]`, so the burn is `min(lock, basis)`
    ///         under the envelope and `minSlashBps` is the single deterrence
    ///         floor a small declaration cannot get under.
    ///
    ///         The rate reads NO price: lock and stake are both WOOD, so a
    ///         conviction never waits on a feed — a liveness property worth
    ///         keeping, since feed outages correlate with the market stress a
    ///         drain happens in.
    function slashBpsFor(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory bps);

    /// @notice `slashBpsFor` at an explicit slash anchor instead of the
    ///         proposal's `executedAt`. Each rate is the approver's LOCK over
    ///         `slashableStakeAt(g, anchor)` (live stake when `anchor == 0`),
    ///         rounded up, saturating at 10_000, 0 for a zero lock.
    /// @dev    The review-path slash uses this: `GuardianRegistry.resolveReview`
    ///         blocks BEFORE execution, so `executedAt` is zero and the basis
    ///         `StakedWood.slashGuardians` burns against is the stake at review
    ///         open. `anchor` is a RAW instant — sWOOD applies the same-block `-1`
    ///         hardening itself, so a caller holding a pre-hardened stamp passes
    ///         `stamp + 1`. Reverts `VerdictNotPast` (via sWOOD) on a future
    ///         anchor.
    function slashBpsForAt(address governor, uint256 proposalId, uint256 anchor)
        external
        view
        returns (address[] memory approvers, uint256[] memory bps);

    /// @notice What `guardian` underwrote on this proposal, in USD-18:
    ///         `min(lock, slashable stake) x woodPriceX8()`. UNCAPPED at the
    ///         proposal's need — a guardian who locked more risked more and earns
    ///         fee in proportion. The fee-weight read behind
    ///         `GuardianRegistry.getApproverCoverage`.
    /// @dev    Reverts `NoWoodPrice` when WOOD cannot be priced; the registry
    ///         catches that and reports `priced == false` so the caller retries
    ///         rather than paying zero through an outage.
    function coverageUsdOf(address governor, uint256 proposalId, address guardian) external view returns (uint256);

    /// @notice What a conviction on this proposal can recover FOR THIS PROPOSAL,
    ///         in USD-18: `min(needUsd, sum of min(lock_i, slashable stake_i) x
    ///         woodPriceX8())`.
    /// @dev    The cap at `needUsd` bounds BOND SIZING only: a cohort may lock
    ///         more than the proposal needs, and on conviction every full lock
    ///         still burns, but a challenger should not have to post a bond
    ///         against over-subscription it cannot recover. Reverts on an
    ///         unpriceable WOOD feed or a stale asset feed — sizing a bond off an
    ///         unvouched price is the unsafe direction.
    function liabilityUsd(address governor, uint256 proposalId) external view returns (uint256);

    /// @notice Identical to `liabilityUsd`. With no cohort cap nothing is
    ///         pro-rated across a guardian's other proposals, so there is no
    ///         longer a distinct "unshared" basis; the selector is kept because
    ///         `ChallengeGame.file` names it.
    function unsharedLiabilityUsd(address governor, uint256 proposalId) external view returns (uint256);

    function slashableBondUsd(address guardian) external view returns (uint256);
    /// @notice Sum, in WOOD, of `guardian`'s epoch buckets whose challenge window
    ///         has not elapsed — the batching-cap denominator. Pure WOOD
    ///         arithmetic; readable through any price outage.
    function openExposure(address guardian) external view returns (uint256);
    function coverageUsd(address asset, uint256 amount) external view returns (uint256);
    function proposerBondWood(address asset, uint256 requiredCoverage) external view returns (uint256);
    function currentEpoch() external view returns (uint256);

    /// @notice The WOOD/USD price CAP, 8 decimals. NEVER SERVED AS A PRICE — it
    ///         only bounds whatever the market reports, and lowering it is the
    ///         emergency brake.
    /// @dev    Seed it ABOVE market and review it monthly. A cap below market binds
    ///         permanently, pinning every bond at the cap and making the market
    ///         source inert. Zero means `NoWoodPrice`, not uncapped.
    function woodUsdPriceX8() external view returns (uint256);
    function woodPriceX8() external view returns (uint256);

    /// @notice The WOOD price, which source produced it, and whether the cap is
    ///         currently binding — so monitoring can observe both degraded paths
    ///         without an event.
    /// @param  price       `_haircut(min(market, cap))`, floored at 1.
    /// @param  fromFeed    True when a Chainlink WOOD feed priced it; false means
    ///                     the TWAP oracle did. There is no third source: with
    ///                     neither available this view REVERTS `NoWoodPrice`.
    /// @param  capBinding  True when the manual cap — not the market — is setting
    ///                     every bond's value. Sustained `true` is the alarm that
    ///                     the cap has drifted BELOW market and the market source
    ///                     has gone inert.
    function woodPriceDetail() external view returns (uint256 price, bool fromFeed, bool capBinding);
    function woodHaircutBps() external view returns (uint256);

    /// @notice The wired `IWoodTwapOracle`, or `address(0)` when unwired.
    function woodTwapOracle() external view returns (address);
    function epochLength() external view returns (uint256);
    function challengeWindow() external view returns (uint256);
    function kNumerator() external view returns (uint256);
    function coveredTvlCapUsd() external view returns (uint256);
    function quorumTierThreshold() external view returns (uint8);
    function proposerBondBps() external view returns (uint256);

    // ── Owner setters ──
    function setWoodUsdPrice(uint256 newPriceX8) external;
    function setWoodFeed(address feed, uint256 maxDelay) external;

    /// @notice Wire (or unwire, with `address(0)`) the WOOD/WETH TWAP oracle.
    /// @dev    Wiring VALIDATES the oracle's pair before trusting it, so an empty
    ///         or wrong-token pool cannot be adopted by address alone. Unwiring is
    ///         legal but is NOT a safe resting state: with no Chainlink WOOD feed
    ///         on chain 4663 it leaves the ledger with no price source at all.
    ///         Unwire only to rotate onto a replacement.
    function setWoodTwapOracle(address oracle) external;
    function setWoodHaircutBps(uint256 newBps) external;
    function setAssetFeed(address asset, address feed, uint256 maxDelay) external;
    function setGuardianRegistry(address registry) external;
    function setChallengeWindow(uint256 newWindow) external;
    /// @notice Set the exposure-cap multiplier `k`: a guardian may hold live
    ///         locks totalling `k x slashableStake`, in WOOD. Rejects zero.
    /// @dev    AT `k = 1` THE LEDGER GUARANTEES CONTAINMENT: `sum of live locks <=
    ///         stake`, so burning one proposal's lock leaves at least the sum of
    ///         every other lock still staked — a conviction on one proposal
    ///         leaves every other proposal the guardian backs fully covered. ANY
    ///         `k > 1` IS DELIBERATE LEVERAGE that trades exactly that property
    ///         away: a conviction on one proposal may then leave the others
    ///         under-covered by precisely the excess. The default is 1 because
    ///         containment is a safety property, not a placeholder; raise it only
    ///         as an informed governance decision.
    function setKNumerator(uint256 newK) external;
    function setCoveredTvlCapUsd(uint256 newCap) external;
    function setQuorumTierThreshold(uint8 newThreshold) external;
    function setProposerBondBps(uint256 newBps) external;
}
