// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IChallengeGame
/// @notice Bonded challenges against executed proposals (spec 2026-07-22 §3.4)
///         — the trigger above the slash/compensation rails.
///
///         A challenge is an ASSERTION with an evidence pointer, never an
///         on-chain proof. §3.4's flow is "undisputed → slash after a delay,
///         disputed → adjudication": nothing in it asks the chain to VERIFY a
///         predicate, and only three of the five could ever be verified
///         on-chain anyway (predicate 2 needs a venue-specific fair-value
///         model, predicate 3 is a funding-graph question). Code-enforcing
///         some and judge-enforcing the rest would run two security models in
///         one mechanism. So adjudication is SILENCE: not contesting IS the
///         verdict.
interface IChallengeGame {
    /// @notice The §3.4 predicate a challenge cites.
    /// @dev    CLASSIFICATION ONLY (decision D1). It is carried in
    ///         `ChallengeFiled` so watchtowers, indexers and (later) judges can
    ///         filter and route. It branches NO logic anywhere — every
    ///         predicate takes the identical assertion path, which is exactly
    ///         what keeps one security model instead of two.
    enum Predicate {
        OutOfAdapterOutflow, // §3.4 #1
        OraclePriceDeviation, // §3.4 #2
        ProposerLinkedOutflow, // §3.4 #3
        RogueAllowance, // §3.4 #4
        DrawdownBreach // §3.4 #5
    }

    /// @notice Challenge lifecycle. There is deliberately no `Proven` state —
    ///         see `Predicate`: nothing is proven on-chain, so a challenge is
    ///         only ever live (`Filed`/`Disputed`) or terminal
    ///         (`Failed`/`Settled`/`Inconclusive`). `Inconclusive` is a terminal
    ///         NON-VERDICT — see `Verdict` — reachable only from `Disputed`, the
    ///         same entry `Failed`/`Settled` take via a court ruling.
    enum Status {
        None,
        Filed,
        Disputed,
        Failed,
        Settled,
        Inconclusive
    }

    /// @notice The court's three-valued outcome for a disputed challenge
    ///         (spec 2026-07-28 §4). `Inconclusive` is a NON-VERDICT: the vote
    ///         missed its participation floor, so nothing was adjudicated and
    ///         both sides unwind whole.
    /// @dev    `Inconclusive` IS DELIBERATELY THE ZERO VALUE. A
    ///         default-initialized `Verdict` — an uninitialized local, a
    ///         zeroed struct field, a decoding bug that leaves the value
    ///         unset — must land on the harmless full unwind, never on
    ///         `Guilty`'s max-slash conviction.
    enum Verdict {
        Inconclusive,
        NotGuilty,
        Guilty
    }

    /// @param frozenCoverageUsd The coverage this challenge pinned, in USD-18,
    ///        snapshotted at filing. The bond was sized against it. It is NOT
    ///        what the eventual verdict is worth (review, minor) — the verdict
    ///        is sized by `slashBpsFor` against live bonds at resolve time, and
    ///        the two diverge whenever a bond moved in between. Written once
    ///        and never read on-chain: it exists for indexers and for auditing
    ///        the bond arithmetic against the filing.
    /// @param counterBondWood The counter-bond POOL raised so far, summed over
    ///        every accused approver that has contributed. There is deliberately
    ///        NO single `disputer` field any more: the defence is bought
    ///        collectively, so the payer set is a list
    ///        (`counterBondContributors`) rather than one address. `Filed`
    ///        implies this is strictly below `bondWood`; `Disputed` implies it
    ///        is exactly `bondWood`, because the status flips in the very call
    ///        that completes the pool.
    /// @param adapterTarget The adapter the challenger accuses, demoted on a
    ///        passed challenge (§3.4). The zero address means the filing
    ///        accuses no adapter — see `file`.
    /// @param adapterSelector The accused adapter's selector.
    /// @param executedAt The challenged proposal's execution timestamp, PINNED
    ///        at filing. It is the slash basis (`openedAt`) the verdict is
    ///        sized against, and pinning it is what makes the conviction
    ///        recoverable: any instant at or after the accusation is one the
    ///        accused can move its own stake checkpoint to (review 🔴F1, 🟡F10).
    /// @param vault The challenged proposal's vault, likewise pinned at filing
    ///        rather than re-read from a mutable governor at resolve time.
    /// @param autoSlashDelayAtFiling The silence window this challenge actually
    ///        received, snapshotted at filing. Reading the live parameter let
    ///        the owner retroactively close a window the accused was still
    ///        inside — precisely what `MIN_AUTO_SLASH_DELAY` claims to prevent
    ///        and did not (review 🟠F5).
    /// @param disputeTimeoutAtFiling The escalation clock this challenge
    ///        received, snapshotted for the same reason from the other side: a
    ///        live read let the owner extend an existing freeze 6x.
    /// @param settleBurnBpsAtFiling The settle-path burn rate in force when this
    ///        challenge was filed (review 🔵F15). Pinned for the same reason as
    ///        the clocks above: read live, the owner could raise it after a
    ///        filing and take up to half the refund of a challenge that turned
    ///        out to be CORRECT. The earlier argument for leaving it live — that
    ///        it "prices the refund rather than bounding a window the accused is
    ///        relying on" — does not hold, because the challenger relied on it
    ///        when it decided to file and has no way to withdraw afterwards.
    /// @param forfeitBurnBpsAtFiling The fail-path burn rate in force at filing,
    ///        pinned for the symmetric reason. Its victims are the accused who
    ///        funded the counter-bond: they commit WOOD to a pool whose payout
    ///        this rate scales, so a raise after they paid in shrinks what they
    ///        collect for a defence that WON.
    /// @param convictionBountyBpsAtFiling The conviction-bounty rate in force at
    ///        filing (spec 2026-07-29 §2), pinned for the same reason as the
    ///        clocks and burn rates above: read live, the owner could raise it
    ///        after a filing and change what the challenger stood to collect on
    ///        a conviction it had already committed its bond toward. Forwarded
    ///        to `IStakedWood.slashToEscrow` as `bountyBps` — but ONLY on an
    ///        escalated (`Guilty`-ruled) conviction, never on the silence
    ///        settle. See `ChallengeGame._settle`.
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
        uint256 convictionBountyBpsAtFiling;
        /// @dev The forfeited challenger bond, net of the fail-path burn, that
        ///      the pool's funders split pro-rata to what each put in. Written
        ///      once by `_fail`, read by `claimContribution`, zero on every
        ///      other path. Storing the TOTAL rather than paying it out is what
        ///      lets a claimant compute its own share in O(1).
        uint256 forfeitPayoutWood;
        /// @dev The Inconclusive-unwind burn rate in force at filing (review
        ///      #1, 2026-07-30; escalated per round since owner decision
        ///      2026-07-30), pinned for the same reason as every other rate
        ///      above: the challenger relied on it when it decided to post
        ///      the bond, and cannot withdraw once a court vote misses its
        ///      participation floor out from under it. NOT a flat rate — the
        ///      value pinned here is whatever
        ///      `ChallengeGame._inconclusiveBurnBpsForRound` computed for this
        ///      proposal's round count AT FILING TIME (0 on a proposal's first
        ///      attempt, escalating from there), so two challenges against the
        ///      same proposal can carry different pinned rates depending on
        ///      how many prior `Inconclusive` rounds preceded each. See
        ///      `ChallengeGame._refundAll` and `IChallengeGame.inconclusiveRounds`.
        ///
        ///      TRUE APPEND, not grouped with the other `*AtFiling` rates
        ///      above (review round 2, 2026-07-30): `forfeitPayoutWood` was
        ///      already the trailing field at `9f3a07a`, and inserting this
        ///      one ahead of it — however naturally it reads alongside its
        ///      sibling rates — would shift `forfeitPayoutWood`'s tuple
        ///      position for anything decoding `challengeOf()` positionally.
        ///      Appending after it costs nothing but the grouping.
        uint256 inconclusiveBurnBpsAtFiling;
    }

    // ── Errors ──
    error NotExecuted();
    error WindowClosed();
    error AlreadyChallenged();
    /// @dev The proposal's one liability has already been collected by a settled
    ///      challenge, so no further filing against it can reach a verdict — it
    ///      would settle straight into `VerdictAlreadyCollected`. Refused at the
    ///      door because such a filing still FROZE the coverage on the way, and
    ///      the freeze is what bars an accused approver from
    ///      `claimUnstakeGuardian`: it bought another `autoSlashDelay` of lock on
    ///      already-slashed collateral for the price of `settleBurnBps` on a
    ///      refunded bond, from as many addresses as the griefer cared to fund
    ///      (review 🟡F12).
    error AlreadyConvicted();
    error NothingToFreeze();
    error WrongStatus();
    error DelayNotElapsed();
    error NotAccusedApprover();
    error ZeroAddress();
    error InvalidParameter();
    /// @dev No WOOD price is configured on the ledger, so a bond cannot be
    ///      denominated at all. TRANSIENT and protocol-wide: nothing is
    ///      challengeable until governance sets one. Split out from
    ///      `InvalidParameter` because it shared that error with `BondTooSmall`,
    ///      and the two call for opposite responses (review 🔵F14).
    error WoodPriceUnset();
    /// @dev The bond floored to zero, so the filing would have bought its freeze
    ///      for nothing. PERMANENT and specific to this proposal: nobody can
    ///      ever challenge it while that coverage and that WOOD price stand.
    ///      Wants a `MIN_BOND` floor rather than a revert if it turns out to be
    ///      reachable in practice; naming it is what makes that visible.
    error BondTooSmall();
    /// @notice A counter-bond contribution that would move nothing — a zero
    ///         `amountWood`. The pool being already full cannot reach this: the
    ///         completing contribution flips the status to `Disputed`, so a later
    ///         caller is rejected by `WrongStatus` first.
    error NothingToContribute();
    /// @notice `claimContribution` found nothing owed — the caller never
    ///         contributed, has already claimed, or the challenge ended on the
    ///         guilty-ruling path where the whole pool forfeits to the
    ///         challenger and the funders are owed nothing.
    error NothingToClaim();
    /// @notice `claimContribution` on a challenge that is not yet terminal.
    ///         Entitlements are only knowable once the outcome is fixed.
    error ChallengeNotTerminal();
    /// @notice `rule` called by anything other than the wired court (§3.5).
    /// @dev    Also what an UNWIRED game reverts with, since `court` is then the
    ///         zero address and no caller can match it — Plan D's timeout stays
    ///         the only way out of `Disputed`.
    error NotCourt();
    /// @dev `resolve` was called with too little gas to guarantee the
    ///      `openCase` child inside `slashToEscrow` cannot starve — a starved
    ///      child is indistinguishable from a missing selector there and
    ///      BURNS the victims' compensation (PR #24 round-4 N-4). Retry with
    ///      more gas; nothing about the challenge state changes.
    error InsufficientSlashGas();
    /// @dev The filing named an adapter `(target, selector)` that does not
    ///      appear in the challenged proposal's own execute calls. A challenge
    ///      is an assertion, but WHICH adapter a proposal touched is not an
    ///      assertion — it is on-chain fact, and a full refund on the settle
    ///      path made demoting an arbitrary certified adapter free (review
    ///      🟠F4). This is a membership test over stored calls, not a second
    ///      calldata parser, so D1's one-security-model rule is intact.
    error AdapterNotInProposal();
    /// @notice `file` refused because the owner has paused NEW filings (spec §4:
    ///         the owner's only lever gating filings). Never raised anywhere
    ///         else — dispute/resolve/rule/claims are unaffected by this flag.
    error FilingsPaused();
    /// @notice A setter would break the cross-contract invariant `autoSlashDelay
    ///         + voteWindow + FINALIZE_BUFFER <= disputeTimeout` (B3). Raised by
    ///         `setAutoSlashDelay` and `setDisputeTimeout` — see
    ///         `ChallengeGame._requireWindowFits` for why neither contract can
    ///         hold this alone.
    error WindowInvariantViolated();

    // ── Events ──
    /// @dev `evidenceURI` is carried on-chain unindexed so predicates 2 and 3 —
    ///      the ones no chain can check — still have their off-chain evidence
    ///      pointer anchored to the filing.
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
    event ChallengeDisputed(uint256 indexed challengeId, uint256 counterBondWood);
    /// @notice The pool-completing `dispute` call tried `TokenCourt.refer` on
    ///         the challenger's behalf and the court reverted (Task 8:
    ///         best-effort auto-referral). The dispute itself still landed —
    ///         status flipped to `Disputed`, the counter-bond transfer
    ///         cleared — and `refer` stays permissionless, so ANY caller may
    ///         retry it directly against the court until `InsufficientClock`
    ///         closes that window. This is the recoverable half of the
    ///         asymmetry with `finalize`'s selector-filtered catch on
    ///         `IChallengeGame.rule`: a dropped verdict there was terminal
    ///         with no retry path, so that catch may not be broad; a skipped
    ///         referral here always has one, so this catch may be.
    event AutoReferFailed(uint256 indexed challengeId);
    /// @param slashedWood What the compensation escrow (or the burn fallback)
    ///        actually received — NOT the gross amount taken off the accused.
    ///        On a CONTESTED escalated conviction (spec 2026-07-29 §2) this is
    ///        NET of the conviction bounty paid to the challenger, since
    ///        `IStakedWood.slashToEscrow` deducts the bounty before the escrow
    ///        ever sees the proceeds; on the silence path, and on an escalated
    ///        conviction the challenger itself funded (see `ChallengeGame.
    ///        _settle`'s `contested` gate), no bounty is paid and this equals
    ///        the gross slash.
    event ChallengeSettled(uint256 indexed challengeId, uint256 slashedWood, uint256 caseId);
    /// @dev The slice of the challenger's bond burned on the SETTLE path
    ///      (`settleBurnBps`, review 🟠F4) or the INCONCLUSIVE unwind path
    ///      (`inconclusiveBurnBps`, review #1 2026-07-30) — a filing is never
    ///      free on either of the two paths where the challenger did nothing
    ///      wrong, because an unanswered or unresolved filing still froze a
    ///      cohort's coverage for the price of gas. Distinct from
    ///      `ChallengeFailed.burnedWood`, which is the FAIL-path burn
    ///      (`forfeitBurnBps`) charged to a challenger who was actually wrong;
    ///      a challenge only ever takes one of the three paths.
    event ChallengerBondBurned(uint256 indexed challengeId, uint256 burnedWood);
    /// @dev A settle that convicted nothing because an earlier challenge on the
    ///      same proposal already did. The approvers' liability is one
    ///      liability; concurrent filings do not multiply it.
    /// @dev  WORTH A FILER KNOWING: this challenge still pays the `settleBurnBps`
    ///       slice of its own bond (the silence-path burn applies regardless of
    ///       which concurrent challenge actually collected) and receives
    ///       nothing back beyond the remainder of its own bond — no slash
    ///       share, no bounty, because nothing was slashed on ITS behalf. A
    ///       second, independently correct challenger racing an already-
    ///       settled one is therefore net `-settleBurnBps` of its bond for a
    ///       filing that could never have collected — spec-compliant (the
    ///       liability really was already collected) but easy to miss before
    ///       filing a second challenge against a proposal that may already be
    ///       resolved.
    event VerdictAlreadyCollected(uint256 indexed challengeId, address indexed governor, uint256 indexed proposalId);
    /// @dev A passed challenge whose adapter demotion did NOT land, because the
    ///      registry refused the call — in practice because the game's
    ///      `authorizedDemoter` role was rotated away while the challenge was
    ///      live. The demotion is best-effort precisely so that cannot strand
    ///      the slash, the bond refund and the freeze release behind it (review
    ///      🟠F11); this event is how the miss becomes visible rather than
    ///      silent, and the registry owner's own `demote` is the remedy.
    event AdapterDemotionFailed(uint256 indexed challengeId, address indexed target, bytes4 indexed selector);
    /// @param forfeitedWood What the CHALLENGER lost — its whole bond on the
    ///        normal failure path, and zero on the defensive no-contributor
    ///        branch where the bond is handed back instead.
    /// @param burnedWood The slice of that forfeit destroyed rather than paid
    ///        out (`forfeitBurnBps`). The contributors therefore share
    ///        `forfeitedWood - burnedWood`; the two are reported separately
    ///        because they answer different questions — what filing cost, and
    ///        what the defence actually collected.
    event ChallengeFailed(uint256 indexed challengeId, uint256 forfeitedWood, uint256 burnedWood);
    /// @dev Emitted BEFORE the settle/fail/refund it causes, so an indexer
    ///      reading the log in order sees the verdict and then the accounting
    ///      it produced.
    event ChallengeRuled(uint256 indexed challengeId, Verdict verdict);
    /// @notice Inconclusive unwind: challenger bond returned minus the
    ///         escalating Inconclusive burn (owner decision 2026-07-30), pool
    ///         booked for pull-claims, no conviction, no demotion (spec
    ///         2026-07-28 §4).
    /// @dev    `bondWood` and `poolWood` always satisfy `bondWood == poolWood`
    ///         today, since `rule` only reaches this from `Disputed`, where the
    ///         pool is by construction complete. Reported as two separate
    ///         fields anyway rather than folded into one, so the log stays
    ///         truthful if the reachable set ever widens to an entry with a
    ///         part-funded pool.
    /// @dev    `bondWood` IS THE GROSS, PRE-BURN AMOUNT (review round 3,
    ///         2026-07-30 — flagged, not changed) — not what the challenger
    ///         actually received. `ChallengerBondBurned`, emitted alongside on
    ///         the same transaction whenever the burn is non-zero, carries the
    ///         slice that did not go to the challenger; the two logs together
    ///         are exact, but a consumer reading only this event's `bondWood`
    ///         and treating it as "proceeds to the challenger" over-reports by
    ///         the burned amount. Same shape as `ChallengeFailed`, which
    ///         likewise reports its `forfeitedWood` gross alongside a separate
    ///         `burnedWood`.
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
    event ConvictionBountyBpsSet(uint256 oldBps, uint256 newBps);
    event InconclusiveBurnBpsSet(uint256 oldBps, uint256 newBps);

    // ── Filing ──
    /// @notice File a bonded challenge against an executed proposal, freezing
    ///         the coverage its approvers committed.
    /// @param governor        The governor that executed the proposal.
    /// @param proposalId      The executed proposal being accused.
    /// @param predicate       The §3.4 predicate cited — a label for watchtowers
    ///                        and judges; it changes nothing about the path taken.
    /// @param adapterTarget   The adapter the challenger accuses of misbehaving,
    ///                        demoted if the challenge passes (§3.4: "adapters
    ///                        demote only on a passed challenge"). THE CHALLENGER
    ///                        NAMES IT rather than the chain deriving it from the
    ///                        proposal's calls: deriving would mean a second
    ///                        calldata parser beside the vault's
    ///                        `_guardBatchCalls`, which is the exact duplication
    ///                        D1 removed, and a multi-call proposal has no single
    ///                        derivable culprit anyway. Pass the zero address to
    ///                        accuse no adapter — predicates 2, 3 and 5 often
    ///                        indict a price, a destination or an envelope rather
    ///                        than a certification, and a filing that names
    ///                        nothing simply demotes nothing.
    /// @param adapterSelector The accused adapter's selector. Ignored when
    ///                        `adapterTarget` is the zero address.
    /// @param evidenceURI     Off-chain pointer to the evidence backing the
    ///                        assertion.
    /// @return challengeId The new challenge's id.
    function file(
        address governor,
        uint256 proposalId,
        Predicate predicate,
        address adapterTarget,
        bytes4 adapterSelector,
        string calldata evidenceURI
    ) external returns (uint256 challengeId);

    // ── Dispute / resolution ──
    /// @notice Contribute to the counter-bond POOL of a filed challenge. The
    ///         pool's target is the challenger's own bond; the challenge becomes
    ///         `Disputed` — stopping the auto-slash clock and escalating to the
    ///         court (§3.5) — the moment the pool reaches it.
    /// @param  challengeId The filed challenge to defend.
    /// @param  amountWood  WOOD to contribute. CLAMPED to the shortfall, so an
    ///                     over-sized amount (`type(uint256).max` is the idiom
    ///                     for "whatever is left") pulls only what the pool still
    ///                     needs. Nobody can overpay, so no refund-of-excess path
    ///                     exists to get wrong.
    /// @dev    THE BILL IS SHARED, THE PRICE IS NOT. The target stays pinned to
    ///         the challenger's bond rather than being scaled to the caller's own
    ///         share, and that is the whole design constraint: the accused side
    ///         picks who disputes, so any rule keyed to the DISPUTER's share
    ///         would just be answered by nominating — or manufacturing — the
    ///         smallest identity. Splitting one operator into two guardians
    ///         therefore changes who pays, never how much.
    /// @dev    Callable only by an accused approver (non-zero committed share) of
    ///         the challenged proposal — the accused buy their own escalation,
    ///         and it is what bounds the contributor list. Only strictly before
    ///         `filedAt + autoSlashDelay`, the same instant `resolve` starts
    ///         settling an undisputed challenge: at that second the silence
    ///         verdict is already final (D1) and there is nothing left to buy.
    function dispute(uint256 challengeId, uint256 amountWood) external;

    /// @notice Permissionless resolution. From `Filed` past `autoSlashDelay` the
    ///         silence is the verdict and the accused are slashed into the
    ///         compensation escrow; from `Disputed` past `disputeTimeout` the
    ///         challenge fails to the accused (D5). Reverts otherwise.
    function resolve(uint256 challengeId) external;

    /// @notice The court's verdict on a DISPUTED challenge (spec §3.5, Plan E;
    ///         three-valued since spec 2026-07-28 §4). Callable only by
    ///         `court`, and only from `Disputed` — a `Filed` challenge is still
    ///         inside its own auto-slash clock and has not been escalated to
    ///         anyone.
    /// @dev    THE COURT SUPPLIES ONLY THE VERDICT ENUM and can vary nothing
    ///         else. `Guilty` takes the identical path an UNDISPUTED challenge
    ///         takes — slash at sWOOD's `maxSlashBps` with no severity ramp
    ///         (§3.5 "ground truth established", D7), the named adapter
    ///         demoted, the challenger's bond returned — `NotGuilty` the
    ///         identical path the timeout takes, and `Inconclusive` (§4) unwinds
    ///         BOTH sides whole: no slash, no demotion, no conviction, because
    ///         the vote missed its participation floor and never reached a
    ///         verdict on the merits at all. There is deliberately no severity
    ///         argument: a court that could dial the slash would be negotiating
    ///         with the accused rather than ruling on them.
    /// @dev    A RULING BEATS THE TIMEOUT. All three outcomes are terminal, and
    ///         `resolve` only acts on `Filed`/`Disputed`, so once the court has
    ///         ruled the clock can no longer overwrite the verdict — which is
    ///         the whole point: it is what stops a guilty approver disputing and
    ///         running out `disputeTimeout`.
    function rule(uint256 challengeId, Verdict verdict) external;

    // ── Views ──
    function challengeOf(uint256 challengeId) external view returns (Challenge memory);
    /// @notice Everyone that has put WOOD into a challenge's counter-bond pool,
    ///         in first-contribution order and without duplicates. This is the
    ///         payout set on the failure path — a failed challenge's forfeited
    ///         bond splits pro-rata across THIS list, not across the accused set.
    function counterBondContributors(uint256 challengeId) external view returns (address[] memory);
    /// @notice What one address has contributed to a challenge's counter-bond
    ///         pool. Retained after resolution, so the split a terminal challenge
    ///         paid out stays auditable on-chain.
    function counterBondContributionOf(uint256 challengeId, address contributor) external view returns (uint256);

    /// @notice Collect what a terminal challenge owes you for funding its
    ///         counter-bond: your stake back, plus your pro-rata slice of the
    ///         forfeited challenger bond when the challenge FAILED.
    /// @dev    PULL, NOT PUSH, and that is the point. `_fail` and `_settle` used
    ///         to loop the contributor list and transfer to each — so the list
    ///         had to stay short, which is why `dispute` was restricted to the
    ///         accused. One reverting or blocklisted recipient would also have
    ///         bricked the whole resolution, stranding both bonds and leaving
    ///         the coverage frozen.
    ///
    ///         Resolution now stores the total to split and each claimant
    ///         computes its own share on the way out, so the payout is O(1) per
    ///         claimant and the list length is irrelevant. That is what makes
    ///         open contribution standing safe.
    ///
    ///         Rounding: shares are floor-divided independently, so up to
    ///         `contributors - 1` wei of a failed challenge's payout is never
    ///         claimable. The push version handed that remainder to the last
    ///         recipient; distributing it lazily is not possible without the
    ///         loop this exists to remove. Bounded at wei scale and left in the
    ///         contract, still covered by `unclaimedWood`.
    function claimContribution(uint256 challengeId) external returns (uint256 amount);

    /// @notice What `claimContribution` would pay `contributor` right now — the
    ///         stake plus, on the failed path, its slice of the forfeit. Zero
    ///         once claimed, and zero on the guilty-ruling path.
    function claimableContribution(uint256 challengeId, address contributor) external view returns (uint256);

    /// @notice WOOD owed to counter-bond funders of terminal challenges and not
    ///         yet collected.
    /// @dev    `bondedWood` keeps its meaning — WOOD held for LIVE challenges —
    ///         so the §4 invariant becomes
    ///         `wood.balanceOf(game) >= bondedWood + unclaimedWood`. Splitting
    ///         the two keeps "no live challenge implies `bondedWood == 0`" true,
    ///         which several tests and the fuzz invariant rely on.
    function unclaimedWood() external view returns (uint256);
    /// @notice The MOST RECENTLY FILED challenge against a proposal if it is
    ///         still live (`Filed`/`Disputed`), or zero.
    /// @dev    Filings are per-challenger, so this is no longer "the" live
    ///         challenge: an older one may still be live when the newest has
    ///         gone terminal. Ask `liveChallengeCountOf` whether ANY is live,
    ///         and `liveChallengeOfBy` for a specific challenger's slot.
    function liveChallengeOf(address governor, uint256 proposalId) external view returns (uint256);
    /// @notice How many challenges against this proposal are live. Non-zero is
    ///         exactly the condition under which its coverage stays frozen.
    function liveChallengeCountOf(address governor, uint256 proposalId) external view returns (uint256);
    /// @notice `challenger`'s own live challenge against this proposal, or zero.
    ///         One slot per challenger is what stops the accused cohort from
    ///         squatting the only slot for the whole window (review 🔴F3).
    function liveChallengeOfBy(address governor, uint256 proposalId, address challenger) external view returns (uint256);
    function challengeCount() external view returns (uint256);
    function challengeWindow() external view returns (uint256);
    function challengerBondBps() external view returns (uint256);
    /// @notice The slice of a FAILED challenge's forfeited bond that is
    ///         destroyed instead of being paid to the counter-bond's funders,
    ///         in bps. It exists because the accused side can be the challenger:
    ///         one operator can file against its own proposal and fund the whole
    ///         counter-bond pool, and a forfeit paid entirely to contributors
    ///         then returns to the address that posted it, making the whole
    ///         round trip free. Burning is the only sink with no beneficiary the
    ///         attacker can reach — see `ChallengeGame.BURN_ADDRESS`.
    function forfeitBurnBps() external view returns (uint256);
    function autoSlashDelay() external view returns (uint256);
    function disputeTimeout() external view returns (uint256);
    /// @notice Share of a SUCCESSFUL challenger's bond burned on settle, in bps.
    ///         Applies to the settle path only: the fail path already forfeits
    ///         the whole bond to the accused (§3.4).
    function settleBurnBps() external view returns (uint256);
    /// @notice Slice of a verdict slash paid to the challenger that caused it
    ///         (spec 2026-07-29 §2). Pinned per challenge at filing.
    /// @dev    ESCALATED CONVICTIONS ONLY, and never while a dispute is open.
    ///         `_settle` is the sole payer and it is reached only by the
    ///         silence timeout or a `Guilty` ruling; of those two it forwards a
    ///         non-zero rate ONLY for the ruling. A `NotGuilty` ruling, an
    ///         `Inconclusive` unwind and the dispute timeout all route through
    ///         `_fail`/`_refundAll`, which slash nothing and so pay nothing.
    function convictionBountyBps() external view returns (uint256);
    /// @notice The ROUND-4-AND-BEYOND steady-state share of the challenger's
    ///         bond burned on an `Inconclusive` unwind, in bps (owner decision
    ///         2026-07-30). NOT the whole story: rounds 1-3 follow a fixed,
    ///         lower schedule (round 1 free, rising through fixed 5%/10%
    ///         steps) before reaching this ceiling — see
    ///         `inconclusiveRounds` and `ChallengeGame._inconclusiveBurnBpsForRound`
    ///         for the full schedule and why it escalates with repetition
    ///         rather than staying flat.
    /// @dev    Every OTHER terminal path prices the freeze a filing buys — the
    ///         silence settle burns `settleBurnBps`, a failed challenge
    ///         forfeits the whole bond, an escalated guilty verdict correctly
    ///         charges nothing because the filing was right — except
    ///         `Inconclusive` did not, until review #1 (2026-07-30) added a
    ///         flat burn here. A follow-up audit found the flat rate still
    ///         left `Inconclusive` the CHEAPEST repeatable freeze in the
    ///         contract (a flat percentage cannot distinguish an honest
    ///         one-shot filer from a grinder, since it is invariant to
    ///         repetition), so the rate now escalates with the round count
    ///         instead and this variable is only its final tier.
    ///         Deliberately kept BELOW the LIVE `settleBurnBps`, never above it
    ///         — a non-verdict recovered nothing, so it must never cost the
    ///         challenger more than a verdict that actually recovered value.
    ///         Enforced by `setInconclusiveBurnBps`/`setSettleBurnBps` each
    ///         cross-checking the OTHER's current value (review round 2,
    ///         2026-07-30) — sharing a ceiling with `settleBurnBps` bounds
    ///         both rates' maximums identically but says nothing about where
    ///         either live rate actually sits, which a ceiling-only check on
    ///         each setter left open. That cross-check covers ONLY this
    ///         round-4+ tier — rounds 2 and 3 are fixed constants outside the
    ///         setter pair, additionally clamped live at the point the rate is
    ///         computed (see `_inconclusiveBurnBpsForRound`).
    function inconclusiveBurnBps() external view returns (uint256);
    /// @notice WOOD the game holds on behalf of live (`Filed`/`Disputed`)
    ///         challenges. The §4 invariant is `wood.balanceOf(game) >=
    ///         bondedWood`; the game pays out nothing but bonds, so the two are
    ///         equal except for WOOD donated here by mistake.
    function bondedWood() external view returns (uint256);
    /// @notice The §3.5 adjudicator allowed to `rule` on disputed challenges, or
    ///         the zero address while none is wired — in which case Plan D's
    ///         behaviour is unchanged and `Disputed` remains terminal-by-timeout.
    function court() external view returns (address);
    /// @notice The owner's only lever that gates NEW filings (spec §4): true
    ///         refuses `file` alone. dispute/resolve/rule/claims always run
    ///         unaffected by this flag. It is not a claim that a live
    ///         challenge is fully insulated from the owner — see
    ///         `ChallengeGame.filingsPaused` for what actually is (the
    ///         `*AtFiling` economic pins) and what deliberately is not
    ///         (`court`, read live by `rule`).
    function filingsPaused() external view returns (bool);
    /// @notice Per-proposal deadline for NEW filings, raised (never lowered)
    ///         whenever a challenge on that proposal unwinds `Inconclusive`
    ///         (spec 2026-07-29 §5). `file` gates on the LARGER of this value
    ///         and `executedAt + challengeWindow` — zero is not a sentinel
    ///         here, it is simply what an untouched key contributes to that
    ///         max.
    /// @dev    WITHOUT A RAISED FLOOR, `INCONCLUSIVE` IS A PERMANENT
    ///         ACQUITTAL. Reaching it takes anywhere from `voteWindow` (the
    ///         accused's counter-bond pool may complete the instant it is
    ///         filed) up to `autoSlashDelay + voteWindow` (the accused stalls
    ///         completion to the edge of `autoSlashDelay` first) — roughly 5
    ///         to 12 days at the defaults, and the accused chooses where in
    ///         that span it lands. So a challenge filed more than ~2 days
    ///         after execution could, in the worst case, never be re-filed,
    ///         and stalling let the accused force exactly that worst case:
    ///         "the electorate did not turn out" became "the accused wins,
    ///         finally". Raising the floor on every unwind turns the stall
    ///         into a delay instead of an acquittal.
    function challengeableUntil(bytes32 reviewKey) external view returns (uint256);
    /// @notice How many times this proposal has gone `Inconclusive` since the
    ///         last time the re-challenge window lapsed with nobody refiling
    ///         inside it (owner decision 2026-07-30). Drives the escalating
    ///         Inconclusive-burn schedule (`ChallengeGame._inconclusiveBurnBpsForRound`)
    ///         — round 1 (count 0) is free, and the rate climbs from there.
    /// @dev    KEYED ON THE PROPOSAL ALONE, not `(reviewKey, challenger)` — the
    ///         same tradeoff `_convicted` and `challengeableUntil` already
    ///         make: a per-challenger counter would let a sybil reset the
    ///         escalation for free by switching addresses between rounds.
    ///         RESET, not merely capped, whenever `challengeableUntil` has
    ///         naturally lapsed — see `ChallengeGame.file`'s own comment for
    ///         why that specific condition is what "the grind stopped" means
    ///         here, as opposed to a simpler elapsed-time clock.
    function inconclusiveRounds(bytes32 reviewKey) external view returns (uint256);

    // ── Owner setters ──
    /// @notice Wire (or unwire) the court. The zero address is DELIBERATELY
    ///         permitted: it is how governance revokes a compromised court and
    ///         falls back to Plan D's fail-safe timeout rather than leaving a
    ///         hostile adjudicator able to force slashes.
    function setCourt(address newCourt) external;
    function setExposureLedger(address ledger) external;
    function setTierRegistry(address registry) external;
    function setStakedWood(address stakedWood_) external;
    function setChallengeWindow(uint256 newWindow) external;
    function setChallengerBondBps(uint256 newBps) external;
    /// @notice Set the burned slice of a failed challenge's forfeit. Bounded by
    ///         a ceiling well below the whole bond, and ZERO IS PERMITTED —
    ///         unlike `setChallengerBondBps`, where zero would make the freeze
    ///         free. Zero here only restores the pre-burn behaviour (the entire
    ///         forfeit paid to the funders) and re-opens the self-challenge
    ///         round trip; it is a governance off-switch, not a broken state.
    function setForfeitBurnBps(uint256 newBps) external;
    function setAutoSlashDelay(uint256 newDelay) external;
    function setDisputeTimeout(uint256 newTimeout) external;
    /// @notice Set the settle-path burn. ALSO REJECTS dropping below the LIVE
    ///         `inconclusiveBurnBps` (review round 2, 2026-07-30): the two
    ///         rates share a ceiling, but a ceiling-only check on this setter
    ///         let it fall below an unchanged `inconclusiveBurnBps`, inverting
    ///         the ordering that burn exists to guarantee.
    /// @dev    OPERATOR NOTE (review round 3, 2026-07-30): this is now the
    ///         ONLY way this setter can revert on a value that looks
    ///         reasonable in isolation — a call that would have succeeded
    ///         before the Inconclusive burn existed can fail today purely
    ///         because `inconclusiveBurnBps` (the escalating schedule's
    ///         round-4+ tier) has not been lowered first. This setter does
    ///         NOT, however, guard the escalating schedule's fixed round-2/3
    ///         steps (500/1,000 bps) — those are clamped live at the point
    ///         `file` computes the pinned rate
    ///         (`ChallengeGame._inconclusiveBurnBpsForRound`), not here, so a
    ///         low `settleBurnBps` never blocks filing itself.
    function setSettleBurnBps(uint256 newBps) external;
    function setFilingsPaused(bool paused) external;
    function setConvictionBountyBps(uint256 newBps) external;
    /// @notice Set the round-4-and-beyond steady state of the escalating
    ///         Inconclusive-burn schedule. Bounded by a ceiling at or below
    ///         `settleBurnBps`'s own, AND rejects rising above the LIVE
    ///         `settleBurnBps` itself (review round 2, 2026-07-30) — a
    ///         non-verdict must never be allowed to cost more than a verdict
    ///         that actually recovered value, and the shared ceiling alone
    ///         did not guarantee that ordering against the live rates. Zero
    ///         is legal and floors the round-4+ tier to nothing (rounds 1-3
    ///         are unaffected — they are fixed constants, not derived from
    ///         this variable).
    function setInconclusiveBurnBps(uint256 newBps) external;
}
