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
    event ChallengeFailed(uint256 indexed challengeId, uint256 forfeitedWood);
    event ExposureLedgerSet(address indexed oldLedger, address indexed newLedger);
    event TierRegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event ChallengeWindowSet(uint256 oldWindow, uint256 newWindow);
    event ChallengerBondBpsSet(uint256 oldBps, uint256 newBps);

    // ── Filing ──
    /// @notice File a bonded challenge against an executed proposal, freezing
    ///         the coverage its approvers committed.
    /// @param governor     The governor that executed the proposal.
    /// @param proposalId   The executed proposal being accused.
    /// @param predicate    The §3.4 predicate cited — a label for watchtowers
    ///                     and judges; it changes nothing about the path taken.
    /// @param evidenceURI  Off-chain pointer to the evidence backing the
    ///                     assertion.
    /// @return challengeId The new challenge's id.
    function file(address governor, uint256 proposalId, Predicate predicate, string calldata evidenceURI)
        external
        returns (uint256 challengeId);

    // ── Views ──
    function challengeOf(uint256 challengeId) external view returns (Challenge memory);
    /// @notice The id of the LIVE (`Filed`/`Disputed`) challenge against a
    ///         proposal, or zero when none is live.
    function liveChallengeOf(address governor, uint256 proposalId) external view returns (uint256);
    function challengeCount() external view returns (uint256);
    function challengeWindow() external view returns (uint256);
    function challengerBondBps() external view returns (uint256);

    // ── Owner setters ──
    function setExposureLedger(address ledger) external;
    function setTierRegistry(address registry) external;
    function setChallengeWindow(uint256 newWindow) external;
    function setChallengerBondBps(uint256 newBps) external;
}
