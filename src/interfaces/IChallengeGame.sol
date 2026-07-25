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
    event ChallengeFailed(uint256 indexed challengeId, uint256 forfeitedWood);
    /// @dev Emitted BEFORE the settle/fail it causes, so an indexer reading the
    ///      log in order sees the verdict and then the accounting it produced.
    event ChallengeRuled(uint256 indexed challengeId, bool guilty);
    event CourtSet(address indexed oldCourt, address indexed newCourt);
    event ExposureLedgerSet(address indexed oldLedger, address indexed newLedger);
    event TierRegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event StakedWoodSet(address indexed oldStakedWood, address indexed newStakedWood);
    event ChallengeWindowSet(uint256 oldWindow, uint256 newWindow);
    event ChallengerBondBpsSet(uint256 oldBps, uint256 newBps);
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
    function setAutoSlashDelay(uint256 newDelay) external;
    function setDisputeTimeout(uint256 newTimeout) external;
}
