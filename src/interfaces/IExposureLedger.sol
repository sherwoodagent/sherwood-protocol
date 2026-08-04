// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IExposureLedger
/// @notice Dollar-denominated aggregate exposure cap + covered-TVL cap +
///         approve-quorum arithmetic. Singleton; consumed by GuardianRegistry
///         (exposure recording at approve-vote time) and SyndicateGovernor
///         (covered-TVL check at propose, approve-quorum check at execute).
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

    /// @notice No source could price WOOD: the Chainlink WOOD feed is unwired
    ///         or degraded AND the TWAP oracle is unwired or unavailable — or
    ///         the price CAP `woodUsdPriceX8` is zero.
    ///
    /// @dev    THE CAP IS NEVER SERVED AS A PRICE (design revision 2,
    ///         2026-08-02), so there is no branch left in which a
    ///         hand-maintained scalar becomes the valuation. That is the
    ///         property that makes its staleness tolerable, and it is why "no
    ///         market data" has to be a revert rather than a fallback.
    ///
    ///         `woodUsdPriceX8 == 0` lands here too, rather than meaning "no
    ///         cap". An unset cap would admit an unbounded market price and
    ///         hand a ~$438k WOOD/WETH pool the valuation of every guardian
    ///         bond in the protocol — the one thing the cap exists to prevent —
    ///         so fail-closed is the only safe reading.
    ///
    ///         HALTING SEMANTICS. Every consumer lets this propagate except
    ///         `recordApproval`, which catches it and books nothing. Reverting
    ///         there would let Block votes land while Approve votes failed,
    ///         turning the review block-only — the failure mode reviews M3, N1
    ///         and N4 each removed. Execution (`requireApproveQuorum`),
    ///         proposal creation (`proposerBondWood`) and challenge filing
    ///         (`ChallengeGame.file`) all halt, which is correct: no price
    ///         means no proof of coverage.
    error NoWoodPrice();

    // ── Events ──
    event WoodUsdPriceSet(uint256 oldPriceX8, uint256 newPriceX8);
    event WoodFeedSet(address indexed feed, uint256 maxDelay);
    event WoodTwapOracleSet(address indexed oldOracle, address indexed newOracle);
    event GuardianRegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event AssetFeedSet(address indexed asset, address feed, uint256 maxDelay, uint8 assetDecimals);
    event ExposureRecorded(address indexed guardian, bytes32 indexed reviewKey, uint256 usd, uint256 epoch);
    event ExposureReleased(address indexed guardian, bytes32 indexed reviewKey, uint256 usd, uint256 epoch);
    event ParameterChangeFinalized(bytes32 indexed paramKey, uint256 oldValue, uint256 newValue);
    event CoverageFreezerSet(address indexed oldFreezer, address indexed newFreezer);
    event CoverageFrozenSet(address indexed governor, uint256 indexed proposalId, bool frozen);
    /// @notice A proposal's coverage was pinned open through `deadline`,
    ///         independent of whether it is currently frozen.
    event CoveragePinned(address indexed governor, uint256 indexed proposalId, uint256 deadline);

    // ── Registry-only mutations ──
    function recordApproval(address governor, uint256 proposalId, address guardian) external;
    function releaseApproval(address governor, uint256 proposalId, address guardian) external;

    // ── Governor-consumed checks (view) ──
    function requireWithinCoveredTvlCap(address asset, uint256 requiredCoverage) external view;

    /// @notice Reverts when a proposal's settlement lands beyond the ledger's
    ///         booking horizon. Called at propose so the error lands on the
    ///         proposer rather than on the guardian cohort.
    function requireWithinCoverageHorizon(uint256 executeBy, uint256 strategyDuration) external view;
    /// @notice Measures the covering approvers' aggregate bond against the
    ///         proposal's required coverage instead of gating all-or-nothing
    ///         (issue #27): returns `(coverageRaisedUsd, requiredCoverageUsd)`,
    ///         both USD-18 from the same price read, so the caller can size
    ///         execution to a coverage-proportional effective capital. Reverts
    ///         `InsufficientApproveCoverage` only when the approver set is
    ///         empty or the raised aggregate is exactly zero — a partial but
    ///         nonzero aggregate returns instead of reverting.
    function requireApproveQuorum(address governor, uint256 proposalId, address asset, uint256 requiredCoverage)
        external
        view
        returns (uint256 coverageRaisedUsd, uint256 requiredCoverageUsd);

    // ── Coverage freeze (challenge game) ──
    function freezeCoverage(address governor, uint256 proposalId) external;
    function unfreezeCoverage(address governor, uint256 proposalId) external;
    function isCoverageFrozen(address governor, uint256 proposalId) external view returns (bool);
    /// @notice Whether ANY frozen proposal names this guardian as a covering
    ///         approver, OR this guardian is still within a `pinCoverageUntil`
    ///         deadline. sWOOD gates the unstake CLAIM on it, which is what
    ///         makes the freeze load-bearing rather than decorative: epoch
    ///         buckets age out on wall-clock and a disputed challenge outlives
    ///         them, so `openExposureUsd` alone would let an accused guardian
    ///         claim its bond mid-accusation.
    function hasFrozenCoverage(address guardian) external view returns (bool);
    /// @notice Pin every approver of (governor, proposalId) as frozen through
    ///         `deadline`, regardless of `freezeCoverage`/`unfreezeCoverage`
    ///         state. Only ever RAISES a guardian's pin; decays on its own
    ///         once `block.timestamp` passes `deadline` — no unpin call
    ///         exists or is needed.
    function pinCoverageUntil(address governor, uint256 proposalId, uint256 deadline) external;
    /// @dev Zero is legal and deliberate — it is the UNWIRE switch, closing
    ///      the freeze surface when the challenge game is replaced: with no
    ///      freezer wired there is no filing, so the unwired state fails
    ///      closed for the game rather than open.
    ///
    ///      Reverts while any coverage is frozen. `unfreezeCoverage` is
    ///      `onlyFreezer` and the game is its only caller, so rotating the
    ///      role mid-challenge would orphan the freeze: `resolve()` would
    ///      revert forever, both bonds would be stranded with no withdrawal
    ///      path, and every accused approver would be permanently barred
    ///      from `claimUnstakeGuardian`. Rotate only after draining live
    ///      challenges until `frozenCoverageCount()` is zero.
    function setCoverageFreezer(address freezer) external;
    function coverageFreezer() external view returns (address);
    /// @notice How many proposals are frozen right now, across every guardian.
    ///         Zero is the precondition for rotating `coverageFreezer`, so this
    ///         is the read governance sequences a role change against.
    function frozenCoverageCount() external view returns (uint256);

    // ── Views ──
    /// @notice The covering approvers of a proposal and the USD each has
    ///         BOOKED right now.
    /// @dev    NOT A HISTORICAL SET. `releaseApproval` swap-and-pops the
    ///         guardian out of the approver list, so a released commitment is
    ///         DROPPED, not reported as a zero share. A zero here means
    ///         something else entirely: a booking `settleCoverage` wrote down
    ///         to nothing, which it does for any approver whose own slashable
    ///         bond has gone — a concurrent conviction, or an exit.
    ///
    ///         That makes this the wrong read for "did this guardian
    ///         underwrite this proposal?": `settleCoverage` is permissionless,
    ///         re-runnable, and deliberately un-gated on the freeze, so the
    ///         number moves under a live challenge. Use `pledgedOf` for that
    ///         question. This view answers the one it is named for — what is
    ///         on the books at this instant.
    function approversOf(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory committedUsd);

    /// @notice The covering approvers of a proposal and the USD each PLEDGED
    ///         when it approved — the reservation `recordApproval` booked,
    ///         before any settlement pass redistributed it.
    /// @dev    The settle-immune half of the pair. `approversOf` reports the
    ///         live booking, which `settleCoverage` rewrites in both
    ///         directions without a freeze gate; this reports the pledge,
    ///         which only `recordApproval` writes and only `releaseApproval`
    ///         clears — and `releaseApproval` reverts `CoverageFrozen` for the
    ///         whole life of a challenge.
    ///
    ///         So this is the read that answers whether a guardian underwrote
    ///         a proposal, as opposed to what it happens to be carrying now.
    ///         `TokenCourt` derives its accused set from it: a guardian whose
    ///         booking a later settlement zeroed still underwrote the drain,
    ///         and must still be barred from voting on its own case (#83).
    ///
    ///         Every listed approver has a non-zero pledge in practice —
    ///         `recordApproval` lists a guardian only when it pledges
    ///         something, and `releaseApproval` clears the pledge and the
    ///         listing together. The zero remains meaningful anyway, so
    ///         callers can filter on one predicate rather than on membership.
    function pledgedOf(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory pledgedUsd);

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
    ///         Exposes the same figure as one number, so callers outside the
    ///         ledger need not re-derive the reservation/allocation
    ///         distinction — sizing a challenger's bond off reservations
    ///         instead would charge more to challenge a proposal the better
    ///         covered it was.
    ///
    ///         `min(needUsd, effectiveTotal)`: allocations sum to the need when
    ///         the cohort can cover it, and are bounded by what the cohort can
    ///         actually pay when it cannot.
    function liabilityUsd(address governor, uint256 proposalId) external view returns (uint256);

    /// @notice The UNSHARED counterpart of `liabilityUsd`: what a conviction on
    ///         THIS proposal alone can take, ignoring any pro-rata sharing with
    ///         OTHER open proposals the same guardian(s) also back.
    /// @dev    `liabilityUsd` is the right basis for pricing a conviction's
    ///         actual recovery, and is deliberately pro-rated once a guardian
    ///         backs more than one open proposal — a conviction can only ever
    ///         take one real, shared bond. `ChallengeGame.file`'s
    ///         anti-frivolous-filing bond is a different quantity: it prices
    ///         what THIS FILING freezes for THIS accused cohort, and must not
    ///         shrink merely because the same guardians happen to be juggling
    ///         other open commitments under `kNumerator > 1` (Pashov re-audit
    ///         of #158, finding 3). `ChallengeGame.file` is the intended
    ///         caller; every other consumer keeps reading `liabilityUsd`.
    function unsharedLiabilityUsd(address governor, uint256 proposalId) external view returns (uint256);

    /// @notice Return each approver's over-reservation once the review has shut
    ///         and the approver set is final. Permissionless; safe to skip.
    /// @dev    Re-runnable, and a caller that prices money off a settled
    ///         proposal should re-run it first. Each pass re-derives the whole
    ///         split from the pledges recorded at vote time, at the CURRENT
    ///         price, so a pass taken while WOOD or the vault asset was
    ///         depressed leaves a stale number the next pass corrects. No pass
    ///         can book a guardian above its own pledge, in either direction.
    function settleCoverage(address governor, uint256 proposalId) external;

    function slashableBondUsd(address guardian) external view returns (uint256);
    function openExposureUsd(address guardian) external view returns (uint256);
    function coverageUsd(address asset, uint256 amount) external view returns (uint256);
    function proposerBondWood(address asset, uint256 requiredCoverage) external view returns (uint256);
    function currentEpoch() external view returns (uint256);

    /// @notice The WOOD/USD price CAP, 8 decimals. NEVER SERVED AS A PRICE — it
    ///         only bounds whatever the market reports, and lowering it is the
    ///         emergency brake.
    /// @dev    Seed it ABOVE market and review it monthly. A cap below market
    ///         binds permanently, which pins every bond at the cap and makes
    ///         the market source inert — the exact inversion design revision 2
    ///         exists to undo. Zero means `NoWoodPrice`, not "uncapped".
    function woodUsdPriceX8() external view returns (uint256);
    function woodPriceX8() external view returns (uint256);

    /// @notice The WOOD price, which source produced it, and whether the cap is
    ///         currently binding — so monitoring can observe both degraded
    ///         paths without an event.
    /// @param  price       `_haircut(min(market, cap))`, floored at 1.
    /// @param  fromFeed    True when a Chainlink WOOD feed priced it; false
    ///                     means the TWAP oracle did. There is no third source:
    ///                     with neither available this view REVERTS
    ///                     `NoWoodPrice` rather than returning a made-up number.
    /// @param  capBinding  True when `woodUsdPriceX8 < market`, i.e. the manual
    ///                     cap — not the market — is setting every bond's value.
    ///                     Sustained `true` is the alarm that the cap has
    ///                     drifted BELOW market and the market source has gone
    ///                     inert; it is not a safety failure, but it is the
    ///                     signal that the number needs raising.
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
    /// @dev    Wiring VALIDATES the oracle's pair before trusting it, so an
    ///         empty or wrong-token pool cannot be adopted by address alone.
    ///         Unwiring is legal but is NOT a safe resting state under design
    ///         revision 2: with no Chainlink WOOD feed on chain 4663 it leaves
    ///         the ledger with no price source at all and every price read
    ///         reverts `NoWoodPrice`. Unwire only to rotate onto a replacement.
    function setWoodTwapOracle(address oracle) external;
    function setWoodHaircutBps(uint256 newBps) external;
    function setAssetFeed(address asset, address feed, uint256 maxDelay) external;
    function setGuardianRegistry(address registry) external;
    function setChallengeWindow(uint256 newWindow) external;
    function setKNumerator(uint256 newK) external;
    function setCoveredTvlCapUsd(uint256 newCap) external;
    function setQuorumTierThreshold(uint8 newThreshold) external;
    function setProposerBondBps(uint256 newBps) external;
}
