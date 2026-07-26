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
    ///         (`Failed`/`Settled`).
    enum Status {
        None,
        Filed,
        Disputed,
        Failed,
        Settled
    }

    /// @param frozenCoverageUsd The coverage this challenge pinned, in USD-18,
    ///        snapshotted at filing. The bond was sized against it, and it is
    ///        what the eventual verdict is worth.
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
    /// @param epoch The COVER-RELATIVE coverage epoch the filing cites (spec
    ///        §3.4a, Plan F decision D8). READ ONLY FOR `DrawdownBreach`, and
    ///        only when non-zero: relative epoch 0 is the watch the cover opened
    ///        on, whose coverers are the ledger's original approvers, so zero
    ///        takes the identical path every pre-Plan-F challenge took. It is
    ///        CARRIED ON THE CHALLENGE rather than re-supplied per call because
    ///        `dispute` and `_settle` must resolve the SAME accused set the
    ///        filing did — standing to defend and liability to be slashed are
    ///        two views of one set, and re-deriving either from a caller
    ///        argument is how they come apart.
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
        uint256 epoch;
    }

    // ── Errors ──
    error NotExecuted();
    error WindowClosed();
    error AlreadyChallenged();
    error NothingToFreeze();
    error WrongStatus();
    error DelayNotElapsed();
    error NotAccusedApprover();
    error ZeroAddress();
    error InvalidParameter();
    /// @notice A counter-bond contribution that would move nothing — a zero
    ///         `amountWood`. The pool being already full cannot reach this: the
    ///         completing contribution flips the status to `Disputed`, so a later
    ///         caller is rejected by `WrongStatus` first.
    error NothingToContribute();
    /// @notice `rule` called by anything other than the wired court (§3.5).
    /// @dev    Also what an UNWIRED game reverts with, since `court` is then the
    ///         zero address and no caller can match it — Plan D's timeout stays
    ///         the only way out of `Disputed`.
    error NotCourt();
    /// @notice A `DrawdownBreach` filing cited a COVER-RELATIVE epoch (§3.4a)
    ///         that NOBODY covered — either no guardian renewed it, or no
    ///         `coverageEpochs` registry is wired to answer at all.
    /// @dev    THE EMPTY SET IS NOT AN ACQUITTAL, so it must not be allowed to
    ///         become a challenge. An empty accused set slashes nobody, returns
    ///         the challenger's bond through the defensive no-contributor
    ///         branch, and leaves a terminal challenge on-chain that reads
    ///         exactly like one that ran its course — a phantom challenge, worse
    ///         than none, because it launders "nobody was covering" into "the
    ///         accusation was answered". `CoverageEpochs.coverersOf` returns
    ///         empty for an unrenewed epoch DELIBERATELY (an unrenewed epoch is
    ///         a wind-down condition, not a liability one), and this error is
    ///         what stops that honest answer becoming a silent no-op here.
    /// @dev    Declared on the GAME, not on `ICoverageEpochs`: the registry
    ///         reporting an empty set is not an error at all, it is a fact. Only
    ///         a filing that tried to build an accusation out of it is.
    error NoCoverage();

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
    /// @dev One per contributing approver, so the payer set — and therefore the
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
    event ChallengeSettled(uint256 indexed challengeId, uint256 slashedWood, uint256 caseId);
    /// @param forfeitedWood What the CHALLENGER lost — its whole bond on the
    ///        normal failure path, and zero on the defensive no-contributor
    ///        branch where the bond is handed back instead.
    /// @param burnedWood The slice of that forfeit destroyed rather than paid
    ///        out (`forfeitBurnBps`). The contributors therefore share
    ///        `forfeitedWood - burnedWood`; the two are reported separately
    ///        because they answer different questions — what filing cost, and
    ///        what the defence actually collected.
    event ChallengeFailed(uint256 indexed challengeId, uint256 forfeitedWood, uint256 burnedWood);
    /// @dev Emitted BEFORE the settle/fail it causes, so an indexer reading the
    ///      log in order sees the verdict and then the accounting it produced.
    event ChallengeRuled(uint256 indexed challengeId, bool guilty);
    event CourtSet(address indexed oldCourt, address indexed newCourt);
    event CoverageEpochsSet(address indexed oldRegistry, address indexed newRegistry);
    event ExposureLedgerSet(address indexed oldLedger, address indexed newLedger);
    event TierRegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event StakedWoodSet(address indexed oldStakedWood, address indexed newStakedWood);
    event ChallengeWindowSet(uint256 oldWindow, uint256 newWindow);
    event ChallengerBondBpsSet(uint256 oldBps, uint256 newBps);
    event ForfeitBurnBpsSet(uint256 oldBps, uint256 newBps);
    event AutoSlashDelaySet(uint256 oldDelay, uint256 newDelay);
    event DisputeTimeoutSet(uint256 oldTimeout, uint256 newTimeout);

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
    /// @param epoch           The COVER-RELATIVE coverage epoch the breach
    ///                        SURFACED on (spec §3.4a, D8) — cite it with
    ///                        `CoverageEpochs.relativeEpochNow`, which exists so
    ///                        callers hand over the number the contract expects
    ///                        rather than an absolute index off the ledger's
    ///                        global grid. READ ONLY FOR `DrawdownBreach`:
    ///                        predicate 5 is the only one that can surface on a
    ///                        LATER watch than the approval it came from, since
    ///                        a drawdown breaches at a checkpoint months after
    ///                        execution while an unauthorized venue was
    ///                        unauthorized the moment it executed. Pass zero for
    ///                        every other predicate, and for a breach on the
    ///                        cover's own opening watch; zero takes the exact
    ///                        pre-Plan-F path. A non-zero epoch nobody covered
    ///                        reverts `NoCoverage` rather than accusing nobody.
    /// @param evidenceURI     Off-chain pointer to the evidence backing the
    ///                        assertion.
    /// @return challengeId The new challenge's id.
    /// @dev    THE BOND AND THE FREEZE STAY PROPOSAL-SCOPED even for an epoch
    ///         citation: both are read off `ExposureLedger` for
    ///         `(governor, proposalId)`, because the ledger is what a freeze can
    ///         actually pin and a renewal books its exposure against that same
    ///         proposal. Only the ACCUSED SET is epoch-scoped.
    function file(
        address governor,
        uint256 proposalId,
        Predicate predicate,
        uint256 epoch,
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

    /// @notice The court's verdict on a DISPUTED challenge (spec §3.5, Plan E).
    ///         Callable only by `court`, and only from `Disputed` — a `Filed`
    ///         challenge is still inside its own auto-slash clock and has not
    ///         been escalated to anyone.
    /// @dev    THE COURT SUPPLIES ONLY THE GUILTY/NOT-GUILTY BIT and can vary
    ///         nothing else. `guilty` takes the identical path an UNDISPUTED
    ///         challenge takes — slash at sWOOD's `maxSlashBps` with no severity
    ///         ramp (§3.5 "ground truth established", D7), the named adapter
    ///         demoted, the challenger's bond returned — and `!guilty` the
    ///         identical path the timeout takes. There is deliberately no
    ///         severity argument: a court that could dial the slash would be
    ///         negotiating with the accused rather than ruling on them.
    /// @dev    A RULING BEATS THE TIMEOUT. Both outcomes are terminal, and
    ///         `resolve` only acts on `Filed`/`Disputed`, so once the court has
    ///         ruled the clock can no longer overwrite the verdict — which is
    ///         the whole point: it is what stops a guilty approver disputing and
    ///         running out `disputeTimeout`.
    function rule(uint256 challengeId, bool guilty) external;

    // ── Views ──
    function challengeOf(uint256 challengeId) external view returns (Challenge memory);
    /// @notice WHO A LIVE CHALLENGE WOULD SLASH — the set `_settle` hands to
    ///         sWOOD, and the set `dispute` grants standing from. Resolved from
    ///         the challenge's own stored predicate and epoch, so a guardian
    ///         checking whether it is at risk cannot get the arguments wrong.
    /// @dev    NEVER REVERTS on an empty set — it reports it. `file` is where an
    ///         empty citation is refused; every later reader must tolerate one,
    ///         or unwiring `coverageEpochs` mid-challenge would leave live
    ///         filings unable to settle OR be disputed. For a challenge that
    ///         exists this is empty only after such an owner action:
    ///         `CoverageEpochs._coverers` is append-only, so a watch under
    ///         challenge can gain members but never lose them.
    function accusedOf(uint256 challengeId) external view returns (address[] memory);
    /// @notice The same derivation BEFORE anything is filed: who a challenge
    ///         citing this predicate and epoch would accuse.
    /// @dev    Exists so the epoch-0 definition is auditable from outside this
    ///         contract. `CoverageEpochs.coverersOf(.., 0)` must return exactly
    ///         what this returns for a non-epoch-scoped citation — the two are
    ///         separate copies of one filter over `ExposureLedger.approversOf`,
    ///         and a mirror nobody can read is a mirror nobody can check.
    function accusedFor(address governor, uint256 proposalId, Predicate predicate, uint256 epoch)
        external
        view
        returns (address[] memory);
    /// @notice Everyone that has put WOOD into a challenge's counter-bond pool,
    ///         in first-contribution order and without duplicates. This is the
    ///         payout set on the failure path — a failed challenge's forfeited
    ///         bond splits pro-rata across THIS list, not across the accused set.
    function counterBondContributors(uint256 challengeId) external view returns (address[] memory);
    /// @notice What one address has contributed to a challenge's counter-bond
    ///         pool. Retained after resolution, so the split a terminal challenge
    ///         paid out stays auditable on-chain.
    function counterBondContributionOf(uint256 challengeId, address contributor) external view returns (uint256);
    /// @notice The id of the LIVE (`Filed`/`Disputed`) challenge against a
    ///         proposal, or zero when none is live.
    function liveChallengeOf(address governor, uint256 proposalId) external view returns (uint256);
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
    /// @notice WOOD the game holds on behalf of live (`Filed`/`Disputed`)
    ///         challenges. The §4 invariant is `wood.balanceOf(game) >=
    ///         bondedWood`; the game pays out nothing but bonds, so the two are
    ///         equal except for WOOD donated here by mistake.
    function bondedWood() external view returns (uint256);
    /// @notice The §3.5 adjudicator allowed to `rule` on disputed challenges, or
    ///         the zero address while none is wired — in which case Plan D's
    ///         behaviour is unchanged and `Disputed` remains terminal-by-timeout.
    function court() external view returns (address);
    /// @notice The §3.4a coverage-epoch registry consulted for predicate-5
    ///         attribution, or the zero address while none is wired — in which
    ///         case a non-zero epoch citation is refused (`NoCoverage`) and
    ///         every other filing behaves exactly as it did before Plan F.
    function coverageEpochs() external view returns (address);

    // ── Owner setters ──
    /// @notice Wire (or unwire) the court. The zero address is DELIBERATELY
    ///         permitted: it is how governance revokes a compromised court and
    ///         falls back to Plan D's fail-safe timeout rather than leaving a
    ///         hostile adjudicator able to force slashes.
    function setCourt(address newCourt) external;
    /// @notice Wire (or unwire) the §3.4a coverage-epoch registry. The zero
    ///         address is permitted for the same reason it is on `setCourt`: it
    ///         is the pre-Plan-F default and the revocation switch. Unwiring can
    ///         only ever REFUSE an epoch citation, never misdirect one, so the
    ///         worst it can do is make a class of challenge unfileable.
    /// @dev    The registry MUST read the same `ExposureLedger` this game does.
    ///         Two ledgers means two different answers to "who covered epoch 0",
    ///         and therefore two accused sets — one of which slashes a guardian
    ///         the other calls innocent.
    function setCoverageEpochs(address registry) external;
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
}
