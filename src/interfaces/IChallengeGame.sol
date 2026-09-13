// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IChallengeGame
/// @notice Bonded challenges against executed proposals — the trigger above the
///         slash rails. Slash proceeds are BURNED, not compensated: the protocol
///         punishes the approver, it does not reimburse the vault.
///
///         A challenge is an ASSERTION with an evidence pointer, never an
///         on-chain proof. No predicate is verified on-chain — some need a
///         venue-specific fair-value model or a funding-graph analysis a chain
///         cannot do, and enforcing some in code while judge-enforcing the rest
///         would run two security models in one mechanism.
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

    /// @notice Challenge lifecycle. There is deliberately no `Proven` state: a
    ///         challenge is live (`Filed`) or terminal (`Failed`/`Settled`).
    enum Status {
        None,
        Filed,
        Failed,
        Settled
    }

    /// @param frozenCoverageUsd The coverage this challenge pinned, in USD-18,
    ///        snapshotted at filing; the bond was sized against it. It is NOT what
    ///        the eventual verdict is worth — the verdict is punitive and takes
    ///        the severity ceiling of each convicted approver's live bond. Written
    ///        once and never read on-chain: it exists for indexers and for
    ///        auditing the bond arithmetic.
    /// @param adapterTarget The adapter the challenger accuses, demoted on a
    ///        passed challenge. Zero means the filing accuses no adapter.
    /// @param adapterSelector The accused adapter's selector.
    /// @param executedAt The challenged proposal's execution timestamp, pinned at
    ///        filing. It is the slash basis the verdict is sized against, and
    ///        pinning it keeps the conviction recoverable: any instant at or after
    ///        the accusation is one the accused could move its own checkpoint past.
    /// @param vault The challenged proposal's vault, likewise pinned at filing
    ///        rather than re-read from a mutable governor at resolve time.
    /// @param voteWindowAtFiling The decision window this challenge actually
    ///        received. Reading the live parameter would let the owner
    ///        retroactively close a window the accused is still inside.
    /// @param settleBurnBpsAtFiling The settle-path burn rate in force at filing.
    ///        Read live, the owner could raise it afterwards and take up to half
    ///        the refund of a challenge that turned out correct — the challenger
    ///        relied on the rate when it filed and cannot withdraw.
    /// @param forfeitBurnBpsAtFiling The fail-path burn rate at filing, pinned for
    ///        the symmetric reason: it scales what a challenger that loses gets
    ///        back.
    /// @param prosecutorFeeBpsAtFiling The prosecutor-fee rate at filing, pinned
    ///        for the same reason. Forwarded to `IProposerBondEscrow.forfeitBond`
    ///        on EVERY conviction — it is a slice of the proposer's forfeited
    ///        bond, not of the slash, which pays no one.
    struct Challenge {
        address governor;
        uint256 proposalId;
        address challenger;
        uint256 bondWood;
        Predicate predicate;
        Status status;
        uint256 filedAt;
        uint256 frozenCoverageUsd;
        address adapterTarget;
        bytes4 adapterSelector;
        uint256 executedAt;
        address vault;
        uint256 voteWindowAtFiling;
        uint256 settleBurnBpsAtFiling;
        uint256 forfeitBurnBpsAtFiling;
        uint256 prosecutorFeeBpsAtFiling;
        /// @dev The escrow holding this proposal's PROPOSER bond, pinned at filing
        ///      from `StrategyProposal.proposerBondEscrow` — the same binding
        ///      `reclaimProposerBond` releases against, and where `_settle`
        ///      confiscates it on a conviction. Pinned rather than re-read for the
        ///      same reason as `vault` and `executedAt`: a verdict can land a full
        ///      `voteWindow` after filing. Zero when the proposal locked no
        ///      bond, which the settle path treats as nothing-to-forfeit rather
        ///      than an error. Appended for tuple-position stability.
        address proposerBondEscrow;
        /// @dev Stake eligible to vote on this challenge: the guardian total at
        ///      filing less the accused cohort's own weight.
        uint256 votableStakeAtFiling;
        /// @dev The quorum in force at filing, pinned like every other rate.
        uint256 quorumBpsAtFiling;
        /// @dev Running convict-side weight.
        uint256 convictWeight;
    }

    // ── Errors ──
    error NotExecuted();
    error WindowClosed();
    error AlreadyChallenged();
    /// @dev The proposal's one liability has already been collected by a settled
    ///      challenge, so no further filing against it can reach a verdict.
    ///      Refused at the door because such a filing still FREEZES the coverage,
    ///      and the freeze is what bars an accused approver from
    ///      `claimUnstakeGuardian`: it would buy another `voteWindow` of lock
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
    ///         else — resolution is unaffected by this flag.
    error FilingsPaused();
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
    ///         the un-wedge for a mis-wired slasher, `setExposureLedger` as the
    ///         only way to move the freeze rail — have no permissionless
    ///         equivalent.
    error RenounceDisabled();
    /// @dev One vote per guardian per challenge; there is no un-vote and no
    ///      re-vote, which is what lets a reached quorum settle on the spot.
    error AlreadyVoted();
    /// @dev The voter is one of the approvers this challenge accuses. Its
    ///      weight is out of the denominator, so it cannot be in the numerator.
    error AccusedCannotVote();
    /// @dev The voter is not an active guardian, or carried no staked WOOD at
    ///      the filing instant.
    error NoVotableStake();

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
    /// @param slashedWood What was actually BURNED. Gross and burned are the same
    ///        number on every path: `slashVerdict` takes no payee and burns
    ///        everything it collects. The prosecutor's fee is a slice of the
    ///        PROPOSER's forfeited bond instead and never touches this figure.
    event ChallengeSettled(uint256 indexed challengeId, uint256 slashedWood);
    /// @dev The slice of the CHALLENGER'S BOND burned on a settle
    ///      (`settleBurnBps`) — a correct filing is cheap, not free, because it
    ///      froze a cohort's coverage for the price of gas. Distinct from
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
    /// @param forfeitedWood The GROSS bond the challenger had staked on the
    ///        accusation it lost.
    /// @param burnedWood The slice of that bond destroyed; the challenger keeps
    ///        `forfeitedWood - burnedWood`. The two are reported separately
    ///        because they answer different questions.
    event ChallengeFailed(uint256 indexed challengeId, uint256 forfeitedWood, uint256 burnedWood);
    event ExposureLedgerSet(address indexed oldLedger, address indexed newLedger);
    event TierRegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event StakedWoodSet(address indexed oldStakedWood, address indexed newStakedWood);
    event ChallengeWindowSet(uint256 oldWindow, uint256 newWindow);
    event ChallengerBondBpsSet(uint256 oldBps, uint256 newBps);
    event ForfeitBurnBpsSet(uint256 oldBps, uint256 newBps);
    event VoteWindowSet(uint256 oldWindow, uint256 newWindow);
    event SettleBurnBpsSet(uint256 oldBps, uint256 newBps);
    event FilingsPausedSet(bool oldPaused, bool newPaused);
    event ProsecutorFeeBpsSet(uint256 oldBps, uint256 newBps);
    /// @dev `weight` is the voter's staked WOOD at `filedAt`, the same basis
    ///      the challenge's votable stake was measured on.
    event ChallengeVoteCast(uint256 indexed challengeId, address indexed voter, bool convict, uint256 weight);
    event ChallengeQuorumBpsSet(uint256 oldBps, uint256 newBps);

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

    // Deciding
    function voteOnChallenge(uint256 challengeId, bool convict) external;

    // Resolution
    /// @notice Permissionless resolution once the decision window has closed.
    ///         Reverts otherwise.
    function resolve(uint256 challengeId) external;

    // ── Views ──
    function challengeOf(uint256 challengeId) external view returns (Challenge memory);
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
    /// @notice The slice of a FAILED challenge's bond destroyed rather than
    ///         returned, in bps. It exists because the accused side can be the
    ///         challenger: one operator can file against its own proposal, and
    ///         anything returned in full is a round trip it pays nothing for.
    ///         Burning is the only sink with no beneficiary the attacker can
    ///         reach.
    function forfeitBurnBps() external view returns (uint256);
    function voteWindow() external view returns (uint256);
    function challengeQuorumBps() external view returns (uint256);
    function challengeTallyOf(uint256 challengeId)
        external
        view
        returns (uint256 convictWeight, uint256 votableStake, uint256 quorumBps);
    function hasVotedOn(uint256 challengeId, address voter) external view returns (bool);
    /// @notice Share of a SUCCESSFUL challenger's bond burned on settle, in bps.
    function settleBurnBps() external view returns (uint256);
    /// @notice Slice of the convicted proposer's forfeited bond paid to the
    ///         challenger that caused the conviction. Pinned per challenge at
    ///         filing.
    /// @dev    Paid on convictions only. `_settle` is the sole payer; `_fail`
    ///         slashes nothing and so pays nothing.
    function prosecutorFeeBps() external view returns (uint256);
    /// @notice WOOD the game holds on behalf of live (`Filed`) challenges. The
    ///         invariant is `wood.balanceOf(game) >= bondedWood`; the game pays
    ///         out nothing but bonds, so the two are equal except for WOOD
    ///         donated here by mistake.
    function bondedWood() external view returns (uint256);
    /// @notice The owner's only lever that gates NEW filings: true refuses `file`
    ///         alone; resolution always runs unaffected. It is not a claim that a
    ///         live challenge is fully insulated from the owner — see
    ///         `ChallengeGame.filingsPaused` for what actually is: the
    ///         `*AtFiling` economic pins.
    function filingsPaused() external view returns (bool);
    /// @notice Per-proposal deadline for NEW filings, raised (never lowered)
    ///         whenever a challenge on that proposal fails without a verdict.
    ///         `file` gates on the LARGER of this value and
    ///         `executedAt + strategyDuration + challengeWindow` — zero is not a
    ///         sentinel, it is simply what an untouched key contributes.
    /// @dev    THE `+ strategyDuration` TERM IS LOAD-BEARING. `settleProposal`
    ///         moves money at `executedAt + strategyDuration`, not at
    ///         `executedAt`, so a deadline of `executedAt + challengeWindow` alone
    ///         could close BEFORE the settlement calls guardians underwrote ever
    ///         ran — making a drain permanently unchallengeable.
    /// @dev    WITHOUT A RAISED FLOOR, A FAILED CHALLENGE IS A PERMANENT
    ///         ACQUITTAL. A whole `voteWindow` elapses before one can fail, so a
    ///         challenge filed a couple of days after execution could in the
    ///         worst case never be re-filed. Raising the floor on every failure
    ///         turns the stall into a delay.
    function challengeableUntil(bytes32 reviewKey) external view returns (uint256);

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
    function setExposureLedger(address ledger) external;
    function setTierRegistry(address registry) external;
    function setStakedWood(address stakedWood_) external;
    function setChallengeWindow(uint256 newWindow) external;
    function setChallengerBondBps(uint256 newBps) external;
    /// @notice Set the burned slice of a failed challenge's bond. Bounded by a
    ///         ceiling well below the whole bond, and ZERO IS PERMITTED — unlike
    ///         `setChallengerBondBps`, where zero would make the freeze free.
    ///         Zero here only restores returning the bond whole and re-opens the
    ///         self-challenge round trip.
    function setForfeitBurnBps(uint256 newBps) external;
    function setVoteWindow(uint256 newWindow) external;
    function setChallengeQuorumBps(uint256 newBps) external;
    /// @notice Set the settle-path burn.
    function setSettleBurnBps(uint256 newBps) external;
    function setFilingsPaused(bool paused) external;
    function setProsecutorFeeBps(uint256 newBps) external;
}
