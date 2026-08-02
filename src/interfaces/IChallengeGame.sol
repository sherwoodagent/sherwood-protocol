// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IChallengeGame
/// @notice Bonded challenges against executed proposals (spec 2026-07-22 §3.4)
///         — the trigger above the slash rails. Slash proceeds are BURNED, not
///         compensated: the protocol punishes the approver, it does not
///         reimburse the vault.
///
///         A challenge is an ASSERTION with an evidence pointer, never an
///         on-chain proof: an undisputed challenge slashes after a delay, a
///         disputed one goes to adjudication. No predicate is verified
///         on-chain — some need a venue-specific fair-value model or a
///         funding-graph analysis a chain can't do, and enforcing some
///         predicates in code while judge-enforcing the rest would run two
///         security models in one mechanism. Adjudication is SILENCE: not
///         contesting IS the verdict.
interface IChallengeGame {
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
    ///         nothing is proven on-chain (see `Predicate`), so a challenge is
    ///         only ever live (`Filed`/`Disputed`) or terminal
    ///         (`Failed`/`Settled`/`Inconclusive`). `Inconclusive` is a
    ///         terminal NON-VERDICT (see `Verdict`), reachable only from
    ///         `Disputed`, the same state `Failed`/`Settled` reach via a
    ///         court ruling.
    enum Status {
        None,
        Filed,
        Disputed,
        Failed,
        Settled,
        Inconclusive
    }

    /// @notice The court's three-valued outcome for a disputed challenge.
    ///         `Inconclusive` is a NON-VERDICT: the vote missed its
    ///         participation floor, so nothing was adjudicated and both
    ///         sides unwind whole.
    /// @dev    `Inconclusive` IS DELIBERATELY THE ZERO VALUE. A
    ///         default-initialized `Verdict` — an uninitialized local, a
    ///         zeroed struct field, a decoding bug that leaves the value
    ///         unset — must land on the harmless full unwind, never on
    ///         `Guilty`'s max-slash conviction.
    /// @dev    NOT THE SAME ORDER AS `ITokenCourt.Ruling`, AND A CAST BETWEEN
    ///         THE TWO IS NEVER VALID. `Ruling` is `{None, Guilty, NotGuilty}`;
    ///         this is `{Inconclusive, NotGuilty, Guilty}` — the two non-zero
    ///         values are INVERTED, so `Verdict(uint8(ruling))` silently
    ///         turns a `Guilty` ruling into a `NotGuilty` verdict and vice
    ///         versa. Each enum's zero value is pinned to its own safe
    ///         default (`Ruling.None` = "the court has not ruled";
    ///         `Verdict.Inconclusive` = "nothing was adjudicated, unwind
    ///         whole"), and those defaults are load-bearing where they sit.
    ///         `TokenCourt` therefore TRANSLATES explicitly, arm by arm,
    ///         when it calls `rule` — the only correct conversion between
    ///         them.
    enum Verdict {
        Inconclusive,
        NotGuilty,
        Guilty
    }

    /// @param frozenCoverageUsd The coverage this challenge pinned, in USD-18,
    ///        snapshotted at filing. The bond was sized against it. It is NOT
    ///        what the eventual verdict is worth — the verdict is punitive and
    ///        takes the severity ceiling of each convicted approver's live
    ///        bond, so the two are related only incidentally and diverge
    ///        whenever a bond moved or the cohort was over-covered. Written once
    ///        and never read on-chain: it exists for indexers and for auditing
    ///        the bond arithmetic against the filing.
    /// @param counterBondWood The counter-bond POOL raised so far, summed
    ///        over every accused approver that has contributed. There is
    ///        deliberately no single `disputer` field: the defence is bought
    ///        collectively, so the payer set is a list
    ///        (`counterBondContributors`) rather than one address. `Filed`
    ///        implies this is strictly below `bondWood`; `Disputed` implies
    ///        it equals `bondWood`, because the status flips in the call
    ///        that completes the pool.
    /// @param adapterTarget The adapter the challenger accuses, demoted on a
    ///        passed challenge. The zero address means the filing accuses no
    ///        adapter — see `file`.
    /// @param adapterSelector The accused adapter's selector.
    /// @param executedAt The challenged proposal's execution timestamp,
    ///        pinned at filing. It is the slash basis (`openedAt`) the
    ///        verdict is sized against, and pinning it keeps the conviction
    ///        recoverable: any instant at or after the accusation is one the
    ///        accused could otherwise move its own stake checkpoint past.
    /// @param vault The challenged proposal's vault, likewise pinned at
    ///        filing rather than re-read from a mutable governor at resolve
    ///        time.
    /// @param autoSlashDelayAtFiling The silence window this challenge
    ///        actually received, snapshotted at filing. Reading the live
    ///        parameter would let the owner retroactively close a window the
    ///        accused is still inside — exactly what `MIN_AUTO_SLASH_DELAY`
    ///        guards against.
    /// @param disputeTimeoutAtFiling The escalation clock this challenge
    ///        received, snapshotted for the same reason from the other
    ///        side: a live read would let the owner extend an existing
    ///        freeze several-fold.
    /// @param settleBurnBpsAtFiling The settle-path burn rate in force when
    ///        this challenge was filed. Pinned for the same reason as the
    ///        clocks above: read live, the owner could raise it after
    ///        filing and take up to half the refund of a challenge that
    ///        turned out to be correct — the challenger relied on the rate
    ///        when it decided to file and has no way to withdraw
    ///        afterwards.
    /// @param forfeitBurnBpsAtFiling The fail-path burn rate in force at
    ///        filing, pinned for the symmetric reason. Its victims are the
    ///        accused who funded the counter-bond: they commit WOOD to a
    ///        pool whose payout this rate scales, so a raise after they
    ///        paid in would shrink what they collect for a defence that
    ///        won.
    /// @param prosecutorFeeBpsAtFiling The prosecutor-fee rate in force at
    ///        filing, pinned for the same reason as the clocks and burn rates
    ///        above: read live, the owner could raise it after filing and
    ///        change what the challenger stood to collect on a conviction it
    ///        had already committed its bond toward. Forwarded to
    ///        `IProposerBondEscrow.forfeitBond` as `feeBps` on EVERY
    ///        conviction, silence settle included — it is a slice of the
    ///        proposer's forfeited bond, not of the slash, which pays no one.
    ///        See `ChallengeGame._settle`.
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
        /// @dev The Inconclusive-unwind burn rate in force at filing,
        ///      pinned for the same reason as every other rate above: the
        ///      challenger relied on it when it decided to post the bond,
        ///      and cannot withdraw once a court vote misses its
        ///      participation floor. Not a flat rate — the value pinned
        ///      here is whatever `ChallengeGame._inconclusiveBurnBpsForRound`
        ///      computed for this proposal's round count at filing time (0
        ///      on a proposal's first attempt, escalating from there), so
        ///      two challenges against the same proposal can carry
        ///      different pinned rates depending on how many prior
        ///      `Inconclusive` rounds preceded each. See
        ///      `ChallengeGame._refundAll` and
        ///      `IChallengeGame.inconclusiveRounds`.
        ///
        ///      Appended after `forfeitPayoutWood` rather than grouped with
        ///      the other `*AtFiling` rates: inserting it earlier would
        ///      shift `forfeitPayoutWood`'s tuple position for anything
        ///      decoding `challengeOf()` positionally.
        uint256 inconclusiveBurnBpsAtFiling;
        /// @dev The escrow holding this proposal's PROPOSER bond, pinned at
        ///      filing from `StrategyProposal.proposerBondEscrow` — the
        ///      same binding `SyndicateGovernor.reclaimProposerBond`
        ///      releases against. `_settle` confiscates it there on a
        ///      conviction.
        ///
        ///      Pinned rather than re-read, same reasoning as `vault` and
        ///      `executedAt`: a verdict can land a full `disputeTimeout`
        ///      after filing, and nothing about the escrow should be
        ///      movable in between by a governor upgrade or a re-pointed
        ///      escrow slot. Zero when the proposal locked no bond (no
        ///      ledger wired at propose, or `proposerBondBps` set to zero),
        ///      which the settle path treats as "nothing to forfeit" rather
        ///      than as an error.
        ///
        ///      Appended after `inconclusiveBurnBpsAtFiling` for the same
        ///      reason: anything decoding `challengeOf()` positionally
        ///      keeps every existing tuple index.
        address proposerBondEscrow;
    }

    // ── Errors ──
    error NotExecuted();
    error WindowClosed();
    error AlreadyChallenged();
    /// @dev The proposal's one liability has already been collected by a
    ///      settled challenge, so no further filing against it can reach a
    ///      verdict — it would settle straight into
    ///      `VerdictAlreadyCollected`. Refused at the door because such a
    ///      filing still FREEZES the coverage on the way, and the freeze is
    ///      what bars an accused approver from `claimUnstakeGuardian`: it
    ///      would buy another `autoSlashDelay` of lock on already-slashed
    ///      collateral for the price of `settleBurnBps` on a refunded bond,
    ///      from as many addresses as the griefer cares to fund.
    error AlreadyConvicted();
    error NothingToFreeze();
    error WrongStatus();
    error DelayNotElapsed();
    error NotAccusedApprover();
    error ZeroAddress();
    error InvalidParameter();
    /// @dev No WOOD price is configured on the ledger, so a bond cannot be
    ///      denominated at all. Transient and protocol-wide: nothing is
    ///      challengeable until governance sets one. Split out from
    ///      `InvalidParameter` because the two call for opposite responses.
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
    ///         contributed, has already claimed, or the challenge ended on the
    ///         guilty-ruling path where the whole pool forfeits to the
    ///         challenger and the funders are owed nothing.
    error NothingToClaim();
    /// @notice `claimContribution` on a challenge that is not yet terminal.
    ///         Entitlements are only knowable once the outcome is fixed.
    error ChallengeNotTerminal();
    /// @notice `rule` called by anything other than the wired court.
    /// @dev    Also what an unwired game reverts with, since `court` is
    ///         then the zero address and no caller can match it — the
    ///         timeout stays the only way out of `Disputed`.
    error NotCourt();
    /// @dev `resolve` was called with too little gas to guarantee the slash
    ///      loop can finish. Retry with more gas; nothing about the challenge
    ///      state changes. The floor is currently conservative — it was sized
    ///      around an external `openCase` child that no longer exists (see
    ///      `ChallengeGame.SLASH_GAS_BASE`).
    error InsufficientSlashGas();
    /// @dev The filing named an adapter `(target, selector)` that does not
    ///      appear in the challenged proposal's own execute calls. A
    ///      challenge is an assertion, but which adapter a proposal touched
    ///      is on-chain fact, not an assertion, and a full refund on the
    ///      settle path would otherwise make demoting an arbitrary
    ///      certified adapter free. This is a membership test over stored
    ///      calls, not a second calldata parser.
    error AdapterNotInProposal();
    /// @notice `file` refused because the owner has paused new filings —
    ///         the owner's only lever gating filings. Never raised anywhere
    ///         else — dispute/resolve/rule/claims are unaffected by this
    ///         flag.
    error FilingsPaused();
    /// @notice A setter would break the cross-contract invariant
    ///         `autoSlashDelay + voteWindow + FINALIZE_BUFFER <=
    ///         disputeTimeout`. Raised by `setAutoSlashDelay` and
    ///         `setDisputeTimeout` — see `ChallengeGame._requireWindowFits`
    ///         for why neither contract can hold this alone.
    error WindowInvariantViolated();
    /// @notice A role setter was pointed at a contract that has not granted
    ///         this game the reciprocal role it needs there — a ledger
    ///         whose `coverageFreezer` is not this address, or a sWOOD
    ///         whose `authorizedSlasher` is not this address.
    /// @dev    Both grants are two-sided, and moving only this side is a
    ///         wedge rather than a misconfiguration that surfaces
    ///         harmlessly: every terminal path of a live challenge routes
    ///         through `unfreezeCoverage` (which reverts
    ///         `NotCoverageFreezer`) and every conviction through
    ///         `slashVerdict` (which reverts on its own caller gate),
    ///         leaving bonds and the counter-bond pool with no exit and the
    ///         coverage frozen on a ledger that can no longer be told to
    ///         release it. Grant the role on the target contract first,
    ///         then re-point here.
    error RoleNotGranted();
    /// @notice `renounceOwnership` is disabled. Ownership is transferable
    ///         (`Ownable2Step`) but never abandonable.
    /// @dev    The owner-only escapes this design relies on —
    ///         `setStakedWood` as the un-wedge for a mis-wired slasher,
    ///         `setCourt(address(0))` as the off-switch for a captured
    ///         court — have no permissionless equivalent, so an ownerless
    ///         game is a game whose documented recoveries are all gone.
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
    event ChallengeDisputed(uint256 indexed challengeId, uint256 counterBondWood);
    /// @notice The pool-completing `dispute` call tried `TokenCourt.refer`
    ///         on the challenger's behalf and the court reverted — a
    ///         best-effort auto-referral. The dispute itself still landed —
    ///         status flipped to `Disputed`, the counter-bond transfer
    ///         cleared — and `refer` stays permissionless, so any caller
    ///         may retry it directly against the court until
    ///         `InsufficientClock` closes that window. This is the
    ///         recoverable half of the asymmetry with `finalize`'s
    ///         selector-filtered catch on `IChallengeGame.rule`: a dropped
    ///         verdict there is terminal with no retry path, so that catch
    ///         may not be broad; a skipped referral here always has one, so
    ///         this catch may be.
    event AutoReferFailed(uint256 indexed challengeId);
    /// @param slashedWood What was actually BURNED — NOT the gross amount taken
    ///        off the accused.
    ///        Gross and burned are now the same number on every path:
    ///        `IStakedWood.slashVerdict` takes no payee and burns everything it
    ///        collects. The prosecutor's fee is a slice of the PROPOSER's
    ///        forfeited bond instead and never touches this figure — see
    ///        `IProposerBondEscrow.ProsecutorFeePaid` for that leg.
    event ChallengeSettled(uint256 indexed challengeId, uint256 slashedWood);
    /// @dev The slice of the challenger's bond burned on the SETTLE path
    ///      (`settleBurnBps`) or the INCONCLUSIVE unwind path
    ///      (`inconclusiveBurnBps`) — a filing is never free on either path
    ///      where the challenger did nothing wrong, because an unanswered
    ///      or unresolved filing still froze a cohort's coverage for the
    ///      price of gas. Distinct from `ChallengeFailed.burnedWood`, which
    ///      is the FAIL-path burn (`forfeitBurnBps`) charged to a
    ///      challenger who was actually wrong; a challenge only ever takes
    ///      one of the three paths.
    event ChallengerBondBurned(uint256 indexed challengeId, uint256 burnedWood);
    /// @dev A settle that convicted nothing because an earlier challenge on the
    ///      same proposal already did. The approvers' liability is one
    ///      liability; concurrent filings do not multiply it.
    /// @dev  WORTH A FILER KNOWING: this challenge still pays the `settleBurnBps`
    ///       slice of its own bond (the silence-path burn applies regardless of
    ///       which concurrent challenge actually collected) and receives
    ///       nothing back beyond the remainder of its own bond — no slash
    ///       share and no prosecutor fee, because this settle collected no
    ///       liability and forfeited no bond on ITS behalf. A
    ///       second, independently correct challenger racing an already-
    ///       settled one is therefore net `-settleBurnBps` of its bond for a
    ///       filing that could never have collected — spec-compliant (the
    ///       liability really was already collected) but easy to miss before
    ///       filing a second challenge against a proposal that may already be
    ///       resolved.
    event VerdictAlreadyCollected(uint256 indexed challengeId, address indexed governor, uint256 indexed proposalId);
    /// @dev A passed challenge whose adapter demotion did NOT land, because
    ///      the registry refused the call — in practice because the game's
    ///      `authorizedDemoter` role was rotated away while the challenge
    ///      was live. The demotion is best-effort precisely so that cannot
    ///      strand the slash, the bond refund and the freeze release behind
    ///      it; this event is how the miss becomes visible rather than
    ///      silent, and the registry owner's own `demote` is the remedy.
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

    /// @notice A conviction could NOT confiscate the proposer bond —
    ///         already reclaimed, already forfeited by a concurrent
    ///         challenge, or an escrow that refused the call. Surfaced
    ///         rather than reverted for the same reason
    ///         `AdapterDemotionFailed` is: a terminal path must not be
    ///         hostage to a call that can fail, or the slash never lands
    ///         and the coverage never unfreezes.
    event ProposerBondForfeitureFailed(
        uint256 indexed challengeId, address indexed governor, uint256 indexed proposalId, address escrow
    );
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
    ///         escalating Inconclusive burn, pool booked for pull-claims,
    ///         no conviction, no demotion.
    /// @dev    `bondWood` and `poolWood` always satisfy `bondWood ==
    ///         poolWood` today, since `rule` only reaches this from
    ///         `Disputed`, where the pool is by construction complete.
    ///         Reported as two separate fields anyway rather than folded
    ///         into one, so the log stays truthful if the reachable set
    ///         ever widens to an entry with a part-funded pool.
    /// @dev    `bondWood` IS THE GROSS, PRE-BURN AMOUNT — not what the
    ///         challenger actually received. `ChallengerBondBurned`,
    ///         emitted alongside on the same transaction whenever the burn
    ///         is non-zero, carries the slice that did not go to the
    ///         challenger; the two logs together are exact, but a consumer
    ///         reading only this event's `bondWood` and treating it as
    ///         "proceeds to the challenger" over-reports by the burned
    ///         amount. Same shape as `ChallengeFailed`, which likewise
    ///         reports its `forfeitedWood` gross alongside a separate
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
    event ProsecutorFeeBpsSet(uint256 oldBps, uint256 newBps);
    event InconclusiveBurnBpsSet(uint256 oldBps, uint256 newBps);

    // ── Filing ──
    /// @notice File a bonded challenge against an executed proposal,
    ///         freezing the coverage its approvers committed.
    /// @param governor        The governor that executed the proposal.
    /// @param proposalId      The executed proposal being accused.
    /// @param predicate       The predicate cited — a label for
    ///                        watchtowers and judges; it changes nothing
    ///                        about the path taken.
    /// @param adapterTarget   The adapter the challenger accuses of
    ///                        misbehaving, demoted if the challenge passes.
    ///                        THE CHALLENGER NAMES IT rather than the chain
    ///                        deriving it from the proposal's calls:
    ///                        deriving would mean a second calldata parser
    ///                        beside the vault's `_guardBatchCalls`, and a
    ///                        multi-call proposal has no single derivable
    ///                        culprit anyway. Pass the zero address to
    ///                        accuse no adapter — some predicates indict a
    ///                        price, a destination or an envelope rather
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
    ///         pool's target is the challenger's own bond; the challenge
    ///         becomes `Disputed` — stopping the auto-slash clock and
    ///         escalating to the court — the moment the pool reaches it.
    /// @param  challengeId The filed challenge to defend.
    /// @param  amountWood  WOOD to contribute. CLAMPED to the shortfall, so
    ///                     an over-sized amount (`type(uint256).max` is the
    ///                     idiom for "whatever is left") pulls only what
    ///                     the pool still needs. Nobody can overpay, so no
    ///                     refund-of-excess path exists to get wrong.
    /// @dev    THE BILL IS SHARED, THE PRICE IS NOT. The target stays
    ///         pinned to the challenger's bond rather than being scaled to
    ///         the caller's own share, and that is the whole design
    ///         constraint: the accused side picks who disputes, so any rule
    ///         keyed to the DISPUTER's share would just be answered by
    ///         nominating — or manufacturing — the smallest identity.
    ///         Splitting one operator into two guardians therefore changes
    ///         who pays, never how much.
    /// @dev    PERMISSIONLESS — ANYONE MAY FUND THE DEFENCE. The
    ///         restriction answers "who may BUY the escalation" — but once
    ///         the counter-bond became a POOL that question is separate
    ///         from "who may help FILL it". `claimContribution` makes every
    ///         payout O(1) and pull-based, so contributor-list length is
    ///         not load-bearing. Skin in the game is enforced economically
    ///         instead — a `Guilty` ruling forfeits the whole pool to the
    ///         challenger, so an outside funder risks real capital.
    ///
    ///         Nothing about the contribution gates a payout any more.
    ///         `_settle` used to pay the conviction bounty only when one of
    ///         the ACCUSED funded the pool — a predicate the accused could
    ///         switch off for free by defending from an unrelated address
    ///         (issue #101). The prosecutor's fee now comes from the
    ///         proposer's forfeited bond and is gated on nothing here.
    /// @dev    Only strictly before `filedAt + autoSlashDelay`, the same
    ///         instant `resolve` starts settling an undisputed challenge:
    ///         at that second the silence verdict is already final and
    ///         there is nothing left to buy. The clock is the one the
    ///         challenge RECEIVED at filing (`autoSlashDelayAtFiling`), not
    ///         the live parameter.
    function dispute(uint256 challengeId, uint256 amountWood) external;

    /// @notice Permissionless resolution. From `Filed` past `autoSlashDelay` the
    ///         silence is the verdict and the accused are slashed, their bonds
    ///         burned; from `Disputed` past `disputeTimeout` the challenge fails
    ///         to the accused (D5). Reverts otherwise.
    function resolve(uint256 challengeId) external;

    /// @notice The court's verdict on a DISPUTED challenge. Callable only
    ///         by `court`, and only from `Disputed` — a `Filed` challenge
    ///         is still inside its own auto-slash clock and has not been
    ///         escalated to anyone.
    /// @dev    THE COURT SUPPLIES ONLY THE VERDICT ENUM and can vary
    ///         nothing else. `Guilty` takes the identical path an
    ///         UNDISPUTED challenge takes — slash at sWOOD's `maxSlashBps`
    ///         with no severity ramp, the named adapter demoted, the
    ///         challenger's bond returned — `NotGuilty` the identical path
    ///         the timeout takes, and `Inconclusive` unwinds BOTH sides
    ///         whole: no slash, no demotion, no conviction, because the
    ///         vote missed its participation floor and never reached a
    ///         verdict on the merits at all. There is deliberately no
    ///         severity argument: a court that could dial the slash would
    ///         be negotiating with the accused rather than ruling on them.
    /// @dev    A RULING BEATS THE TIMEOUT. All three outcomes are
    ///         terminal, and `resolve` only acts on `Filed`/`Disputed`, so
    ///         once the court has ruled the clock can no longer overwrite
    ///         the verdict — which is the whole point: it is what stops a
    ///         guilty approver disputing and running out `disputeTimeout`.
    function rule(uint256 challengeId, Verdict verdict) external;

    // ── Views ──
    function challengeOf(uint256 challengeId) external view returns (Challenge memory);
    /// @notice Everyone that has put WOOD into a challenge's counter-bond
    ///         pool, in first-contribution order and without duplicates.
    ///         This is the payout set on the failure path — a failed
    ///         challenge's forfeited bond splits pro-rata across THIS
    ///         list, not across the accused set.
    function counterBondContributors(uint256 challengeId) external view returns (address[] memory);
    /// @notice What one address has contributed to a challenge's
    ///         counter-bond pool. Retained after resolution, so the split
    ///         a terminal challenge paid out stays auditable on-chain.
    function counterBondContributionOf(uint256 challengeId, address contributor) external view returns (uint256);

    /// @notice Collect what a terminal challenge owes you for funding its
    ///         counter-bond: your stake back, plus your pro-rata slice of
    ///         the forfeited challenger bond when the challenge FAILED.
    /// @dev    PULL, NOT PUSH: resolution stores the total to split and
    ///         each claimant computes its own share on the way out, so the
    ///         payout is O(1) per claimant regardless of contributor-list
    ///         length, and one reverting or blocklisted recipient can
    ///         never brick a resolution or strand the frozen coverage.
    ///
    ///         Rounding: shares are floor-divided independently, so up to
    ///         `contributors - 1` wei of a failed challenge's payout is
    ///         never claimable. Bounded at wei scale and left in the
    ///         contract, still covered by `unclaimedWood`.
    function claimContribution(uint256 challengeId) external returns (uint256 amount);

    /// @notice What `claimContribution` would pay `contributor` right now
    ///         — the stake plus, on the failed path, its slice of the
    ///         forfeit. Zero once claimed, and zero on the guilty-ruling
    ///         path.
    function claimableContribution(uint256 challengeId, address contributor) external view returns (uint256);

    /// @notice WOOD owed to counter-bond funders of terminal challenges and
    ///         not yet collected.
    /// @dev    `bondedWood` keeps its meaning — WOOD held for LIVE
    ///         challenges — so the invariant is `wood.balanceOf(game) >=
    ///         bondedWood + unclaimedWood`. Splitting the two keeps "no
    ///         live challenge implies `bondedWood == 0`" true, which
    ///         several tests and the fuzz invariant rely on.
    function unclaimedWood() external view returns (uint256);
    /// @notice The MOST RECENTLY FILED challenge against a proposal if it
    ///         is still live (`Filed`/`Disputed`), or zero.
    /// @dev    Filings are per-challenger, so this is no longer "the" live
    ///         challenge: an older one may still be live when the newest
    ///         has gone terminal. Ask `liveChallengeCountOf` whether ANY is
    ///         live, and `liveChallengeOfBy` for a specific challenger's
    ///         slot.
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
    /// @notice The slice of a FAILED challenge's forfeited bond that is
    ///         destroyed instead of being paid to the counter-bond's
    ///         funders, in bps. It exists because the accused side can be
    ///         the challenger: one operator can file against its own
    ///         proposal and fund the whole counter-bond pool, and a
    ///         forfeit paid entirely to contributors then returns to the
    ///         address that posted it, making the whole round trip free.
    ///         Burning is the only sink with no beneficiary the attacker
    ///         can reach — see `ChallengeGame.BURN_ADDRESS`.
    function forfeitBurnBps() external view returns (uint256);
    function autoSlashDelay() external view returns (uint256);
    function disputeTimeout() external view returns (uint256);
    /// @notice Share of a SUCCESSFUL challenger's bond burned on settle, in
    ///         bps. Applies to the settle path only: the fail path already
    ///         forfeits the whole bond to the accused.
    function settleBurnBps() external view returns (uint256);
    /// @notice Slice of a verdict slash paid to the challenger that caused
    ///         it. Pinned per challenge at filing.
    /// @dev    ESCALATED CONVICTIONS ONLY, and never while a dispute is
    ///         open. `_settle` is the sole payer and it is reached only by
    ///         the silence timeout or a `Guilty` ruling; of those two it
    ///         forwards a non-zero rate ONLY for the ruling. A `NotGuilty`
    ///         ruling, an `Inconclusive` unwind and the dispute timeout all
    ///         route through `_fail`/`_refundAll`, which slash nothing and
    ///         so pay nothing.
    function prosecutorFeeBps() external view returns (uint256);
    /// @notice The ROUND-4-AND-BEYOND steady-state share of the
    ///         challenger's bond burned on an `Inconclusive` unwind, in
    ///         bps. Rounds 1-3 follow a fixed, lower schedule (round 1
    ///         free, rising through fixed 5%/10% steps) before reaching
    ///         this ceiling — see `inconclusiveRounds` and
    ///         `ChallengeGame._inconclusiveBurnBpsForRound` for the full
    ///         schedule.
    /// @dev    Every OTHER terminal path prices the freeze a filing buys —
    ///         the silence settle burns `settleBurnBps`, a failed
    ///         challenge forfeits the whole bond, an escalated guilty
    ///         verdict charges nothing because the filing was right.
    ///         `Inconclusive` escalates with the round count instead of a
    ///         flat rate, since a flat percentage cannot distinguish an
    ///         honest one-shot filer from a grinder. Deliberately kept
    ///         BELOW the LIVE `settleBurnBps`, never above it — a
    ///         non-verdict recovered nothing, so it must never cost the
    ///         challenger more than a verdict that actually recovered
    ///         value. Enforced by
    ///         `setInconclusiveBurnBps`/`setSettleBurnBps` each
    ///         cross-checking the OTHER's current value — sharing a
    ///         ceiling bounds both rates' maximums identically but says
    ///         nothing about where either live rate actually sits, which a
    ///         ceiling-only check on each setter would leave open. That
    ///         cross-check covers ONLY this round-4+ tier — rounds 2 and 3
    ///         are fixed constants outside the setter pair, additionally
    ///         clamped live at the point the rate is computed (see
    ///         `_inconclusiveBurnBpsForRound`).
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
    /// @notice The owner's only lever that gates NEW filings: true refuses
    ///         `file` alone. dispute/resolve/rule/claims always run
    ///         unaffected by this flag. It is not a claim that a live
    ///         challenge is fully insulated from the owner — see
    ///         `ChallengeGame.filingsPaused` for what actually is (the
    ///         `*AtFiling` economic pins) and what deliberately is not
    ///         (`court`, read live by `rule`).
    function filingsPaused() external view returns (bool);
    /// @notice Per-proposal deadline for NEW filings, raised (never
    ///         lowered) whenever a challenge on that proposal unwinds
    ///         `Inconclusive`. `file` gates on the LARGER of this value and
    ///         `executedAt + challengeWindow` — zero is not a sentinel
    ///         here, it is simply what an untouched key contributes to
    ///         that max.
    /// @dev    WITHOUT A RAISED FLOOR, `INCONCLUSIVE` IS A PERMANENT
    ///         ACQUITTAL. Reaching it takes anywhere from `voteWindow` (the
    ///         accused's counter-bond pool may complete the instant it is
    ///         filed) up to `autoSlashDelay + voteWindow` (the accused
    ///         stalls completion to the edge of `autoSlashDelay` first) —
    ///         roughly 5 to 12 days at the defaults, and the accused
    ///         chooses where in that span it lands. A challenge filed more
    ///         than ~2 days after execution could, in the worst case,
    ///         never be re-filed, and stalling lets the accused force
    ///         exactly that worst case. Raising the floor on every unwind
    ///         turns the stall into a delay instead of an acquittal.
    function challengeableUntil(bytes32 reviewKey) external view returns (uint256);
    /// @notice How many times this proposal has gone `Inconclusive` since
    ///         the last time the re-challenge window lapsed with nobody
    ///         refiling inside it. Drives the escalating Inconclusive-burn
    ///         schedule (`ChallengeGame._inconclusiveBurnBpsForRound`) —
    ///         round 1 (count 0) is free, and the rate climbs from there.
    /// @dev    KEYED ON THE PROPOSAL ALONE, not `(reviewKey, challenger)` —
    ///         the same tradeoff `_convicted` and `challengeableUntil`
    ///         already make: a per-challenger counter would let a sybil
    ///         reset the escalation for free by switching addresses
    ///         between rounds. RESET, not merely capped, whenever
    ///         `challengeableUntil` has naturally lapsed — see
    ///         `ChallengeGame.file`'s own comment for why that specific
    ///         condition is what "the grind stopped" means here, as
    ///         opposed to a simpler elapsed-time clock.
    function inconclusiveRounds(bytes32 reviewKey) external view returns (uint256);

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
    /// @notice Set the burned slice of a failed challenge's forfeit.
    ///         Bounded by a ceiling well below the whole bond, and ZERO IS
    ///         PERMITTED — unlike `setChallengerBondBps`, where zero would
    ///         make the freeze free. Zero here only restores paying the
    ///         entire forfeit to the funders and re-opens the
    ///         self-challenge round trip; it is a governance off-switch,
    ///         not a broken state.
    function setForfeitBurnBps(uint256 newBps) external;
    function setAutoSlashDelay(uint256 newDelay) external;
    function setDisputeTimeout(uint256 newTimeout) external;
    /// @notice Set the settle-path burn. ALSO REJECTS dropping below the
    ///         LIVE `inconclusiveBurnBps`: the two rates share a ceiling,
    ///         but a ceiling-only check on this setter would let it fall
    ///         below an unchanged `inconclusiveBurnBps`, inverting the
    ///         ordering that burn exists to guarantee.
    /// @dev    OPERATOR NOTE: a call that would have succeeded before the
    ///         Inconclusive burn existed can fail today purely because
    ///         `inconclusiveBurnBps` (the escalating schedule's round-4+
    ///         tier) has not been lowered first. This setter does NOT
    ///         guard the escalating schedule's fixed round-2/3 steps
    ///         (500/1,000 bps) — those are clamped live at the point
    ///         `file` computes the pinned rate
    ///         (`ChallengeGame._inconclusiveBurnBpsForRound`), not here, so
    ///         a low `settleBurnBps` never blocks filing itself.
    function setSettleBurnBps(uint256 newBps) external;
    function setFilingsPaused(bool paused) external;
    function setProsecutorFeeBps(uint256 newBps) external;
    /// @notice Set the round-4-and-beyond steady state of the escalating
    ///         Inconclusive-burn schedule. Bounded by a ceiling at or below
    ///         `settleBurnBps`'s own, AND rejects rising above the LIVE
    ///         `settleBurnBps` itself — a non-verdict must never be
    ///         allowed to cost more than a verdict that actually recovered
    ///         value, and the shared ceiling alone does not guarantee that
    ///         ordering against the live rates. Zero is legal and floors
    ///         the round-4+ tier to nothing (rounds 1-3 are unaffected —
    ///         they are fixed constants, not derived from this variable).
    function setInconclusiveBurnBps(uint256 newBps) external;
}
