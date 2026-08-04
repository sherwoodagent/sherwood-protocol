// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IChallengeGame} from "./IChallengeGame.sol";

/// @title  ITokenCourt
/// @notice Single-layer WOOD-vote adjudication of disputed challenges.
///         HOLDS NO WOOD: no bonds, no custody, pure logic.
interface ITokenCourt {
    /// @notice A case's lifecycle. `None` is the zero value shared with "no
    ///         case referred yet" (`caseOfChallenge == 0`); `Voting` is the
    ///         one open window a case ever gets; `Resolved` is terminal —
    ///         there is no re-opening, mirroring the game's own
    ///         silence-is-final posture.
    enum Phase {
        None,
        Voting,
        Resolved
    }

    /// @notice The court's own record of how ONE VOTER ruled — not a case outcome.
    ///         `voteOf` is its only use; a case's outcome is stored as an
    ///         `IChallengeGame.Verdict` in `Case.verdict`.
    /// @dev    THE ORDERS ARE INVERTED, AND A CAST BETWEEN THE TWO TYPES IS NEVER
    ///         VALID:
    ///
    ///           Ruling  { None = 0,         Guilty = 1,    NotGuilty = 2 }
    ///           Verdict { Inconclusive = 0, NotGuilty = 1, Guilty = 2 }
    ///
    ///         so a numeric conversion between them INVERTS GUILT. Each enum's
    ///         zero value is chosen for ITS OWN default semantics — `Ruling.None`
    ///         is the not-voted sentinel `vote`'s `AlreadyVoted` check reads,
    ///         `Verdict.Inconclusive` is the case answered nothing — so these are
    ///         different meanings, not one meaning spelled twice. `finalize`
    ///         builds a `Verdict` from the TALLY directly and never converts, so
    ///         the divergence is inert. Do NOT harmonise the orders to enable a
    ///         cast: re-ordering either one is how an inert divergence becomes a
    ///         guilt-inverting bug.
    enum Ruling {
        None,
        Guilty,
        NotGuilty
    }

    /// @notice Everything the court knows about one disputed challenge.
    /// @param challengeId The `ChallengeGame` challenge this case adjudicates. One
    ///        case per (game, challenge) — `caseOfChallenge` enforces it.
    /// @param game The `IChallengeGame` this case's verdict is delivered to,
    ///        PINNED at `refer`. `finalize` calls `rule` on this address, never on
    ///        the live `challengeGame`: an owner re-pointing it between `refer`
    ///        and `finalize` would otherwise make `finalize` rule a DIFFERENT
    ///        game's challenge at the same numeric id.
    /// @param ledger The `IExposureLedger` this case's accused set was derived
    ///        from, PINNED at `refer`. That pointer is read exactly once and
    ///        handed to `_recordAccused`, so the accused set, `accusedWeight` and
    ///        this field can never come from three different ledgers. RESIDUAL
    ///        WINDOW: an owner re-point strictly between `file` and `refer` is
    ///        absorbed BY the pin rather than blocked by it.
    /// @param snapshotTs `executedAt - 1`, written ONCE in `refer` and never
    ///        re-derived, so the owner cannot move a live case's electorate.
    /// @param referredAt The instant `refer` opened this case — the anchor the
    ///        vote window counts from.
    /// @param voteWindowAtReferral The court's `voteWindow` PINNED at referral, so
    ///        the owner cannot retroactively shrink or stretch a window a party is
    ///        already relying on.
    /// @param accusedWeight The raw `getPastStake` sum of the accused set at
    ///        `snapshotTs`, the same basis `getPastTotalVotes` sums, so the
    ///        participation floor's subtraction never compares two different
    ///        measures of the same WOOD.
    /// @param guiltyVotes Aged vote weight cast for `Guilty`.
    /// @param notGuiltyVotes Aged vote weight cast for `NotGuilty`.
    /// @param phase The case's lifecycle position.
    /// @param verdict The three-valued outcome `finalize` handed to `rule`. Zero
    ///        (`Inconclusive`) until resolved, matching `Verdict`'s own
    ///        harmless-default design.
    /// @param finalizedAt The instant `finalize` closed this case, or zero.
    /// @param challenger The challenge's own challenger, PINNED at `refer` from
    ///        the `Challenge` struct already read there. `vote` bars this address
    ///        like the accused set: a `Guilty` verdict pays the challenger, so an
    ///        unbarred challenger voting on its own filing is a self-dealing
    ///        conviction. APPENDED, not inserted, to keep earlier field positions.
    /// @param accusedWeightAtLookback The raw `getPastStake` sum of the SAME
    ///        accused set, read at `snapshotTs - FLOOR_LOOKBACK` — the instant
    ///        `_participationFloor`'s `earlier` term is measured at. Recorded so
    ///        the lookback branch can subtract the accused cohort from `earlier`
    ///        at the instant `earlier` itself is measured, rather than leaving one
    ///        term un-reduced. APPENDED for the same reason.
    struct Case {
        uint256 challengeId;
        address game; // pinned IChallengeGame this case rules on, written once in refer
        address ledger; // pinned IExposureLedger the accused set was derived from, written once in refer
        uint256 snapshotTs; // executedAt - 1, written once in refer
        uint256 referredAt;
        uint256 voteWindowAtReferral; // pinned: owner cannot move a live case's clock
        uint256 accusedWeight; // raw getPastStake sum at snapshotTs, same basis as aged votes
        uint256 guiltyVotes; // aged weight
        uint256 notGuiltyVotes; // aged weight
        Phase phase;
        IChallengeGame.Verdict verdict;
        uint256 finalizedAt;
        address challenger; // pinned Challenge.challenger, written once in refer (finding #7)
        uint256 accusedWeightAtLookback; // raw getPastStake sum at snapshotTs - FLOOR_LOOKBACK, same accused set as accusedWeight (finding #6)
    }

    /// @notice A wiring setter was handed the zero address.
    error ZeroAddress();
    /// @notice A bounded setter was handed a value outside its allowed range.
    error InvalidParameter();
    /// @notice `refer` called on a challenge that already has a case on the
    ///         currently-wired game (`caseOfChallenge[challengeGame][id] != 0`)
    ///         — one case per (game, challenge), enforced at the door rather
    ///         than left to a downstream overwrite.
    error AlreadyReferred();
    /// @notice `refer` called on a challenge whose `IChallengeGame.Status` is
    ///         not `Disputed` — there is nothing to adjudicate yet (still
    ///         `Filed`) or nothing left to adjudicate (already terminal).
    error ChallengeNotDisputed();
    /// @notice `refer`'s clock check failed: the challenge's own timeout does
    ///         not leave `voteWindow + FINALIZE_BUFFER` of room, so a vote
    ///         opened now could never finish before the game's permissionless
    ///         timeout resolves the challenge out from under it.
    error InsufficientClock();
    /// @notice A call landed on a case whose `Phase` does not permit it —
    ///         voting or finalizing outside `Voting`, for instance.
    error WrongPhase();
    /// @notice `finalize` called before `referredAt + voteWindowAtReferral`
    ///         has elapsed. With an open electorate there is no "everyone has
    ///         voted" early-close condition — the window must run its course.
    error WindowOpen();
    /// @notice `vote` called after `referredAt + voteWindowAtReferral` has
    ///         elapsed — the one window this case gets has already closed.
    error WindowClosed();
    /// @notice `vote` called a second time by the same address. One vote per
    ///         voter, no re-weighting: there is no path to change a cast
    ///         vote, only to be refused a second one.
    error AlreadyVoted();
    /// @notice `vote` called by an address in the accused set. The accused
    ///         cannot vote on their own verdict.
    error AccusedCannotVote();
    /// @notice `vote` called by an address whose growth-gated ballot weight is
    ///         zero — either it had no aged weight at `snapshotTs`, or its raw
    ///         stake grew over the preceding `FLOOR_LOOKBACK` and its aged weight
    ///         that far back was zero (the fresh-whale signature: raw stake
    ///         acquired entirely inside the window carries no ballot). A verdict
    ///         on the past — there is no remedy.
    error NoVotingPower();
    /// @notice `vote` called by an address that had weight at `snapshotTs` but
    ///         holds nothing NOW — the present-holdings gate. Distinct from
    ///         `NoVotingPower` because the remedy is the opposite: re-stake at
    ///         least `minGuardianStake` and the address becomes votable again, at
    ///         the historic raw checkpoint discounted to `ageFloorBps`.
    error NoPresentHoldings();
    /// @notice `vote` called by the challenge's own challenger. A `Guilty` verdict
    ///         pays it the accused's bond plus the escalated pool, so letting it
    ///         vote on its own filing is a self-dealing conviction — the same
    ///         defect `AccusedCannotVote` closes for the other side.
    error ChallengerCannotVote();
    /// @notice `renounceOwnership` was called. The court refuses it outright, for
    ///         everyone including the owner: it is non-upgradeable, so an
    ///         ownerless court can never again be re-wired or re-tuned — losing
    ///         both the rescue path for a compromised dependency and the
    ///         counter-lever the live `participationFloorBps` read provides.
    error OwnershipCannotBeRenounced();
    /// @notice A setter would break the cross-contract invariant `autoSlashDelay
    ///         + voteWindow + FINALIZE_BUFFER <= disputeTimeout`. Raised by
    ///         `setVoteWindow` — see `ChallengeGame._requireWindowFits` for why
    ///         neither contract can hold this invariant alone.
    error WindowInvariantViolated();
    /// @notice A setter would break the cross-contract invariant
    ///         `participationFloorBps < ageFloorBps`. Raised by
    ///         `setParticipationFloorBps` (against the wired sWOOD, when one is)
    ///         and `setStakedWood` (against the new sWOOD, always). At equality
    ///         the raw-turnout fraction needed to clear the floor is 100% of
    ///         un-accused stake voting at age zero, which is not a liveness
    ///         guarantee anyone can stand on.
    error FloorInvariantViolated();

    /// @notice A case opened. `snapshotTs` is logged here so indexers never
    ///         need a second read to learn the electorate cutoff `refer`
    ///         pinned.
    event CaseReferred(
        uint256 indexed caseId,
        uint256 indexed challengeId,
        address indexed governor,
        uint256 proposalId,
        uint256 snapshotTs
    );
    /// @notice The accused set `refer` recorded for this case, and the raw
    ///         `accusedWeight` it summed to. `count` is the array length —
    ///         logged rather than requiring an indexer to decode
    ///         `_accused[caseId]`'s eventual length from other events.
    event AccusedSetRecorded(uint256 indexed caseId, uint256 count, uint256 accusedWeight);
    /// @notice One vote cast. `weight` is the aged `getPastVotes` amount this
    ///         ballot carried, not a raw stake — the same number `finalize`
    ///         sums into `guiltyVotes`/`notGuiltyVotes`. May be a
    ///         growth-gated min against the caller's aged weight
    ///         `FLOOR_LOOKBACK` before `snapshotTs` rather than the bare
    ///         snapshot read — see `vote`'s natspec (issue #82).
    event VoteCast(uint256 indexed caseId, address indexed voter, bool guilty, uint256 weight);
    /// @notice A case resolved. `floor` is logged alongside the tally so an
    ///         `Inconclusive` verdict is explainable from the log alone —
    ///         without it, "turnout < floor" is unverifiable off-chain
    ///         without re-deriving `_participationFloor` at `snapshotTs`.
    event CaseFinalized(
        uint256 indexed caseId,
        IChallengeGame.Verdict verdict,
        uint256 guiltyVotes,
        uint256 notGuiltyVotes,
        uint256 floor
    );
    /// @notice `rule` reverted with `WrongStatus` — the challenge went terminal on
    ///         its own clock during the finalize buffer, so there is nothing left
    ///         to rule. The case still closes and, with zero custody, this is
    ///         bookkeeping rather than fund loss. Every OTHER revert from `rule`
    ///         bubbles out of `finalize` instead, so the case stays `Voting` for
    ///         an honest retry.
    event ChallengeAlreadyTerminal(uint256 indexed caseId, uint256 indexed challengeId);
    /// @notice The wired `ChallengeGame` changed (or was set for the first
    ///         time, `oldGame == address(0)`).
    event ChallengeGameSet(address indexed oldGame, address indexed newGame);
    /// @notice The wired `StakedWood` electorate source changed (or was set
    ///         for the first time, `oldStakedWood == address(0)`).
    event StakedWoodSet(address indexed oldStakedWood, address indexed newStakedWood);
    /// @notice The default vote window changed. Governs future referrals
    ///         only — every case already `Voting` keeps the window it was
    ///         referred under (`voteWindowAtReferral`).
    event VoteWindowSet(uint256 oldWindow, uint256 newWindow);
    /// @notice The anti-capture participation floor changed. Governs future
    ///         finalizations only.
    event ParticipationFloorBpsSet(uint256 oldBps, uint256 newBps);

    /// @notice Ceiling on `setVoteWindow`'s argument. Bounds how long a
    ///         disputed challenge's coverage can stay frozen awaiting a vote.
    function MAX_VOTE_WINDOW() external view returns (uint256);
    /// @notice Grace period after the vote window closes during which
    ///         someone should call `finalize` before the challenge's own
    ///         `disputeTimeout` can resolve it by timeout instead. Not
    ///         enforced on-chain (the game's timeout is not gated on court
    ///         state) — it is the margin `refer`'s clock check reserves.
    function FINALIZE_BUFFER() external view returns (uint256);
    /// @notice How far before a case's `snapshotTs` the participation floor's
    ///         electorate base is cross-checked. The base is the SMALLER of the
    ///         UNACCUSED electorate at the snapshot and the UNACCUSED electorate
    ///         this long before it — the accused cohort subtracted at BOTH
    ///         instants, each against the electorate measured at that same instant
    ///         — so stake younger than this cannot RAISE the floor on either side
    ///         of the min. Closes the denial-of-quorum lever a single snapshot
    ///         read left open to anyone staking large, from a never-approving
    ///         address, immediately before executing their own drain.
    function FLOOR_LOOKBACK() external view returns (uint256);
    /// @notice The wired `IChallengeGame` this court adjudicates for and
    ///         reads challenge state from. Zero while unwired.
    function challengeGame() external view returns (address);
    /// @notice The wired `IStakedWood` electorate source (`getPastVotes`,
    ///         `getPastStake`, `getPastTotalVotes`). Zero while unwired.
    function stakedWood() external view returns (address);
    /// @notice The vote window newly referred cases receive. Bounded by
    ///         `MAX_VOTE_WINDOW`; a live case keeps the window it was
    ///         referred under regardless of later changes here.
    function voteWindow() external view returns (uint256);
    /// @notice The anti-capture participation floor, in bps of
    ///         `min(total(snapshotTs) - accusedWeight,
    ///         total(snapshotTs - FLOOR_LOOKBACK) - accusedWeightAtLookback)`,
    ///         where EACH subtraction is floored at zero and taken against the
    ///         SAME-INSTANT accused weight BEFORE the lookback min. Leaving the
    ///         lookback term un-reduced let a large stake from a never-approving
    ///         address at `snapshotTs` flip which term binds and inflate the floor
    ///         past the honest electorate's reachable turnout.
    ///
    ///         A NONZERO lookback term is additionally floored at a fixed fraction
    ///         of the lookback electorate before it competes: an exact-zero term
    ///         falls back safely to the unclamped same-instant term, but a merely
    ///         TINY nonzero one — one unrelated guardian's dust stake while the
    ///         accused otherwise dominated that instant — is not zero yet rounds
    ///         the floor to effectively nothing once scaled by bps.
    ///
    ///         Turnout below the floor resolves `Inconclusive` rather than on the
    ///         raw tally, so a thin, rented-stake vote cannot convict or acquit
    ///         alone. Read LIVE at `finalize`, never pinned per case — which also
    ///         makes it the owner's counter-lever if a large idle stake is
    ///         observed inflating a live case's base.
    function participationFloorBps() external view returns (uint256);
    /// @notice Count of cases ever referred. Case ids are 1-indexed
    ///         (`caseOfChallenge == 0` means "no case").
    function caseCount() external view returns (uint256);
    /// @notice The case id referred for `challengeId` on `game`, or zero.
    /// @dev    Keyed by (game, challengeId), NOT challengeId alone: `ChallengeGame`
    ///         is non-upgradeable, so redeploying it is the migration path and a
    ///         fresh game's `challengeCount` restarts at 0 — its ids would
    ///         otherwise collide with every case the old game ever referred.
    function caseOfChallenge(address game, uint256 challengeId) external view returns (uint256);
    /// @notice Full state of one case.
    function caseOf(uint256 caseId) external view returns (Case memory);
    /// @notice How `voter` ruled on `caseId`, or `Ruling.None` if they have
    ///         not voted.
    function voteOf(uint256 caseId, address voter) external view returns (Ruling);
    /// @notice Whether `account` is in `caseId`'s accused set — the set
    ///         `vote` bars from casting a ballot.
    function isAccused(uint256 caseId, address account) external view returns (bool);
    /// @notice The accused set `refer` recorded for `caseId`, in the order it
    ///         was recorded.
    function accusedOf(uint256 caseId) external view returns (address[] memory);

    /// @notice Open a case for a disputed challenge. Permissionless and free — the
    ///         entry point both the game's auto-referral and any manual fallback
    ///         call.
    /// @dev    Requires `challengeGame`/`stakedWood` wired, no existing case for
    ///         this challenge on the currently-wired game, status `Disputed`, and
    ///         the clock check — a vote that could not finish before the game's
    ///         own timeout never opens.
    /// @dev    PINS THE EXPOSURE LEDGER alongside `game` and `snapshotTs`: one
    ///         read feeds both the stored pointer and the accused-set derivation,
    ///         so a later `setExposureLedger` cannot move a live case's accused
    ///         set, weight, or participation floor. Its residual counterpart — a
    ///         re-point strictly BETWEEN `file` and `refer` — is out of the
    ///         court's reach entirely.
    /// @return caseId The new case's id.
    function refer(uint256 challengeId) external returns (uint256 caseId);
    /// @notice Cast the one vote this address gets on `caseId`.
    /// @dev    Weight is `getPastVotes(msg.sender, case.snapshotTs)` — aged,
    ///         snapshot-fixed — UNLESS the caller's raw stake grew over the
    ///         `FLOOR_LOOKBACK` window preceding the snapshot, in which case it is
    ///         the minimum of that weight and the caller's aged weight
    ///         `FLOOR_LOOKBACK` earlier. Reverts outside the open window, for a
    ///         second vote, for an accused address, for the case's own challenger,
    ///         for zero growth-gated weight, or for holding nothing at the present
    ///         instant — the caller must be an active guardian when the vote is
    ///         cast, even though the weight it counts for is historic.
    function vote(uint256 caseId, bool guilty) external;
    /// @notice Close the vote window and adjudicate `caseId`.
    /// @dev    Requires the window to have elapsed. `Inconclusive` when turnout is
    ///         zero or below the participation floor; otherwise `Guilty` on a
    ///         strict majority, `NotGuilty` on a tie or majority the other way.
    ///         Writes the verdict before calling `rule` on the pinned `game` and
    ///         SELECTIVELY tolerates that call reverting: only `WrongStatus` is
    ///         swallowed — the court holds no WOOD, so a terminal challenge is
    ///         bookkeeping, not stranded funds. Every other revert bubbles whole
    ///         so the case stays `Voting` for an honest retry; a bare catch would
    ///         let anyone burn a `Guilty` verdict for free by starving the child
    ///         call's gas, or by unwiring the court.
    function finalize(uint256 caseId) external;

    /// @notice Wire (or re-wire) the challenge game this court adjudicates
    ///         for. The zero address is refused — an unwired court can
    ///         `refer` nothing. Governs future referrals only: a case already
    ///         `Voting` or `Resolved` keeps the `game` it was referred under
    ///         (`Case.game`), so re-wiring here never redirects a live case's
    ///         `finalize` to a different game.
    function setChallengeGame(address newGame) external;
    /// @notice Wire (or re-wire) the electorate source. The zero address is
    ///         refused. Unconditionally validates
    ///         `participationFloorBps < newStakedWood.ageFloorBps()` against the
    ///         NEW sWOOD, closing the compose-bypass where a floor raised while
    ///         unwired is then wired to an electorate whose age floor it meets or
    ///         exceeds. Also refuses a target that does not implement
    ///         `ageFloorBps()`.
    function setStakedWood(address newStakedWood) external;
    /// @notice Set the vote window newly referred cases receive. Bounded to
    ///         `(0, MAX_VOTE_WINDOW]`; zero would open a case that could
    ///         never be voted on. Governs future referrals only — see
    ///         `voteWindowAtReferral`.
    function setVoteWindow(uint256 newWindow) external;
    /// @notice Set the anti-capture participation floor. Bounded to `(0, 10_000]`;
    ///         zero would let any nonzero turnout, however thin, reach a verdict
    ///         on the merits. When an electorate is wired, also validates
    ///         `newBps < stakedWood.ageFloorBps()` against its LIVE age floor —
    ///         vacuous while unwired.
    function setParticipationFloorBps(uint256 newBps) external;
}
