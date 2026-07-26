// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICoverageEpochs
/// @notice Per-strategy coverage epochs for the guardian economic-security
///         model (spec 2026-07-22 §3.4a). A cover pins a baseline NAV when a
///         proposal executes, checkpoints NAV at every epoch boundary, and
///         attaches predicate-5 (drawdown) liability to the guardians covering
///         the epoch in which a breach SURFACES — not to the original
///         approvers, who may have long since exited.
///
/// @dev    NAV SOURCE (D1, and the single most important rule in this design):
///         every NAV read goes through `IPriceRouter.valueStrategy(strategy)`
///         and FAILS CLOSED when `instantOK == false`. Never
///         `SyndicateVault.totalAssets()`. `totalAssets()` is
///         `idle float + liveNav`, and the vault's `_laneState()` leaves
///         `liveNav` at ZERO whenever the router cannot price the strategy —
///         correct for the vault (it falls back to float-only NAV and routes LP
///         flow through the async queue), catastrophic as a checkpoint. A
///         baseline or checkpoint taken from `totalAssets()` during a router
///         outage records a ~100% loss, breaches the drawdown envelope, and
///         exposes honest guardians to a full slash over an oracle hiccup.
///
/// @dev    D7 — the implementation holds no tokens and moves no funds, ever.
///         Wind-down seizes nothing: it only flags a cover so the settlement
///         path that already exists becomes permissionlessly callable.
interface ICoverageEpochs {
    // ── Errors ──

    /// @notice The proposal is not in `Executed` state.
    error NotExecuted();
    /// @notice The proposal carries no strategy (queue-only); there is nothing
    ///         for the price router to value, so there is nothing to cover.
    error NoStrategy();
    /// @notice A cover already exists for this `(governor, proposalId)`.
    error AlreadyOpened();
    /// @notice The price router answered `instantOK == false`. Fail closed (D1)
    ///         rather than record a fabricated loss.
    error NavUnavailable();
    /// @notice No cover exists for this `(governor, proposalId)`.
    error NotOpened();
    /// @notice The epoch boundary being acted on has not been reached yet.
    error BoundaryNotReached();
    /// @notice This epoch already has a recorded NAV checkpoint.
    error AlreadyCheckpointed();
    /// @notice Renewal for the cited epoch closed at its `renewalDeadline`. The
    ///         deadline sits strictly BEFORE the boundary on purpose: it is what
    ///         stops a last-moment exit run on a discontinuous move.
    error RenewalClosed();
    /// @notice This guardian already committed to cover the cited epoch.
    error AlreadyCommitted();
    /// @notice Wind-down refused: the epoch now beginning still has coverage and
    ///         the NAV is not stale past the grace window.
    error StillCovered();
    /// @notice The cover is flagged for wind-down and accepts no new renewal
    ///         commitments.
    error WoundDown();
    /// @notice The cover is already flagged for wind-down.
    error AlreadyWoundDown();
    /// @notice An owner-set parameter is outside its documented bound.
    error InvalidParameter();
    /// @notice A constructor argument was the zero address.
    error ZeroAddress();

    // ── Events ──

    /// @notice A cover opened with the baseline NAV actually observed at that
    ///         moment (D2) and a copy of the ledger's epoch schedule (D3).
    event CoverOpened(
        bytes32 indexed coverKey,
        address indexed governor,
        uint256 indexed proposalId,
        address strategy,
        uint256 baselineNav,
        uint16 maxDrawdownBps
    );
    /// @notice An epoch boundary NAV was recorded. `cumulativeLossBps` is
    ///         measured from BASELINE, never epoch-over-epoch (D4).
    event Checkpointed(bytes32 indexed coverKey, uint256 indexed epoch, uint256 nav, uint256 cumulativeLossBps);
    /// @notice The declared drawdown envelope was exceeded on the cited epoch's
    ///         watch. This is the event watchtowers file predicate 5 against.
    event DrawdownBreached(bytes32 indexed coverKey, uint256 indexed epoch, uint256 lossBps, uint16 maxDrawdownBps);
    /// @notice A guardian committed to cover `epoch`, booking real exposure.
    event RenewalCommitted(bytes32 indexed coverKey, uint256 indexed epoch, address indexed guardian);
    /// @notice Coverage lapsed (`uncovered`) or the NAV stayed unavailable past
    ///         the grace window (`navStale`), so the cover unwinds (D6).
    event WindDownFlagged(bytes32 indexed coverKey, uint256 indexed epoch, bool uncovered, bool navStale);
    /// @notice Owner changed how far ahead of a boundary renewal closes.
    event RenewalLeadTimeSet(uint256 oldLeadTime, uint256 newLeadTime);
    /// @notice Owner changed the window in which a missed checkpoint may be
    ///         retried before the cover is wound down.
    event CheckpointGraceSet(uint256 oldGrace, uint256 newGrace);

    // ── Types ──

    /// @notice Everything a cover knows about one `(governor, proposalId)`.
    /// @dev The epoch schedule is COPIED from the exposure ledger at open (D3)
    ///      rather than re-read on every call: `ExposureLedger.epochLength` is
    ///      immutable today, but reading it once means a future ledger re-point
    ///      cannot retroactively re-slice a live strategy's epochs.
    struct Cover {
        address governor;
        uint256 proposalId;
        address strategy;
        /// @notice When `openCover` ran. D2: the baseline is the NAV observed
        ///         HERE, not at `executedAt` — `openCover` is permissionless and
        ///         may land blocks after execution, and back-dating a number
        ///         nobody read would be unprovable.
        uint64 openedAt;
        uint64 epochLength; // copied from the ledger (D3)
        uint64 epochGenesis; // copied from the ledger (D3)
        uint16 maxDrawdownBps; // snapshot (D5: 10_000 == passive, never breaches)
        uint256 baselineNav; // D2: the NAV actually observed at openCover
        uint64 lastCheckpointedEpoch;
        uint64 breachEpoch;
        bool opened;
        bool windDown;
        bool breached;
    }

    // ── Cover lifecycle ──

    /// @notice Open the cover for an executed strategy proposal and pin its
    ///         baseline NAV. Permissionless — anyone may pay the gas, and the
    ///         guardians' liability does not depend on who did.
    /// @dev Reverts `NotExecuted` unless the proposal is `Executed`,
    ///      `NoStrategy` for a queue-only proposal, `AlreadyOpened` on a second
    ///      call, and `NavUnavailable` when the router cannot price the strategy
    ///      (D1 — a cover MUST refuse to open on an unpriceable baseline, since
    ///      every later drawdown would otherwise be measured against a fiction).
    function openCover(address governor, uint256 proposalId) external;

    // ── Views ──

    /// @notice The full cover record for `(governor, proposalId)`.
    function coverOf(address governor, uint256 proposalId) external view returns (Cover memory);

    /// @notice The drawdown denominator: the NAV observed at `openCover` (D2).
    function baselineNavOf(address governor, uint256 proposalId) external view returns (uint256);

    /// @notice The epoch length copied from the ledger at open (D3).
    function epochLengthOf(address governor, uint256 proposalId) external view returns (uint64);

    /// @notice The epoch genesis copied from the ledger at open (D3).
    function epochGenesisOf(address governor, uint256 proposalId) external view returns (uint64);

    /// @notice The drawdown envelope snapshotted at open. `10_000` is a passive
    ///         mandate, which checkpoints but never breaches (D5).
    function maxDrawdownBpsOf(address governor, uint256 proposalId) external view returns (uint16);

    /// @notice Whether a cover exists for `(governor, proposalId)`.
    function isOpen(address governor, uint256 proposalId) external view returns (bool);

    /// @notice The key covers are stored under, mirroring
    ///         `ChallengeGame._reviewKey` so one proposal has one identity
    ///         across the whole economic-security stack.
    function coverKey(address governor, uint256 proposalId) external pure returns (bytes32);
}
