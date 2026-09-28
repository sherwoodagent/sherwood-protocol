// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IChallengeGame
/// @notice Bonded challenges against executed proposals — the trigger above the
///         slash rails. Slash proceeds are BURNED, not compensated: the protocol
///         punishes the approver, it does not reimburse the vault.
///
///         A challenge is an ASSERTION with an evidence pointer, never an
///         on-chain proof: an undisputed challenge slashes after a delay, a
///         disputed one goes to adjudication. No predicate is verified on-chain
///         — some need a venue-specific fair-value model or a funding-graph
///         analysis a chain cannot do, and enforcing some in code while
///         judge-enforcing the rest would run two security models in one
///         mechanism. Adjudication is SILENCE: not contesting IS the verdict.
interface IChallengeGame {
    /// @notice Lifecycle of a proposal's counter-bond pool.
    /// @dev    `Burned` and `Released` are deliberately two values rather than
    ///         one `resolved` bit: only `Released` makes a funder's stake
    ///         claimable, and collapsing them would let a BURNED pool be claimed
    ///         back - the exact clawback the burn exists to remove.
    ///
    ///         Declared here rather than on the implementation so `poolOutcomeOf`
    ///         can return it from this interface; `ChallengeGame` inherits it.
    enum PoolOutcome {
        Open,
        Burned,
        Released
    }

    /// @notice The predicate a challenge cites.
    /// @dev    Classification only, carried in `ChallengeFiled` so
    ///         watchtowers, indexers and judges can filter and route. It
    ///         branches no logic — every predicate takes the identical
    ///         assertion path, keeping one security model instead of two.
    enum Predicate {
        OutOfAdapterOutflow,
        OraclePriceDeviation,
        ProposerLinkedOutflow,
        RogueAllowance,
        DrawdownBreach
    }

    /// @notice Challenge lifecycle. There is deliberately no `Proven` state:
    ///         (`Filed`/`Disputed`) or terminal
    ///         (`Failed`/`Settled`/`Inconclusive`). `Inconclusive` is a terminal
    ///         NON-VERDICT, reachable only from `Disputed`.
    enum Status {
        None,
        Filed,
        Disputed,
        Failed,
        Settled,
        Inconclusive
    }

    /// @notice The court's three-valued outcome for a disputed challenge.
    ///         `Inconclusive` is a NON-VERDICT: the vote missed its participation
    ///         floor, so nothing was adjudicated and both sides unwind whole.
    /// @dev    `Inconclusive` IS DELIBERATELY THE ZERO VALUE, so a
    ///         default-initialized `Verdict` lands on the harmless full unwind,
    ///         never on `Guilty`'s max-slash conviction.
    /// @dev    NOT THE SAME ORDER AS `ITokenCourt.Ruling`, AND A CAST BETWEEN THE
    ///         TWO IS NEVER VALID. `Ruling` is `{None, Guilty, NotGuilty}`; this
    ///         is `{Inconclusive, NotGuilty, Guilty}` — the two non-zero values
    ///         are INVERTED, so `Verdict(uint8(ruling))` silently turns a `Guilty`
    ///         ruling into a `NotGuilty` verdict. Each enum's zero value is pinned
    ///         to its own safe default, so `TokenCourt` translates explicitly, arm
    ///         by arm.
    enum Verdict {
        Inconclusive,
        NotGuilty,
        Guilty
    }

    /// @param frozenCoverageUsd The coverage this challenge pinned, in USD-18,
    ///        snapshotted at filing; the bond was sized against it. It is NOT what
    ///        the eventual verdict is worth — the verdict is punitive and takes
    ///        the severity ceiling of each convicted approver's live bond. Written
    ///        once and never read on-chain: it exists for indexers and for
    ///        auditing the bond arithmetic.
    /// @param counterBondWood The counter-bond POOL raised so far, summed over
    ///        every contributor. There is deliberately no single `disputer` field:
    ///        the defence is bought collectively.
    ///
    ///        so two concurrent challenges report the SAME figure here and one
    ///        funding answers both. `challengeOf` synthesises it from the pool
    ///        while the challenge is live, and the value is pinned into storage
    ///        when the challenge terminates. Summing it across challenges
    ///        therefore double-counts - ask `counterBondPoolOf` instead.
    ///
    ///        `Disputed` still implies a COMPLETE pool, but completeness is
    ///        `>= target` for the pool, and the target is the largest live bond
    ///        on the proposal rather than necessarily this challenge's own.
    /// @param adapterTarget The adapter the challenger accuses, demoted on a
    ///        passed challenge. Zero means the filing accuses no adapter.
    /// @param adapterSelector The accused adapter's selector.
    /// @param executedAt The challenged proposal's execution timestamp, pinned at
    ///        filing. It is the slash basis the verdict is sized against, and
    ///        pinning it keeps the conviction recoverable: any instant at or after
    ///        the accusation is one the accused could move its own checkpoint past.
    /// @param vault The challenged proposal's vault, likewise pinned at filing
    ///        rather than re-read from a mutable governor at resolve time.
    /// @param autoSlashDelayAtFiling The silence window this challenge actually
    ///        received. Reading the live parameter would let the owner
    ///        retroactively close a window the accused is still inside.
    /// @param disputeTimeoutAtFiling The escalation clock this challenge received,
    ///        pinned for the same reason from the other side: a live read would
    ///        let the owner extend an existing freeze several-fold.
    /// @param settleBurnBpsAtFiling The settle-path burn rate in force at filing.
    ///        Read live, the owner could raise it afterwards and take up to half
    ///        the refund of a challenge that turned out correct — the challenger
    ///        relied on the rate when it filed and cannot withdraw.
    /// @param forfeitBurnBpsAtFiling The fail-path burn rate at filing, pinned for
    ///        the symmetric reason: its victims are the accused who funded the
    ///        counter-bond, whose payout this rate scales.
    /// @param prosecutorFeeBpsAtFiling The prosecutor-fee rate at filing, pinned
    ///        for the same reason. Forwarded to `IProposerBondEscrow.forfeitBond`
    ///        on EVERY conviction — it is a slice of the proposer's forfeited
    ///        bond, not of the slash, which pays no one.
    struct Challenge {
        address governor;
        uint256 proposalId;
        address challenger;
        uint256 bondWood;
        uint256 counterBondWood;
        Predicate predicate;
        Status status;
        uint256 filedAt;
        uint256 frozenCoverageUsd;
        address adapterTarget;
        bytes4 adapterSelector;
        uint256 executedAt;
        address vault;
        uint256 autoSlashDelayAtFiling;
        uint256 disputeTimeoutAtFiling;
        uint256 settleBurnBpsAtFiling;
        uint256 forfeitBurnBpsAtFiling;
        uint256 prosecutorFeeBpsAtFiling;
        /// @dev The forfeited challenger bond, net of the fail-path burn,
        ///      that the pool's funders split pro-rata to what each put in.
        ///      Written once by `_fail`, read by `claimContribution`, zero
        ///      on every other path. Storing the total rather than paying
        ///      it out is what lets a claimant compute its own share in
        ///      O(1).
        uint256 forfeitPayoutWood;
        /// @dev The Inconclusive-unwind burn rate in force at filing, pinned for
        ///      the same reason as every other rate above. Not a flat rate: the
        ///      value pinned here is whatever
        ///      `ChallengeGame._inconclusiveBurnBpsForRound` computed for this
        ///      proposal's round count, so two challenges against the same
        ///      proposal can carry different pinned rates.
        ///
        ///      Appended after `forfeitPayoutWood` rather than grouped with the
        ///      other `*AtFiling` rates: inserting it earlier would shift tuple
        ///      positions for anything decoding `challengeOf()` positionally.
        uint256 inconclusiveBurnBpsAtFiling;
        /// @dev The escrow holding this proposal's PROPOSER bond, pinned at filing
        ///      from `StrategyProposal.proposerBondEscrow` — the same binding
        ///      `reclaimProposerBond` releases against, and where `_settle`
        ///      confiscates it on a conviction. Pinned rather than re-read for the
        ///      same reason as `vault` and `executedAt`: a verdict can land a full
        ///      `disputeTimeout` after filing. Zero when the proposal locked no
        ///      bond, which the settle path treats as nothing-to-forfeit rather
        ///      than an error. Appended for tuple-position stability.
        address proposerBondEscrow;
        /// @dev The adjudicator wired when this challenge was FILED. `rule` gates
        ///      on BOTH the LIVE `court` AND this pinned value: a challenge filed
        ///      with this at `address(0)` can never reach `rule` at all, whatever
        ///      gets wired later, while one that HAD a non-zero `courtAtFiling`
        ///      may still be ruled by a REPLACEMENT adjudicator.
        ///
        ///      `resolve`'s Disputed-timeout branch reads the same value to decide
        ///      what an un-ruled timeout means: `address(0)` means no adjudicator
        ///      was ever GUARANTEED reachable, so a `Guilty` ruling was never a
        ///      real possibility the pool's funders risked losing to. Left
        ///      unpinned, `dispute`'s an-outside-funder-risks-real-capital
        ///      justification collapses whenever the game is unwired, turning every
        ///      dispute into a guaranteed forfeit funded by the challenger.
        ///      `resolve` routes that case to `_refundAll` — a non-verdict, not an
        ///      acquittal. Appended last for tuple-position stability.
        address courtAtFiling;
        /// @dev WOOD paid into THIS challenge's own defence, when the shared pool
        ///      completed before it was filed. Appended for tuple stability.
        uint256 defenceWeight;
        /// @dev When that own defence reached the pool's target; zero means never.
        uint256 defendedAt;
    }

    // ── Errors ──
    error NotExecuted();
    error WindowClosed();
    error AlreadyChallenged();
    /// @dev The proposal's one liability has already been collected by a settled
    ///      challenge, so no further filing against it can reach a verdict.
    ///      Refused at the door because such a filing still FREEZES the coverage,
    ///      and the freeze is what bars an accused approver from
    ///      `claimUnstakeGuardian`: it would buy another `autoSlashDelay` of lock
    ///      on already-slashed collateral for the price of `settleBurnBps` on a
    ///      refunded bond, from as many addresses as the griefer cares to fund.
    error AlreadyConvicted();
    error NothingToFreeze();
    error WrongStatus();
    error DelayNotElapsed();
    error NotAccusedApprover();
    error ZeroAddress();
    error InvalidParameter();
    /// @dev The ledger could not price the bond: no WOOD price source (feed and
    ///      TWAP both unavailable, or the cap unset), or the vault-asset feed
    ///      needed for the proposal's need is stale. Transient and
    ///      protocol-wide: nothing is challengeable until the price returns, and
    ///      filing WAITS rather than falling back to an inflated figure. Split out
    ///      from `InvalidParameter` because the two call for opposite responses.
    error WoodPriceUnset();
    /// @dev The bond floored to zero, so the filing would have bought its
    ///      freeze for nothing. Permanent and specific to this proposal:
    ///      nobody can ever challenge it while that coverage and that WOOD
    ///      price stand.
    error BondTooSmall();
    /// @notice A counter-bond contribution that would move nothing — a zero
    ///         `amountWood`. The pool being already full cannot reach this: the
    ///         completing contribution flips the status to `Disputed`, so a later
    ///         caller is rejected by `WrongStatus` first.
    error NothingToContribute();
    /// @notice `claimContribution` found nothing owed — the caller never
    ///         contributed, has already claimed, or the proposal was CONVICTED,
    ///         which burns the pool rather than returning it. A pool shared with
    ///         a still-live sibling challenge also reads as nothing owed until
    ///         that sibling terminates and the pool is released.
    error NothingToClaim();
    /// @notice `claimContribution` on a challenge that is not yet terminal.
    ///         Entitlements are only knowable once the outcome is fixed.
    error ChallengeNotTerminal();
    /// @notice `rule` called by anything other than the wired court.
    /// @dev    Also what an unwired game reverts with, since `court` is then the
    ///         zero address and no caller can match it.
    /// @dev    ALSO what the LIVE court itself gets back for a challenge filed
    ///         with `courtAtFiling == address(0)`: the live-court identity check
    ///         alone does not mean the pool's funders were ever exposed to a
    ///         ruling on THIS challenge. The timeout stays the only way out of
    ///         `Disputed` for such a challenge.
    error NotCourt();
    /// @dev `resolve` was called with too little gas to guarantee the slash loop
    ///      can finish, or — on a challenge naming an adapter — too little to also
    ///      guarantee the best-effort `demoteByChallenge` that follows it. Retry
    ///      with more gas; nothing about the challenge state changes.
    error InsufficientSlashGas();
    /// @dev The filing named an adapter `(target, selector)` that does not appear
    ///      in the challenged proposal's own execute calls. A challenge is an
    ///      assertion, but which adapter a proposal touched is on-chain fact, and
    ///      a full refund on the settle path would otherwise make demoting an
    ///      arbitrary certified adapter free. A membership test over stored calls,
    ///      not a second calldata parser.
    error AdapterNotInProposal();
    /// @notice `file` refused because the owner has paused new filings —
    ///         the owner's only lever gating filings. Never raised anywhere
    ///         else — dispute/resolve/rule/claims are unaffected by this
    ///         flag.
    error FilingsPaused();
    /// @notice A setter would break the cross-contract invariant
    ///         `autoSlashDelay + voteWindow + FINALIZE_BUFFER + MIN_REFERRAL_SLACK
    ///         <= disputeTimeout`. Raised by `setAutoSlashDelay`,
    ///         `setDisputeTimeout` and `setCourt` — see
    ///         `ChallengeGame._requireWindowFits` for why neither contract can
    ///         hold this alone.
    error WindowInvariantViolated();
    /// @notice A role setter was pointed at a contract that has not granted this
    ///         game the reciprocal role it needs there — a ledger whose
    ///         `coverageFreezer` is not this address, or a sWOOD whose
    ///         `authorizedSlasher` is not.
    /// @dev    Both grants are two-sided, and moving only this side is a wedge:
    ///         every terminal path of a live challenge routes through
    ///         `unfreezeCoverage` and every conviction through `slashVerdict`,
    ///         both of which would revert on their own caller gates — leaving
    ///         bonds with no exit and coverage frozen on a ledger that can no
    ///         longer be told to release it. Grant the role on the target first.
    error RoleNotGranted();
    /// @notice `renounceOwnership` is disabled. Ownership is transferable but
    ///         never abandonable.
    /// @dev    The owner-only escapes this design relies on — `setStakedWood` as
    ///         the un-wedge for a mis-wired slasher, `setCourt(address(0))` as the
    ///         off-switch for a captured court — have no permissionless
    ///         equivalent.
    error RenounceDisabled();

    // ── Events ──
    /// @dev `evidenceURI` is carried on-chain unindexed so predicates that
    ///      no chain can check still have their off-chain evidence pointer
    ///      anchored to the filing.
    event ChallengeFiled(
        uint256 indexed challengeId,
        address indexed governor,
        uint256 indexed proposalId,
        address challenger,
        Predicate predicate,
        uint256 bondWood,
        string evidenceURI
    );
    /// @dev A funder collecting what a terminal challenge owed it: stake back,
    ///      plus its slice of the forfeit on the failed path.
    event ContributionClaimed(uint256 indexed challengeId, address indexed contributor, uint256 amountWood);
    /// @dev One per contributing address, so the payer set — and therefore the
    ///      pro-rata split a failed challenge pays out — is reconstructible from
    ///      the log alone.
    event CounterBondContributed(
        uint256 indexed challengeId, address indexed contributor, uint256 amountWood, uint256 poolWood
    );
    /// @dev Emitted ONCE, by the contribution that completes the pool — the
    ///      instant the escalation is actually bought. It carries no `disputer`:
    ///      the defence is collective, and who paid what is in the
    ///      `CounterBondContributed` log that precedes this one.
    /// @dev `challengeId` IS THE CHALLENGE THE COMPLETING CONTRIBUTION WAS PAID
    ///      THROUGH, not the only one it disputes. The pool is per proposal, so
    ///      every live challenge on that review key whose own silence window
    ///      still contains this instant becomes `Disputed` in the same call. An
    ///      indexer must re-read `challengeOf(...).status` for the siblings
    ///      rather than assume one event means one challenge.
    event ChallengeDisputed(uint256 indexed challengeId, uint256 counterBondWood);
    /// @notice A conviction destroyed the proposal's counter-bond pool. Emitted
    ///         once per pool, by whichever challenge convicted first.
    /// @dev    The pool is NOT paid to the challenger: doing so made the
    ///         counter-bond a refundable deposit for a guilty cohort able to
    ///         file from a second address. `challengeId` is the settling
    ///         challenge, `amountWood` the whole pool, complete or partial.
    event CounterBondPoolBurned(uint256 indexed challengeId, uint256 amountWood);
    /// @notice The proposal's counter-bond pool was returned to its funders —
    ///         booked into `unclaimedWood` for `claimContribution`, not pushed.
    /// @dev    Emitted by the LAST live challenge on the proposal to terminate
    ///         without a conviction, so it can lag a `NotGuilty` or
    ///         `Inconclusive` outcome on any one challenge. Releasing earlier
    ///         would hand the pool back while a sibling was still `Disputed` on
    ///         it, leaving a later `Guilty` ruling nothing to burn.
    event CounterBondPoolReleased(uint256 indexed challengeId, uint256 amountWood);
    /// @notice The pool-completing `dispute` call tried `TokenCourt.refer` on the
    ///         challenger's behalf and the court reverted — a best-effort
    ///         auto-referral. The dispute itself still landed, and `refer` stays
    ///         permissionless, so any caller may retry it directly until
    ///         `InsufficientClock` closes the window. This is the recoverable half
    ///         of the asymmetry with `finalize`'s selector-filtered catch on
    ///         `rule`: a dropped verdict there is terminal with no retry path, so
    ///         that catch may not be broad; a skipped referral always has one.
    event AutoReferFailed(uint256 indexed challengeId);
    /// @param slashedWood What was actually BURNED. Gross and burned are the same
    ///        number on every path: `slashVerdict` takes no payee and burns
    ///        everything it collects. The prosecutor's fee is a slice of the
    ///        PROPOSER's forfeited bond instead and never touches this figure.
    event ChallengeSettled(uint256 indexed challengeId, uint256 slashedWood);
    /// @dev The slice burned on a SETTLE (`settleBurnBps`) or INCONCLUSIVE unwind
    ///      (`inconclusiveBurnBps`) — a filing is never free on either path where
    ///      the challenger did nothing wrong, because an unanswered or unresolved
    ///      filing still froze a cohort's coverage for the price of gas. On a
    ///      settle this is a slice of the CHALLENGER'S BOND on both branches — it
    ///      used to be taken off the forfeited COUNTER-BOND POOL on the escalated
    ///      one, for an identical amount, before that pool stopped being a
    ///      challenger payout at all (see `CounterBondPoolBurned`). Distinct from
    ///      `ChallengeFailed.burnedWood`, the FAIL-path burn charged to a
    ///      challenger who was actually wrong.
    event ChallengerBondBurned(uint256 indexed challengeId, uint256 burnedWood);
    /// @dev A settle that convicted nothing because an earlier challenge on the
    ///      same proposal already did. The approvers' liability is one liability;
    ///      concurrent filings do not multiply it.
    /// @dev  WORTH A FILER KNOWING: this challenge still pays the `settleBurnBps`
    ///       slice of its own bond and receives nothing back beyond the remainder
    ///       — no slash share and no prosecutor fee, because this settle collected
    ///       no liability on ITS behalf. A second, independently correct challenger
    ///       racing an already-settled one is therefore net negative for a filing
    ///       that could never have collected.
    event VerdictAlreadyCollected(uint256 indexed challengeId, address indexed governor, uint256 indexed proposalId);
    /// @dev A passed challenge whose adapter demotion did NOT land, because the
    ///      registry refused the call — in practice because the game's
    ///      `authorizedDemoter` role was rotated away while the challenge was live.
    ///      The demotion is best-effort precisely so that cannot strand the slash,
    ///      the bond refund and the freeze release behind it; the registry owner's
    ///      own `demote` is the remedy.
    event AdapterDemotionFailed(uint256 indexed challengeId, address indexed target, bytes4 indexed selector);

    /// @notice A conviction confiscated the convicted proposal's proposer
    ///         bond. `amount` left the system at the escrow's burn address;
    ///         `proposer` is who lost it.
    event ProposerBondForfeited(
        uint256 indexed challengeId,
        address indexed governor,
        uint256 indexed proposalId,
        address proposer,
        uint256 amount
    );

    /// @notice A conviction could NOT confiscate the proposer bond — already
    ///         reclaimed, already forfeited by a concurrent challenge, or an
    ///         escrow that refused the call. Surfaced rather than reverted for the
    ///         same reason `AdapterDemotionFailed` is: a terminal path must not be
    ///         hostage to a call that can fail.
    event ProposerBondForfeitureFailed(
        uint256 indexed challengeId, address indexed governor, uint256 indexed proposalId, address escrow
    );
    /// @param forfeitedWood What the CHALLENGER lost — its whole bond on the normal
    ///        failure path, and zero on the defensive no-contributor branch.
    /// @param burnedWood The slice of that forfeit destroyed rather than paid out.
    ///        Contributors share `forfeitedWood - burnedWood`; the two are reported
    ///        separately because they answer different questions.
    event ChallengeFailed(uint256 indexed challengeId, uint256 forfeitedWood, uint256 burnedWood);
    /// @dev Emitted BEFORE the settle/fail/refund it causes, so an indexer
    ///      reading the log in order sees the verdict and then the accounting
    ///      it produced.
    event ChallengeRuled(uint256 indexed challengeId, Verdict verdict);
    /// @notice Inconclusive unwind: challenger bond returned minus the escalating
    ///         Inconclusive burn, pool booked for pull-claims, no conviction, no
    ///         demotion.
    /// @dev    `bondWood == poolWood` always holds today, since `rule` only reaches
    ///         this from `Disputed` where the pool is complete by construction.
    ///         Reported as two fields anyway so the log stays truthful if the
    ///         reachable set ever widens.
    /// @dev    `bondWood` IS THE GROSS, PRE-BURN AMOUNT — not what the challenger
    ///         received. `ChallengerBondBurned`, emitted alongside, carries the
    ///         slice that did not: the two logs together are exact, but a consumer
    ///         reading only `bondWood` over-reports by the burned amount.
    event ChallengeInconclusive(uint256 indexed challengeId, uint256 bondWood, uint256 poolWood);
    event CourtSet(address indexed oldCourt, address indexed newCourt);
    event ExposureLedgerSet(address indexed oldLedger, address indexed newLedger);
    event TierRegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event StakedWoodSet(address indexed oldStakedWood, address indexed newStakedWood);
    event ChallengeWindowSet(uint256 oldWindow, uint256 newWindow);
    event ChallengerBondBpsSet(uint256 oldBps, uint256 newBps);
    event ForfeitBurnBpsSet(uint256 oldBps, uint256 newBps);
    event AutoSlashDelaySet(uint256 oldDelay, uint256 newDelay);
    event DisputeTimeoutSet(uint256 oldTimeout, uint256 newTimeout);
    event SettleBurnBpsSet(uint256 oldBps, uint256 newBps);
    event FilingsPausedSet(bool oldPaused, bool newPaused);
    event ProsecutorFeeBpsSet(uint256 oldBps, uint256 newBps);
    event InconclusiveBurnBpsSet(uint256 oldBps, uint256 newBps);

    // Filing
    /// @notice File a bonded challenge against an executed proposal, freezing the
    ///         coverage its approvers committed.
    /// @param governor        The governor that executed the proposal.
    /// @param proposalId      The executed proposal being accused.
    /// @param predicate       The predicate cited — a label for watchtowers and
    ///                        judges; it changes nothing about the path taken.
    /// @param adapterTarget   The adapter accused of misbehaving, demoted if the
    ///                        challenge passes. THE CHALLENGER NAMES IT rather
    ///                        than the chain deriving it: deriving would mean a
    ///                        second calldata parser, and a multi-call proposal
    ///                        has no single derivable culprit. Pass zero to accuse
    ///                        no adapter — a filing that names nothing demotes
    ///                        nothing.
    /// @param adapterSelector The accused adapter's selector. Ignored when
    ///                        `adapterTarget` is zero.
    /// @param evidenceURI     Off-chain pointer to the evidence.
    /// @return challengeId The new challenge's id.
    function file(
        address governor,
        uint256 proposalId,
        Predicate predicate,
        address adapterTarget,
        bytes4 adapterSelector,
        string calldata evidenceURI
    ) external returns (uint256 challengeId);

    // Dispute / resolution
    /// @notice Contribute to the counter-bond POOL of a filed challenge. The
    ///         pool's target is the challenger's own bond; the challenge becomes
    ///         `Disputed` — stopping the auto-slash clock and escalating to the
    ///         court — the moment the pool reaches it.
    /// @param  challengeId The filed challenge to defend.
    /// @param  amountWood  WOOD to contribute. CLAMPED to the shortfall, so an
    ///                     over-sized amount pulls only what the pool still needs
    ///                     and no refund-of-excess path exists to get wrong.
    /// @dev    THE BILL IS SHARED, THE PRICE IS NOT. The target stays pinned to
    ///         the challenger's bond rather than being scaled to the caller's own
    ///         share: the accused side picks who disputes, so any rule keyed to
    ///         the DISPUTER's share would be answered by nominating the smallest
    ///         identity. Splitting one operator into two guardians changes who
    ///         pays, never how much.
    /// @dev    PERMISSIONLESS — ANYONE MAY FUND THE DEFENCE. `claimContribution`
    ///         makes every payout O(1) and pull-based, so contributor-list length
    ///         is not load-bearing, and skin in the game is enforced economically
    ///         instead: a `Guilty` ruling forfeits the whole pool to the
    ///         challenger. Nothing about the contribution gates a payout — the
    ///         prosecutor's fee comes from the proposer's forfeited bond.
    /// @dev    Only strictly before `filedAt + autoSlashDelayAtFiling`, the same
    ///         instant `resolve` starts settling an undisputed challenge: at that
    ///         second the silence verdict is already final.
    function dispute(uint256 challengeId, uint256 amountWood) external;

    /// @notice Permissionless resolution. From `Filed` past `autoSlashDelay` the
    ///         silence is the verdict and the accused are slashed; from `Disputed`
    ///         past `disputeTimeout` the challenge fails to the accused — UNLESS
    ///         no adjudicator was ever pinned at filing, in which case the timeout
    ///         is a non-verdict and both sides unwind whole. When a court WAS
    ///         pinned but never ruled, the timeout still fails the challenge to
    ///         the accused but ALSO re-arms the re-challenge window, unlike a
    ///         genuine `NotGuilty` ruling. Reverts otherwise.
    function resolve(uint256 challengeId) external;

    /// @notice The court's verdict on a DISPUTED challenge. Callable only by
    ///         `court`, and only from `Disputed`.
    /// @dev    ALSO REQUIRES `Challenge.courtAtFiling != address(0)`. The
    ///         live-`court` identity check says who may rule right now, not
    ///         whether THIS challenge's counter-bond funders were ever exposed to
    ///         a ruling at all — a court wired in after a zero-pin filing must not
    ///         retroactively turn that into a live `Guilty` exposure nobody priced
    ///         in. A challenge that DID have an adjudicator pinned may still be
    ///         ruled by a REPLACEMENT court.
    /// @dev    THE COURT SUPPLIES ONLY THE VERDICT ENUM. `Guilty` takes the
    ///         identical path an UNDISPUTED challenge takes; `NotGuilty` the
    ///         identical PAYOUT the timeout takes, but NOT the timeout's
    ///         re-challenge re-arm, since here a real adjudicator looked at the
    ///         merits; `Inconclusive` unwinds BOTH sides whole. There is
    ///         deliberately no severity argument — a court that could dial the
    ///         slash would be negotiating with the accused rather than ruling.
    /// @dev    A RULING BEATS THE TIMEOUT. All three outcomes are terminal and
    ///         `resolve` only acts on `Filed`/`Disputed`, so once the court has
    ///         ruled the clock cannot overwrite the verdict — which is what stops
    ///         a guilty approver disputing and running out `disputeTimeout`.
    function rule(uint256 challengeId, Verdict verdict) external;

    // ── Views ──
    function challengeOf(uint256 challengeId) external view returns (Challenge memory);
    /// @notice Everyone that has put WOOD into the counter-bond pool THIS
    ///         CHALLENGE BELONGS TO, in first-contribution order and without
    ///         duplicates. This is the payout set on the failure path — a failed
    ///         challenge's forfeited bond splits pro-rata across THIS list, not
    ///         across the accused set.
    /// @dev    The pool is per PROPOSAL, so every concurrent challenge on one
    ///         review key returns the same list.
    function counterBondContributors(uint256 challengeId) external view returns (address[] memory);
    /// @notice What one address has contributed to the pool this challenge
    ///         belongs to. Retained after resolution AND after a claim — it is
    ///         the pro-rata weight every later payout out of the same pool is
    ///         split by, so it is a record, not a balance.
    function counterBondContributionOf(uint256 challengeId, address contributor) external view returns (uint256);

    /// @notice The counter-bond pool this challenge belongs to. The pool is
    ///         shared per PROPOSAL, so this is the figure to aggregate over —
    ///         summing `Challenge.counterBondWood` across concurrent challenges
    ///         double-counts one pool.
    /// @param poolWood    WOOD the pool still holds — zero once it resolved.
    /// @param targetWood  What the pool must raise to dispute. The largest live
    ///                    challenger bond on the proposal, frozen at completion.
    /// @param raisedWood  Total ever contributed; the pro-rata denominator.
    /// @param completedAt When the pool first reached its target, or zero. A
    ///                    challenge is `Disputed` when this is non-zero AND
    ///                    earlier than its own auto-slash deadline.
    /// @param burned      True when a conviction destroyed the pool. False both
    ///                    while open and after a release to its funders.
    function counterBondPoolOf(uint256 challengeId)
        external
        view
        returns (uint256 poolWood, uint256 targetWood, uint256 raisedWood, uint256 completedAt, bool burned);

    /// @notice The pool's full lifecycle outcome for the pool `challengeId`
    ///         belongs to.
    /// @dev    `counterBondPoolOf`'s `burned` flag cannot distinguish `Open` from
    ///         `Released` — both report false — and those two differ in exactly
    ///         the way an invariant cares about: `Open` still HOLDS the WOOD,
    ///         `Released` has moved it to `unclaimedWood`. Any property about
    ///         what a pool holds needs this, not that flag.
    function poolOutcomeOf(uint256 challengeId) external view returns (PoolOutcome);

    /// @notice Collect what a terminal challenge owes you for funding the
    ///         counter-bond pool it belongs to: your stake back once that POOL
    ///         has been released, plus your pro-rata slice of THIS challenge's
    ///         forfeited challenger bond when it FAILED.
    /// @dev    PULL, NOT PUSH: resolution stores the total to split and each
    ///         claimant computes its own share on the way out, so the payout is
    ///         O(1) regardless of contributor-list length and one reverting
    ///         recipient can never brick a resolution. Shares floor-divide
    ///         independently, so up to `contributors - 1` wei is never claimable —
    ///         bounded at wei scale and still covered by `unclaimedWood`.
    /// @dev    The two legs are tracked separately and each is single-shot. A
    ///         pool shared by several challenges can owe one funder a stake
    ///         (once) and a forfeit share from every challenge on it that
    ///         failed (once each), so claiming through one challenge never
    ///         retires an entitlement earned on another.
    function claimContribution(uint256 challengeId) external returns (uint256 amount);

    /// @notice What `claimContribution` would pay `contributor` right now
    ///         — the released stake plus, on the failed path, its slice of the
    ///         forfeit. Zero once claimed, zero while the challenge is live, and
    ///         zero on any conviction path, where the pool is BURNED rather than
    ///         returned.
    function claimableContribution(uint256 challengeId, address contributor) external view returns (uint256);

    /// @notice WOOD owed to counter-bond funders of terminal challenges and not
    ///         yet collected.
    /// @dev    `bondedWood` keeps its meaning — WOOD held for LIVE challenges — so
    ///         the invariant is
    ///         `wood.balanceOf(game) >= bondedWood + unclaimedWood`. Splitting the
    ///         two keeps no-live-challenge-implies-zero-`bondedWood` true.
    function unclaimedWood() external view returns (uint256);
    /// @notice The MOST RECENTLY FILED challenge against a proposal if it is still
    ///         live, or zero.
    /// @dev    Filings are per-challenger, so this is not the live challenge: an
    ///         older one may still be live when the newest has gone terminal. Ask
    ///         `liveChallengeCountOf` whether ANY is live.
    function liveChallengeOf(address governor, uint256 proposalId) external view returns (uint256);
    /// @notice How many challenges against this proposal are live.
    ///         Non-zero is exactly the condition under which its coverage
    ///         stays frozen.
    function liveChallengeCountOf(address governor, uint256 proposalId) external view returns (uint256);
    /// @notice `challenger`'s own live challenge against this proposal, or
    ///         zero. One slot per challenger is what stops the accused
    ///         cohort from squatting the only slot for the whole window.
    function liveChallengeOfBy(address governor, uint256 proposalId, address challenger) external view returns (uint256);
    function challengeCount() external view returns (uint256);
    function challengeWindow() external view returns (uint256);
    function challengerBondBps() external view returns (uint256);
    /// @notice The slice of a FAILED challenge's forfeited bond destroyed instead
    ///         of being paid to the counter-bond's funders, in bps. It exists
    ///         because the accused side can be the challenger: one operator can
    ///         file against its own proposal and fund the whole pool, and a
    ///         forfeit paid entirely to contributors then returns to the address
    ///         that posted it. Burning is the only sink with no beneficiary the
    ///         attacker can reach.
    function forfeitBurnBps() external view returns (uint256);
    function autoSlashDelay() external view returns (uint256);
    function disputeTimeout() external view returns (uint256);

    /// @notice Margin the referral window must clear ON TOP of
    ///         `autoSlashDelay + voteWindow + FINALIZE_BUFFER`. Exposed so
    ///         `TokenCourt` and the wiring script enforce the same margin
    ///         `ChallengeGame._requireWindowFits` does, rather than each
    ///         carrying its own literal.
    function MIN_REFERRAL_SLACK() external view returns (uint256);
    /// @notice Share of a SUCCESSFUL challenger's bond burned on settle, in
    ///         bps. Applies to the settle path only: the fail path already
    ///         forfeits the whole bond to the accused.
    function settleBurnBps() external view returns (uint256);
    /// @notice Slice of the convicted proposer's forfeited bond paid to the
    ///         challenger that caused the conviction. Pinned per challenge at
    ///         filing.
    /// @dev    Paid on convictions only. `_settle` is the sole payer, reached by
    ///         the silence timeout or a `Guilty` ruling; a `NotGuilty` ruling, an
    ///         `Inconclusive` unwind and the dispute timeout all route through
    ///         `_fail`/`_refundAll`, which slash nothing and so pay nothing.
    function prosecutorFeeBps() external view returns (uint256);
    /// @notice The ROUND-4-AND-BEYOND steady-state share of the challenger's bond
    ///         burned on an `Inconclusive` unwind, in bps. Rounds 1-3 follow a
    ///         fixed, lower schedule before reaching this ceiling — see
    ///         `ChallengeGame._inconclusiveBurnBpsForRound`.
    /// @dev    Every OTHER terminal path prices the freeze a filing buys — the
    ///         silence settle burns `settleBurnBps`, a failed challenge forfeits
    ///         the whole bond, an escalated guilty verdict charges nothing because
    ///         the filing was right. `Inconclusive` escalates with the round count
    ///         instead of a flat rate, since a flat percentage cannot distinguish
    ///         an honest one-shot filer from a grinder.
    /// @dev    DELIBERATELY NOT KEPT BELOW THE LIVE `settleBurnBps` AT THIS TIER.
    ///         A mutual setter cross-check pinned
    ///         `inconclusiveBurnBps <= settleBurnBps` at all times, which made the
    ///         ladder's fourth rung permanently unreachable: raising it required
    ///         raising `settleBurnBps` first, and that breaks
    ///         `honestFilingBreaksEven`. This rate is bounded only by
    ///         `MAX_INCONCLUSIVE_BURN_BPS`. The non-verdict-never-costs-more-than-
    ///         a-verdict property still holds for rounds 1-3, which are clamped
    ///         live at the point the rate is pinned, and at the ABSOLUTE ceiling
    ///         for this tier too, since `MAX_INCONCLUSIVE_BURN_BPS ==
    ///         MAX_SETTLE_BURN_BPS`.
    function inconclusiveBurnBps() external view returns (uint256);
    /// @notice WOOD the game holds on behalf of live (`Filed`/`Disputed`)
    ///         challenges. The invariant is `wood.balanceOf(game) >=
    ///         bondedWood`; the game pays out nothing but bonds, so the two
    ///         are equal except for WOOD donated here by mistake.
    function bondedWood() external view returns (uint256);
    /// @notice The adjudicator allowed to `rule` on disputed challenges, or
    ///         the zero address while none is wired — in which case
    ///         `Disputed` remains terminal-by-timeout.
    function court() external view returns (address);
    /// @notice The owner's only lever that gates NEW filings: true refuses `file`
    ///         alone; dispute/resolve/rule/claims always run unaffected. It is not
    ///         a claim that a live challenge is fully insulated from the owner —
    ///         see `ChallengeGame.filingsPaused` for what actually is (the
    ///         `*AtFiling` economic pins) and what is not (`court`, read live).
    function filingsPaused() external view returns (bool);
    /// @notice Per-proposal deadline for NEW filings, raised (never lowered)
    ///         whenever a challenge on that proposal unwinds `Inconclusive`.
    ///         `file` gates on the LARGER of this value and
    ///         `executedAt + strategyDuration + challengeWindow` — zero is not a
    ///         sentinel, it is simply what an untouched key contributes.
    /// @dev    THE `+ strategyDuration` TERM IS LOAD-BEARING. `settleProposal`
    ///         moves money at `executedAt + strategyDuration`, not at
    ///         `executedAt`, so a deadline of `executedAt + challengeWindow` alone
    ///         could close BEFORE the settlement calls guardians underwrote ever
    ///         ran — making a drain permanently unchallengeable.
    /// @dev    WITHOUT A RAISED FLOOR, `INCONCLUSIVE` IS A PERMANENT ACQUITTAL.
    ///         Reaching it takes anywhere from `voteWindow` up to
    ///         `autoSlashDelay + voteWindow`, and the accused chooses where in
    ///         that span it lands, so a challenge filed a couple of days after
    ///         execution could in the worst case never be re-filed. Raising the
    ///         floor on every unwind turns the stall into a delay.
    function challengeableUntil(bytes32 reviewKey) external view returns (uint256);
    /// @notice How many times this proposal has gone `Inconclusive` since the last
    ///         time the re-challenge window lapsed with nobody refiling. Drives
    ///         the escalating Inconclusive-burn schedule; round 1 already burns at
    ///         a fixed, positive rate and the rate climbs from there.
    /// @dev    KEYED ON THE PROPOSAL ALONE, not `(reviewKey, challenger)` — a
    ///         per-challenger counter would let a sybil reset the escalation for
    ///         free by switching addresses. RESET, not merely capped, whenever
    ///         `challengeableUntil` has naturally lapsed.
    function inconclusiveRounds(bytes32 reviewKey) external view returns (uint256);

    /// @notice Whether an honest, UNCONTESTED filing currently breaks even or
    ///         better under the live settle-path parameters, i.e. whether
    ///         `challengerBondBps * settleBurnBps <= proposerBondBps *
    ///         prosecutorFeeBps` (`proposerBondBps` read live from the wired
    ///         ledger, which owns that rate). `false` means a guilty approver's
    ///         dominant strategy is silence, because the challenger who correctly
    ///         calls it net-loses WOOD even after a conviction. VIEW ONLY: no
    ///         setter enforces this inequality.
    /// @dev    A BARE BOOLEAN CANNOT DISTINGUISH MAGNITUDE FROM A TRIVIAL PASS —
    ///         `settleBurnBps == 0` zeroes the cost side and this always reads
    ///         `true`, locally correct but easy to over-read. Prefer
    ///         `honestFilingNetPayoffBps` when the margin's size matters.
    function honestFilingBreaksEven() external view returns (bool);
    /// @notice The SIGNED net WOOD-bps payoff to a challenger for a CORRECT,
    ///         UNCONTESTED filing under the live settle-path parameters:
    ///         `proposerBondBps * prosecutorFeeBps - challengerBondBps *
    ///         settleBurnBps`. Positive means the filer profits, negative means it
    ///         loses WOOD even after a correct, unanswered accusation.
    /// @dev    Exposes the magnitude `honestFilingBreaksEven`'s boolean cannot:
    ///         two configurations that both read `true` there — one trivially,
    ///         one with a wide genuine margin — read apart here. VIEW ONLY.
    function honestFilingNetPayoffBps() external view returns (int256);

    // ── Owner setters ──
    /// @notice Wire (or unwire) the court. The zero address is
    ///         DELIBERATELY permitted: it is how governance revokes a
    ///         compromised court and falls back to the fail-safe timeout
    ///         rather than leaving a hostile adjudicator able to force
    ///         slashes.
    function setCourt(address newCourt) external;
    function setExposureLedger(address ledger) external;
    function setTierRegistry(address registry) external;
    function setStakedWood(address stakedWood_) external;
    function setChallengeWindow(uint256 newWindow) external;
    function setChallengerBondBps(uint256 newBps) external;
    /// @notice Set the burned slice of a failed challenge's forfeit. Bounded by a
    ///         ceiling well below the whole bond, and ZERO IS PERMITTED — unlike
    ///         `setChallengerBondBps`, where zero would make the freeze free. Zero
    ///         here only restores paying the entire forfeit to the funders and
    ///         re-opens the self-challenge round trip.
    function setForfeitBurnBps(uint256 newBps) external;
    function setAutoSlashDelay(uint256 newDelay) external;
    function setDisputeTimeout(uint256 newTimeout) external;
    /// @notice Set the settle-path burn.
    /// @dev    DELIBERATELY DOES NOT REJECT dropping below the live
    ///         `inconclusiveBurnBps`. The two rates used to cross-check each
    ///         other's live value, pinning
    ///         `inconclusiveBurnBps <= settleBurnBps` at all times — sound in
    ///         isolation, but it made the Inconclusive ladder's round-4+ tier
    ///         permanently unreachable above round 3's fixed rate, since raising
    ///         it required raising this rate first and that breaks
    ///         `honestFilingBreaksEven`.
    /// @dev    OPERATOR NOTE: this setter does NOT guard the escalating schedule's
    ///         fixed round-2/3 steps — those are clamped live at the point `file`
    ///         computes the pinned rate, not here, so a low `settleBurnBps` never
    ///         blocks filing itself.
    function setSettleBurnBps(uint256 newBps) external;
    function setFilingsPaused(bool paused) external;
    function setProsecutorFeeBps(uint256 newBps) external;
    /// @notice Set the round-4-and-beyond steady state of the escalating
    ///         Inconclusive-burn schedule. Bounded ONLY by its own ceiling,
    ///         `MAX_INCONCLUSIVE_BURN_BPS` — deliberately does NOT additionally
    ///         reject rising above the live `settleBurnBps`; see
    ///         `inconclusiveBurnBps` for why that cross-check was removed. Zero is
    ///         legal and floors this tier to nothing; rounds 1-3 are unaffected,
    ///         being fixed constants.
    function setInconclusiveBurnBps(uint256 newBps) external;
}
