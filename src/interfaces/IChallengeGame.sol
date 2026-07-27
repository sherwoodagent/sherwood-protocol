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
    ///        snapshotted at filing. The bond was sized against it. It is NOT
    ///        what the eventual verdict is worth (review, minor) — the verdict
    ///        is sized by `slashBpsFor` against live bonds at resolve time, and
    ///        the two diverge whenever a bond moved in between. Written once
    ///        and never read on-chain: it exists for indexers and for auditing
    ///        the bond arithmetic against the filing.
    /// @param disputer The accused approver that posted the counter-bond, or
    ///        the zero address while nobody has contested. Recorded because the
    ///        counter-bond is returned to WHOEVER posted it on the timeout path
    ///        (D5) — it is not the challenger's to forfeit and not the accused
    ///        set's to share.
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
        address disputer;
        address adapterTarget;
        bytes4 adapterSelector;
        uint256 executedAt;
        address vault;
        uint256 autoSlashDelayAtFiling;
        uint256 disputeTimeoutAtFiling;
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
    event ChallengeDisputed(uint256 indexed challengeId, address indexed disputer, uint256 counterBondWood);
    event ChallengeSettled(uint256 indexed challengeId, uint256 slashedWood, uint256 caseId);
    /// @dev The slice of the challenger's bond burned on the settle path, so a
    ///      filing is never free in either direction (review 🟠F4).
    event ChallengerBondBurned(uint256 indexed challengeId, uint256 burnedWood);
    /// @dev A settle that convicted nothing because an earlier challenge on the
    ///      same proposal already did. The approvers' liability is one
    ///      liability; concurrent filings do not multiply it.
    event VerdictAlreadyCollected(uint256 indexed challengeId, address indexed governor, uint256 indexed proposalId);
    event ChallengeFailed(uint256 indexed challengeId, uint256 forfeitedWood);
    event ExposureLedgerSet(address indexed oldLedger, address indexed newLedger);
    event TierRegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event StakedWoodSet(address indexed oldStakedWood, address indexed newStakedWood);
    event ChallengeWindowSet(uint256 oldWindow, uint256 newWindow);
    event ChallengerBondBpsSet(uint256 oldBps, uint256 newBps);
    event AutoSlashDelaySet(uint256 oldDelay, uint256 newDelay);
    event DisputeTimeoutSet(uint256 oldTimeout, uint256 newTimeout);
    event SettleBurnBpsSet(uint256 oldBps, uint256 newBps);

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
    /// @notice Contest a filed challenge by matching the challenger's bond.
    ///         Callable only by an accused approver of the challenged proposal,
    ///         and only strictly before `filedAt + autoSlashDelay` — at that
    ///         instant the silence verdict is already final (D1).
    /// @dev    Stops the auto-slash clock and escalates to the court (§3.5).
    ///         The court does not exist yet, so `resolve` times the escalation
    ///         out in favour of the accused after `disputeTimeout` (D5).
    function dispute(uint256 challengeId) external;

    /// @notice Permissionless resolution. From `Filed` past `autoSlashDelay` the
    ///         silence is the verdict and the accused are slashed into the
    ///         compensation escrow; from `Disputed` past `disputeTimeout` the
    ///         challenge fails to the accused (D5). Reverts otherwise.
    function resolve(uint256 challengeId) external;

    // ── Views ──
    function challengeOf(uint256 challengeId) external view returns (Challenge memory);
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
    function autoSlashDelay() external view returns (uint256);
    function disputeTimeout() external view returns (uint256);
    /// @notice Share of a SUCCESSFUL challenger's bond burned on settle, in bps.
    ///         Applies to the settle path only: the fail path already forfeits
    ///         the whole bond to the accused (§3.4).
    function settleBurnBps() external view returns (uint256);
    /// @notice WOOD the game holds on behalf of live (`Filed`/`Disputed`)
    ///         challenges. The §4 invariant is `wood.balanceOf(game) >=
    ///         bondedWood`; the game pays out nothing but bonds, so the two are
    ///         equal except for WOOD donated here by mistake.
    function bondedWood() external view returns (uint256);

    // ── Owner setters ──
    function setExposureLedger(address ledger) external;
    function setTierRegistry(address registry) external;
    function setStakedWood(address stakedWood_) external;
    function setChallengeWindow(uint256 newWindow) external;
    function setChallengerBondBps(uint256 newBps) external;
    function setAutoSlashDelay(uint256 newDelay) external;
    function setDisputeTimeout(uint256 newTimeout) external;
    function setSettleBurnBps(uint256 newBps) external;
}
