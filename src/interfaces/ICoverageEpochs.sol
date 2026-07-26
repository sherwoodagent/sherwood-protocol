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
    /// @notice An epoch boundary NAV was recorded. `epoch` is COVER-RELATIVE
    ///         (D8); `cumulativeLossBps` is measured from BASELINE, never
    ///         epoch-over-epoch (D4).
    event Checkpointed(bytes32 indexed coverKey, uint256 indexed epoch, uint256 nav, uint256 cumulativeLossBps);
    /// @notice The declared drawdown envelope was exceeded on the cited
    ///         COVER-RELATIVE epoch's watch (D8). This is the event watchtowers
    ///         file predicate 5 against. Emitted at most once per cover: it names
    ///         the epoch the breach SURFACED on, which is who is liable.
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
        /// @notice COVER-RELATIVE epoch indices (D8), not the ledger's absolute
        ///         ones: relative 0 is the watch this cover opened on. The
        ///         boundaries themselves stay on the ledger's global grid, which
        ///         is what keeps a guardian's commitment expiring together with
        ///         its exposure bucket.
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
    /// @dev ALSO SNAPSHOTS THE ORIGINAL APPROVER SET (see `isOriginalApprover`).
    ///      This is the only moment the ledger can still answer "who backed this
    ///      proposal" unambiguously: from here on `commitRenewal` adds renewers
    ///      to the very same approver list, and relative epoch 0's coverers
    ///      could no longer be told apart from a later watch's.
    /// @dev Reverts `NotExecuted` unless the proposal is `Executed`,
    ///      `NoStrategy` for a queue-only proposal, `AlreadyOpened` on a second
    ///      call, and `NavUnavailable` when the router cannot price the strategy
    ///      (D1 — a cover MUST refuse to open on an unpriceable baseline, since
    ///      every later drawdown would otherwise be measured against a fiction).
    function openCover(address governor, uint256 proposalId) external;

    /// @notice Record the boundary NAV of the epoch that has just ended, and
    ///         evaluate the cumulative drawdown against the declared envelope.
    ///         Permissionless, once per epoch, and only once that epoch's
    ///         boundary — the START of the following epoch — has passed.
    /// @dev The epoch is stored COVER-RELATIVE (D8) while the boundary it fires
    ///      on stays on the ledger's global grid.
    /// @dev A cumulative loss STRICTLY greater than `maxDrawdownBps` latches
    ///      `breached`, stamps `breachEpoch` with the relative epoch the breach
    ///      surfaced on, and emits `DrawdownBreached`. A loss exactly AT the
    ///      envelope does not breach: the mandate declared that bound as
    ///      permitted. A passive mandate (`10_000`) never breaches at all (D5).
    /// @dev The recorded epoch is the one whose boundary just closed, NOT a
    ///      cursor position: a checkpoint taken late must not file a NAV read
    ///      today under an epoch nobody observed. Per D4 a missed boundary
    ///      simply stays unrecorded, and cumulative loss keeps measuring from
    ///      the baseline, so a skipped call cannot launder a drawdown.
    /// @dev Reverts `NotOpened` without a cover, `BoundaryNotReached` before
    ///      the first boundary the cover is liable for, `AlreadyCheckpointed`
    ///      on a second call inside the same epoch, and `NavUnavailable` when
    ///      the router answers `instantOK == false` (D1 — refusing to act on an
    ///      unpriceable strategy is the only safe reading; D6 winds such a
    ///      cover down rather than slashing anyone for a fabricated loss).
    function checkpoint(address governor, uint256 proposalId) external;

    // ── Views ──

    /// @notice The NAV recorded for COVER-RELATIVE `epoch` (D8), or zero if that
    ///         boundary was never checkpointed. Zero is "no observation", never
    ///         "worthless".
    function navAt(address governor, uint256 proposalId, uint256 epoch) external view returns (uint256);

    /// @notice Cumulative drawdown from the BASELINE in bps (D4), zero when the
    ///         last checkpoint sat at or above baseline and zero while no
    ///         checkpoint has been taken at all.
    /// @dev Cumulative from baseline, NEVER epoch-over-epoch. Epoch-over-epoch
    ///      looks natural — you just checkpointed, so compare against last time
    ///      — and fails silently: if nobody checkpoints during a crash, the next
    ///      checkpoint re-baselines against the depressed value and a 30%
    ///      drawdown reads as 0%. Since checkpoints are permissionless and
    ///      unpaid, that missed call is the expected case, not an edge case.
    function cumulativeLossBps(address governor, uint256 proposalId) external view returns (uint256);

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

    /// @notice Whether the declared drawdown envelope has been exceeded on some
    ///         checkpoint. Latching: it names the epoch a breach SURFACED on and
    ///         never moves to a later, deeper one.
    /// @dev Always false for a passive mandate (`maxDrawdownBps == 10_000`),
    ///      which checkpoints but carries no predicate-5 liability (D5).
    function breached(address governor, uint256 proposalId) external view returns (bool);

    /// @notice The COVER-RELATIVE epoch (D8) a drawdown breach SURFACED on — the
    ///         index to hand `coverersOf` to learn who answers for it.
    /// @dev Latching: it names the FIRST breaching checkpoint and never moves to
    ///      a later, deeper one. Without the latch, liability would migrate to
    ///      whoever happened to renew after the loss was already visible.
    /// @dev Zero on a cover that has not breached, so read it alongside
    ///      `breached`: relative epoch 0 is a real epoch, not a sentinel.
    function breachEpochOf(address governor, uint256 proposalId) external view returns (uint64);

    /// @notice The COVER-RELATIVE epoch index containing `block.timestamp` (D8).
    ///         Relative epoch 0 is the watch the cover opened on.
    /// @dev Exists so an off-chain watchtower cites the same number the contract
    ///      expects. The ledger's `epochGenesis` is its DEPLOY time, so a cover
    ///      opened in production sits in absolute epoch 40-something while its
    ///      own first watch is 0; every index crossing this interface is the
    ///      relative one. Reverts `NotOpened` without a cover — an unopened
    ///      cover has no schedule to be positioned on.
    function relativeEpochNow(address governor, uint256 proposalId) external view returns (uint256);

    /// @notice Whether a cover exists for `(governor, proposalId)`.
    function isOpen(address governor, uint256 proposalId) external view returns (bool);

    // ── Renewal (spec §3.4a) ──

    /// @notice Commit to cover COVER-RELATIVE `epoch` (D8), booking real
    ///         exposure against the same aggregate cap a fresh approval
    ///         consumes — a guardian without capacity cannot renew, which is the
    ///         point of booking at all.
    /// @dev Accepted only while `block.timestamp < renewalDeadline(epoch)`. See
    ///      that function for what the deadline does and does not buy.
    /// @dev Reverts `NotOpened` without a cover, `WoundDown` on a cover already
    ///      unwinding, `InvalidParameter` for `epoch == 0` (relative epoch 0 is
    ///      the watch the cover opened on — covered by the ORIGINAL approvers
    ///      through the ledger, so a "renewal" of it would create a second,
    ///      contradictory notion of who covered it), `RenewalClosed` past the
    ///      deadline, and `AlreadyCommitted` on a second commit by the same
    ///      guardian. The last guard is load-bearing rather than defensive:
    ///      `ExposureLedger.recordApproval` is idempotent, so without it a
    ///      double commit would silently succeed and push a duplicate coverer.
    function commitRenewal(address governor, uint256 proposalId, uint256 epoch) external;

    /// @notice The instant renewal for COVER-RELATIVE `epoch` closes:
    ///         `globalBoundary(epoch) - renewalLeadTime`, where the boundary is
    ///         the START of that epoch on the ledger's GLOBAL grid (D8).
    ///
    /// @dev DELIBERATELY BEFORE THE BOUNDARY — AND READ WHAT THAT BUYS BEFORE
    ///      SIZING `renewalLeadTime`. This closes the DISCONTINUOUS exit run: a
    ///      hack, depeg or liquidation cascade landing in the hours between the
    ///      deadline and the boundary cannot be front-run out of.
    ///
    ///      It does NOT create information asymmetry about a gradual decline.
    ///      `IPriceRouter.valueStrategy` is a PUBLIC VIEW: a guardian can read
    ///      it continuously and compute what the boundary checkpoint will almost
    ///      certainly say, so a strategy deteriorating visibly across the epoch
    ///      is not hidden by this deadline for one second. That case is handled
    ///      by repricing at renewal (spec §3.10 — a riskier strategy costs more
    ///      to renew, and if nobody will pay it winds down), which IS NOT BUILT
    ///      YET. An implementer who believes sequencing is the whole defence
    ///      will size `renewalLeadTime` wrongly: longer does not buy more
    ///      protection against drift, it only makes guardians commit against
    ///      staler information.
    /// @dev Reverts `NotOpened` without a cover — an unopened cover has no
    ///      schedule, and the boundary arithmetic would underflow on a zero
    ///      genesis.
    function renewalDeadline(address governor, uint256 proposalId, uint256 epoch) external view returns (uint256);

    /// @notice The guardians who committed renewal for COVER-RELATIVE `epoch`.
    /// @dev Renewals ONLY, and therefore NOT the liability view. Relative epoch
    ///      0's coverers are the original approvers held by `ExposureLedger` and
    ///      this list is empty for it; `coverersOf` is the unified claims-made
    ///      answer and the one `ChallengeGame` accuses from.
    function renewalCoverersOf(address governor, uint256 proposalId, uint256 epoch)
        external
        view
        returns (address[] memory);

    // ── Forced wind-down (spec §3.4a, D6/D7) ──

    /// @notice Flag a cover for wind-down. Permissionless: §3.4a's close-out is a
    ///         property of the schedule, not a privilege, and whoever notices the
    ///         lapse first may record it.
    ///
    ///         Two INDEPENDENT triggers, either of which is sufficient:
    ///
    ///         1. UNCOVERED — a boundary passed and nobody committed renewal for
    ///            the epoch now beginning. `coverersOf` deliberately answers with
    ///            an EMPTY set for such an epoch rather than falling back to the
    ///            original approvers: re-accusing guardians for a watch nobody
    ///            stood is precisely the open-ended liability §3.4a ends. So an
    ///            unrenewed epoch is a WIND-DOWN condition, never a liability one,
    ///            and this is where it goes.
    ///         2. STALE (D6) — `checkpointGrace` expired with no successful
    ///            checkpoint of the epoch that just closed. A strategy whose value
    ///            cannot be established cannot be underwritten, and carrying on
    ///            uncovered is exactly the gap §3.4a exists to prevent. The cover
    ///            unwinds; it is never slashed for the fabricated ~100% loss a
    ///            router outage would otherwise report (D1).
    ///
    /// @dev D7 — THIS SEIZES NOTHING. It sets one flag. The implementation holds
    ///      no tokens and moves no funds on this path or any other; the unwinding
    ///      is done by the settlement path that already exists in
    ///      `SyndicateGovernor`, which the flag makes permissionlessly callable
    ///      ahead of `strategyDuration`.
    /// @dev Every index it reads is COVER-RELATIVE (D8) while the boundaries it
    ///      compares against stay on the ledger's global grid.
    /// @dev Reverts `NotOpened` without a cover, `AlreadyWoundDown` on a second
    ///      call, `BoundaryNotReached` while the cover is still inside its own
    ///      relative epoch 0 (no boundary has passed, so nothing can have lapsed),
    ///      and `StillCovered` when the epoch now beginning has coverers and the
    ///      closed epoch was either checkpointed or is still inside its grace.
    function flagWindDown(address governor, uint256 proposalId) external;

    /// @notice Whether this cover has been flagged for wind-down. False for a
    ///         cover that does not exist — there is nothing to unwind.
    /// @dev The single bit `SyndicateGovernor.settleProposal` reads to drop its
    ///      caller/timing gate.
    function windDownRequired(address governor, uint256 proposalId) external view returns (bool);

    /// @notice How long a missed boundary checkpoint may be retried before the
    ///         cover is wound down (D6). Owner-set, default 7 days, bounded
    ///         `(0, epochLength)`.
    function checkpointGrace() external view returns (uint256);

    // ── Claims-made attribution (spec §3.4a) ──

    /// @notice Who is liable for a breach that surfaced in COVER-RELATIVE
    ///         `epoch` (D8) — the single entry point for predicate-5
    ///         attribution.
    ///
    ///         Relative epoch 0 is the watch the cover opened on, so its
    ///         coverers are the proposal's ORIGINAL approvers. Every later epoch
    ///         is covered by whoever committed renewal for it, and by nobody
    ///         else: an original approver who did not renew answers for NOTHING
    ///         surfacing after its own epoch. That bound — one epoch plus the
    ///         challenge window, however long the strategy runs — is the entire
    ///         reason coverage epochs exist.
    ///
    /// @dev An epoch nobody renewed has NO coverers, and the empty array is the
    ///      honest answer rather than a fallback to epoch 0's approvers:
    ///      re-accusing them for an unrenewed watch is exactly the open-ended
    ///      liability this mechanism ends. An unrenewed epoch is a wind-down
    ///      condition, not a liability condition.
    ///
    /// @dev Epoch 0 takes TWO tests, and neither alone is correct.
    ///
    ///      1. A NON-ZERO `committedUsd` on a LIVE read of the ledger's
    ///         approvers, the filter `ChallengeGame._accused` also applies. A
    ///         released approver stays in `ExposureLedger._approversOf` with a
    ///         zeroed share rather than being dropped, so membership of that
    ///         array is NOT coverage — the filter is. Reading it live rather
    ///         than from a frozen array is what makes a released guardian drop
    ///         out of epoch 0 dynamically.
    ///
    ///      2. Membership of the ORIGINAL approver set snapshotted at
    ///         `openCover`. Test 1 alone is no longer "who backed this
    ///         proposal": `commitRenewal` books a renewal through
    ///         `ExposureLedger.recordApproval` under the SAME `proposalId`, so
    ///         the ledger's list grows to include renewers, and a guardian whose
    ///         first commitment was relative epoch 3 would otherwise be returned
    ///         as a coverer of relative epoch 0 — claims-made attribution
    ///         inverted.
    ///
    ///      The conjunction does NOT exclude guardians who renewed. §3.4a lets
    ///      incumbents roll over, and a rolled-over incumbent is liable for its
    ///      own watch AND its renewed one; test 2 asks where a guardian STARTED,
    ///      never whether it continued.
    ///
    /// @dev DIVERGES FROM `ChallengeGame._accused` AT EPOCH 0, and knowingly.
    ///      The game routes only NON-ZERO epochs through this function; its
    ///      epoch-0 branch still reads the ledger directly and so still counts
    ///      renewers as epoch-0 approvers. Closing that requires a change inside
    ///      `ChallengeGame`, not here — a renewer-only guardian remains exposed
    ///      to an epoch-0 predicate-5 filing until it lands.
    function coverersOf(address governor, uint256 proposalId, uint256 epoch) external view returns (address[] memory);

    /// @notice Whether `guardian` was one of the proposal's ORIGINAL approvers,
    ///         as snapshotted when the cover opened.
    /// @dev Half of the epoch-0 answer, exposed because it is otherwise
    ///      unobservable state that decides who a predicate-5 slash reaches. It
    ///      is NOT the same question as `coverersOf(.., 0)` membership: this
    ///      stays true after a release, while the coverer set drops the guardian
    ///      the moment its ledger share zeroes. False for a cover that was never
    ///      opened.
    function isOriginalApprover(address governor, uint256 proposalId, address guardian) external view returns (bool);

    /// @notice Whether `guardian` has already committed to cover `epoch`.
    function hasCommittedRenewal(address governor, uint256 proposalId, uint256 epoch, address guardian)
        external
        view
        returns (bool);

    /// @notice How far ahead of an epoch boundary renewal closes. Owner-set,
    ///         default 3 days, bounded `(0, epochLength / 2]`.
    function renewalLeadTime() external view returns (uint256);

    // ── Owner setters ──

    /// @notice Set how far ahead of a boundary renewal closes.
    /// @dev Bounded `(0, epochLength / 2]`. Zero would put the deadline ON the
    ///      boundary, leaving renewal open until the instant the checkpoint can
    ///      be taken — closing no window at all. Beyond half an epoch, guardians
    ///      commit against badly stale information, which is a different failure
    ///      rather than a stronger defence: see `renewalDeadline`.
    function setRenewalLeadTime(uint256 newLeadTime) external;

    /// @notice Set how long a missed boundary checkpoint may be retried before
    ///         the cover winds down (D6).
    /// @dev Bounded `(0, epochLength)`. Strictly BELOW an epoch: a grace at or
    ///      past `epochLength` means the next boundary always arrives before the
    ///      grace expires, so the stale trigger could never fire and D6 would be
    ///      silently deleted. Zero is refused for the mirror-image reason —
    ///      checkpoints are permissionless and unpaid, so a zero grace would wind
    ///      a healthy cover down over one late transaction.
    function setCheckpointGrace(uint256 newGrace) external;

    /// @notice The key covers are stored under, mirroring
    ///         `ChallengeGame._reviewKey` so one proposal has one identity
    ///         across the whole economic-security stack.
    function coverKey(address governor, uint256 proposalId) external pure returns (bytes32);
}
