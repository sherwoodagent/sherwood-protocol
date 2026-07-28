// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ITokenCourt} from "./interfaces/ITokenCourt.sol";
import {IChallengeGame} from "./interfaces/IChallengeGame.sol";
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";
import {IStakedWood} from "./interfaces/IStakedWood.sol";

/// @notice The one thing the court needs from the game that `IChallengeGame`
///         does not declare: WHICH LEDGER THE GAME TRUSTS. Read from the game,
///         never from the challenger-supplied governor - a hostile governor
///         could report no approvers and delete the accused set.
interface IChallengeGameLedger {
    function exposureLedger() external view returns (address);
}

/**
 * @title TokenCourt
 * @notice Single-layer WOOD-vote adjudication of disputed `ChallengeGame`
 *         challenges (spec 2026-07-28-token-court-design.md §3). Replaces the
 *         two-layer panel court: one referral opens one vote window, one
 *         tally against a participation floor produces the verdict. There is
 *         no panel, no appeal, no bad-faith track.
 *
 * @dev    HOLDS NO WOOD, EVER. No bonds, no custody bookkeeping, no
 *         `SafeERC20` import — every WOOD-moving effect of a verdict
 *         (slash, demotion, bond return, pool payout) lives on `ChallengeGame`
 *         and `StakedWood`. This contract only decides `Guilty` / `NotGuilty`
 *         / `Inconclusive` and hands that decision to the game via `rule`.
 *         Zero custody is also why there is no pause here (see below) and why
 *         a reverting `IChallengeGame.rule` call (`ChallengeAlreadyTerminal`)
 *         is bookkeeping rather than a stuck-funds hazard.
 *
 * @dev    NON-UPGRADEABLE, PLAIN `Ownable2Step` — the house shape for
 *         single-owner administrative contracts in this protocol (mirrors
 *         `ChallengeGame`). No UUPS/beacon proxy: the court has no storage
 *         layout to protect across upgrades and no shared implementation to
 *         coordinate, so the upgrade machinery would be pure surface area.
 *
 * @dev    NO PAUSE EXISTS ON THIS CONTRACT (spec §3). The human backstop for
 *         the whole system is `ChallengeGame.setFilingsPaused`, which gates
 *         `file` only. Pausing referral or voting HERE would let an
 *         already-disputed challenge drift toward its own `disputeTimeout`
 *         while the court sits frozen, forfeiting an honest challenger's bond
 *         by owner inaction — the opposite of what a safety lever should do.
 *         Stopping new challenges from entering is sufficient, and it is the
 *         game's lever, not this contract's.
 */
contract TokenCourt is Ownable2Step, ITokenCourt {
    /// @notice Ceiling on `setVoteWindow`'s argument. Bounds how long a
    ///         disputed challenge's coverage can stay frozen awaiting a vote.
    uint256 public constant MAX_VOTE_WINDOW = 14 days;
    /// @notice Grace period after the vote window for someone to call
    ///         `finalize` before the challenge's own timeout can fire.
    uint256 public constant FINALIZE_BUFFER = 1 days;
    /// @dev Basis-point denominator shared by `participationFloorBps`.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice The wired `IChallengeGame` this court adjudicates for and
    ///         reads challenge state from. Zero while unwired.
    address public challengeGame;
    /// @notice The wired `IStakedWood` electorate source. Zero while unwired.
    address public stakedWood;
    /// @notice The vote window newly referred cases receive. Bounded by
    ///         `MAX_VOTE_WINDOW`; a live case keeps the window it was
    ///         referred under regardless of later changes here.
    uint256 public voteWindow = 5 days;
    /// @notice The anti-capture participation floor (spec §3 D6), in bps of
    ///         `total - accusedWeight` at a case's snapshot.
    uint256 public participationFloorBps = 1_000;

    /// @notice Count of cases ever referred. Case ids are 1-indexed.
    uint256 public caseCount;
    mapping(uint256 caseId => ITokenCourt.Case) internal _cases;
    /// @notice The case id referred for a challenge, or zero if none has been.
    mapping(uint256 challengeId => uint256 caseId) public caseOfChallenge;
    /// @notice How an address ruled on a case, or `Ruling.None` unvoted.
    mapping(uint256 caseId => mapping(address voter => ITokenCourt.Ruling)) public voteOf;
    /// @notice Whether an address is in a case's accused set.
    mapping(uint256 caseId => mapping(address account => bool)) public isAccused;
    mapping(uint256 caseId => address[]) internal _accused;

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @inheritdoc ITokenCourt
    function caseOf(uint256 caseId) external view returns (ITokenCourt.Case memory) {
        return _cases[caseId];
    }

    /// @inheritdoc ITokenCourt
    function accusedOf(uint256 caseId) external view returns (address[] memory) {
        return _accused[caseId];
    }

    /// @inheritdoc ITokenCourt
    function setChallengeGame(address newGame) external onlyOwner {
        if (newGame == address(0)) revert ZeroAddress();
        emit ChallengeGameSet(challengeGame, newGame);
        challengeGame = newGame;
    }

    /// @inheritdoc ITokenCourt
    function setStakedWood(address newStakedWood) external onlyOwner {
        if (newStakedWood == address(0)) revert ZeroAddress();
        emit StakedWoodSet(stakedWood, newStakedWood);
        stakedWood = newStakedWood;
    }

    /// @inheritdoc ITokenCourt
    function setVoteWindow(uint256 newWindow) external onlyOwner {
        if (newWindow == 0 || newWindow > MAX_VOTE_WINDOW) revert InvalidParameter();
        emit VoteWindowSet(voteWindow, newWindow);
        voteWindow = newWindow;
    }

    /// @inheritdoc ITokenCourt
    function setParticipationFloorBps(uint256 newBps) external onlyOwner {
        if (newBps == 0 || newBps > BPS_DENOMINATOR) revert InvalidParameter();
        emit ParticipationFloorBpsSet(participationFloorBps, newBps);
        participationFloorBps = newBps;
    }

    /// @inheritdoc ITokenCourt
    /// @dev    THE SNAPSHOT IS COMPUTED HERE, ONCE, AND STORED (decision D2).
    ///         It is `executedAt - 1` — the block before the challenged
    ///         proposal executed — the same instant the compensation path and
    ///         the settle-path slash use. Storing it rather than re-deriving
    ///         it on every `vote`/`finalize` call is what keeps the electorate
    ///         that judges guilt identical no matter how many blocks pass
    ///         before the window closes, and it means the vote cannot be made
    ///         to disagree with itself about who is entitled to vote — not
    ///         even if the governor's proposal record moved underneath it.
    /// @dev    NOTHING HERE EXTENDS THE CHALLENGE'S OWN CLOCK. `ChallengeGame`
    ///         still fails a disputed challenge to the accused at
    ///         `filedAt + disputeTimeoutAtFiling`, so a referral filed very
    ///         late would leave the vote too little time to reach a verdict.
    ///         Rather than open a case doomed to lose the race (review finding
    ///         E1's live-race version), THE CLOCK CHECK below refuses to open
    ///         one at all unless `voteWindow + FINALIZE_BUFFER` still fits
    ///         before the timeout — turning a runtime race into a structural
    ///         impossibility: a case that exists is always one that can finish.
    /// @dev    STATE IS CLAIMED BEFORE ANY EXTERNAL READ, even though this
    ///         function reads NOTHING off the challenger-supplied governor
    ///         any more — `ch.executedAt` comes from the game's own pinned
    ///         record, not a live `ISyndicateGovernor.getProposal` call (see
    ///         below). The only external read of challenge state left is
    ///         `challengeOf` itself, and it is `view`, so the compiler emits
    ///         STATICCALL and re-entry is impossible at the EVM level today.
    ///         Claiming `caseOfChallenge[challengeId]` before that read is what keeps
    ///         a second `refer` on the same challenge harmless — not
    ///         impossible, just a no-op `AlreadyReferred` — if `challengeOf`
    ///         ever loses its `view` or the game ever calls back into the
    ///         court.
    function refer(uint256 challengeId) external returns (uint256 caseId) {
        address game = challengeGame;
        address swood = stakedWood;
        // Requires wired (review finding E4 closed structurally): a case can
        // no longer exist before its electorate does.
        if (game == address(0) || swood == address(0)) revert ZeroAddress();
        if (caseOfChallenge[challengeId] != 0) revert AlreadyReferred();

        caseId = ++caseCount;
        caseOfChallenge[challengeId] = caseId;

        IChallengeGame.Challenge memory ch = IChallengeGame(game).challengeOf(challengeId);
        // Only a contested challenge is escalated: a `Filed` one is still
        // inside its own auto-slash clock (silence is already the verdict
        // there), and a terminal one has nothing left to decide.
        if (ch.status != IChallengeGame.Status.Disputed) revert ChallengeNotDisputed();

        // The clock check: a vote that could not finish before the
        // challenge's own timeout never opens.
        uint256 window = voteWindow;
        if (block.timestamp + window + FINALIZE_BUFFER > ch.filedAt + ch.disputeTimeoutAtFiling) {
            revert InsufficientClock();
        }

        // `ch.executedAt` is the game's OWN pin (F10): `ChallengeGame` snapshots
        // it at filing from the proposal record and never re-reads a live
        // governor afterward — the settle-path slash is sized against this
        // same field. Reading it here rather than calling back into
        // `ch.governor` means the snapshot instant equals the settle-path
        // slash instant BY CONSTRUCTION (one write, two readers), not because
        // two independent reads happen to agree — a mutable governor record
        // could otherwise move the second read out from under the first.
        uint256 executedAt = ch.executedAt;
        // Unreachable through a real filing — `ChallengeGame.file` rejects an
        // unexecuted proposal, so this guard is a restatement of that
        // `NotExecuted` invariant here — but fail closed rather than
        // underflow into a snapshot at `type(uint256).max`, an instant nobody
        // has voting power at.
        if (executedAt == 0) revert InvalidParameter();
        uint256 snapshotTs = executedAt - 1;

        ITokenCourt.Case storage c = _cases[caseId];
        c.challengeId = challengeId;
        c.snapshotTs = snapshotTs;
        c.referredAt = block.timestamp;
        c.voteWindowAtReferral = window;
        c.phase = ITokenCourt.Phase.Voting;

        emit CaseReferred(caseId, challengeId, ch.governor, ch.proposalId, snapshotTs);

        // THE ACCUSED SET IS FIXED HERE, under the same rule as the snapshot
        // directly above it. `vote` bars this set from casting a ballot, and
        // the weight recorded below is what the participation floor's base
        // subtracts.
        _recordAccused(caseId, c, game, ch.governor, ch.proposalId, snapshotTs);
    }

    /// @inheritdoc ITokenCourt
    /// @dev    DO NOT RE-WEIGHT THE RESULT (D3). `getPastVotes` is documented
    ///         by `IStakedWood` as age-weighted own staked WOOD already — a
    ///         second aging curve here would duplicate the staking contract's
    ///         and inevitably diverge from it. There is exactly one basis for
    ///         a vote's weight, and it lives in `StakedWood`, not here.
    /// @dev    THE ZERO-WEIGHT REVERT IS THE FLASH-LOAN DEFENCE, and it is a
    ///         consequence of the snapshot rather than a check of its own.
    ///         Weight is read at `c.snapshotTs` — `executedAt - 1`, the instant
    ///         BEFORE the challenged proposal executed — so WOOD bought or
    ///         staked after the drain, by the exploiter or by anyone who saw
    ///         it happen, has no weight at all. There is no borrow, no flash
    ///         loan, and no post-hoc accumulation that reaches back past a
    ///         stored timestamp.
    /// @dev    THE ACCUSED MAY NOT VOTE, and this is the check the snapshot
    ///         alone could never make. The snapshot bars whoever bought in
    ///         AFTER the drain; it says nothing about the approvers who were
    ///         already large holders BEFORE it — and those are exactly the
    ///         defendants, because a guardian has to stake WOOD to back
    ///         coverage at all. Left in, they could be routinely large enough
    ///         on their own to clear the participation floor and carry the
    ///         vote: a defendant that can outvote its own jury inverts the
    ///         layer, turning "the electorate judges the accused" into "the
    ///         accused judges itself".
    /// @dev    NO VOTE CHANGES (D3). `AlreadyVoted` refuses a second call from
    ///         the same address outright rather than accepting the latest one
    ///         — there is no path to change a cast vote, only to be refused a
    ///         second one.
    /// @dev    THE WINDOW IS THE CASE'S PINNED `voteWindowAtReferral`, never
    ///         the live `voteWindow` — see that field's own rationale (F5): a
    ///         later `setVoteWindow` call must not move a live case's clock.
    /// @dev    `guiltyVotes`/`notGuiltyVotes` ACCUMULATE AGED `getPastVotes`
    ///         WEIGHT, while `_participationFloor`'s base is RAW `getPastTotalVotes`
    ///         minus raw accused `getPastStake`. The two tallies are measured
    ///         on deliberately different bases — this is not a mismatch to
    ///         "fix". Aging only ever shrinks weight relative to raw stake, so
    ///         turnout summed here can never exceed what the floor's raw base
    ///         would have summed for the same voters; the floor stays
    ///         conservative rather than reachable by an aged-down electorate.
    ///         See `_participationFloor`.
    function vote(uint256 caseId, bool guilty) external {
        ITokenCourt.Case storage c = _cases[caseId];
        if (c.phase != ITokenCourt.Phase.Voting) revert WrongPhase();
        if (block.timestamp >= c.referredAt + c.voteWindowAtReferral) revert WindowClosed();
        if (voteOf[caseId][msg.sender] != ITokenCourt.Ruling.None) revert AlreadyVoted();
        if (isAccused[caseId][msg.sender]) revert AccusedCannotVote();

        uint256 weight = IStakedWood(stakedWood).getPastVotes(msg.sender, c.snapshotTs);
        if (weight == 0) revert NoVotingPower();

        voteOf[caseId][msg.sender] = guilty ? ITokenCourt.Ruling.Guilty : ITokenCourt.Ruling.NotGuilty;
        if (guilty) {
            c.guiltyVotes += weight;
        } else {
            c.notGuiltyVotes += weight;
        }

        emit VoteCast(caseId, msg.sender, guilty, weight);
    }

    /// @inheritdoc ITokenCourt
    /// @dev    THE VERDICT TABLE (spec §3), and why each branch fails safe:
    ///         - `turnout == 0 || turnout < floor` -> `Inconclusive`. This is a
    ///           NON-EVENT that unwinds both sides whole (`IChallengeGame.rule`'s
    ///           own natspec), not an acquittal-with-forfeit. A thin or absent
    ///           vote answers nothing about guilt, so it must not be read as an
    ///           answer in either direction — the D6 anti-capture floor exists
    ///           precisely so a small, possibly rented, stake cannot manufacture
    ///           either a conviction or a clean acquittal by being the only
    ///           voice in the room.
    ///         - `guiltyVotes > notGuiltyVotes` -> `Guilty`. A STRICT majority is
    ///           required, not a plurality — see the next branch.
    ///         - otherwise (a tie included) -> `NotGuilty`. A tie carries no
    ///           ground truth either way; failing it to `NotGuilty` rather than
    ///           `Guilty` is deliberate, because `Guilty` triggers a 100%-style
    ///           slash (D7, `IChallengeGame.rule`) and an even vote is the worst
    ///           possible basis for destroying stake. `IChallengeGame.Verdict`'s
    ///           enum order (`{Inconclusive, NotGuilty, Guilty}`) makes this the
    ///           SAME direction the zero-value default already fails toward —
    ///           there is no separate case here that could disagree with it.
    /// @dev    STATE IS CLOSED BEFORE THE EXTERNAL CALL, and the `rule` call is
    ///         wrapped in try/catch — review finding E1 made structural. Between
    ///         a case's vote window closing and someone calling `finalize`, the
    ///         underlying challenge can go terminal on its OWN clock
    ///         (`ChallengeGame.resolve`'s `disputeTimeout`, or a second court
    ///         beating this call to `rule`), in which case `IChallengeGame.rule`
    ///         reverts `WrongStatus`/`NotCourt`. Writing `phase = Resolved` and
    ///         emitting `CaseFinalized` FIRST, then tolerating that revert
    ///         (`ChallengeAlreadyTerminal`), is what stops a terminal-race loser
    ///         from wedging this case open forever: the court holds no WOOD, as
    ///         stated in the contract-level docs above, so a verdict that never
    ///         lands on the game is bookkeeping — a case this contract will
    ///         never again act on — not a stuck-funds hazard.
    /// @dev    PERMISSIONLESS, like `refer` and `resolve` on the game side: the
    ///         caller chooses nothing here. The window, the tally, and the
    ///         verdict are all already fixed by state and the clock before this
    ///         call runs; opening it to anyone just removes the last place a
    ///         privileged party could sit on a decided case.
    function finalize(uint256 caseId) external {
        ITokenCourt.Case storage c = _cases[caseId];
        if (c.phase != ITokenCourt.Phase.Voting) revert WrongPhase();
        if (block.timestamp < c.referredAt + c.voteWindowAtReferral) revert WindowOpen();

        uint256 guiltyVotes = c.guiltyVotes;
        uint256 notGuiltyVotes = c.notGuiltyVotes;
        uint256 turnout = guiltyVotes + notGuiltyVotes;
        uint256 floor = _participationFloor(c.snapshotTs, c.accusedWeight);

        IChallengeGame.Verdict verdict;
        if (turnout == 0 || turnout < floor) {
            verdict = IChallengeGame.Verdict.Inconclusive;
        } else if (guiltyVotes > notGuiltyVotes) {
            verdict = IChallengeGame.Verdict.Guilty;
        } else {
            verdict = IChallengeGame.Verdict.NotGuilty; // tie fails safe
        }

        // Terminal before the external call (E1, made structural): a missed
        // `rule` below is bookkeeping, not stranded funds, with zero custody.
        c.verdict = verdict;
        c.finalizedAt = block.timestamp;
        c.phase = ITokenCourt.Phase.Resolved;
        emit CaseFinalized(caseId, verdict, guiltyVotes, notGuiltyVotes, floor);

        try IChallengeGame(challengeGame).rule(c.challengeId, verdict) {}
        catch {
            emit ChallengeAlreadyTerminal(caseId, c.challengeId);
        }
    }

    /// @dev THE FLOOR'S BASE IS `getPastTotalVotes(snapshotTs) - accusedWeight`,
    ///      with a `>` fallback to the unreduced total when the subtrahend
    ///      would not strictly reduce it. POST-#29 (carrying review finding
    ///      E3's fix forward): `accusedWeight` sums `getPastStake` over the
    ///      accused set, the exact same raw-own-stake basis
    ///      `getPastTotalVotes` sums over the whole electorate — so
    ///      `accusedWeight <= total` BY CONSTRUCTION, not by luck. The `>`
    ///      check is defence-in-depth against a future basis change on either
    ///      side, not a condition this code expects to fail today.
    /// @dev THE FLOOR READS THE LIVE `participationFloorBps`, DELIBERATELY NOT
    ///      PINNED per-case. This is the opposite choice from `snapshotTs` and
    ///      `voteWindowAtReferral`, which ARE pinned at `refer` — and the
    ///      difference is deliberate, not an oversight carried over from that
    ///      pattern. `snapshotTs`/`voteWindowAtReferral` are pinned because a
    ///      live re-read would let the owner move a case's electorate or clock
    ///      out from under a vote already in progress. The participation floor
    ///      has no such hazard: it is read exactly once, at `finalize`, after
    ///      voting has already closed — there is no window during which a
    ///      change to it could retroactively alter anyone's cast ballot. The
    ///      spec (D6) sanctions this: a floor change is meant to apply to any
    ///      case finalizing after it takes effect, including one already
    ///      `Voting` when the owner adjusts it.
    function _participationFloor(uint256 snapshotTs, uint256 accusedWeight) internal view returns (uint256) {
        uint256 total = IStakedWood(stakedWood).getPastTotalVotes(snapshotTs);
        uint256 base = total > accusedWeight ? total - accusedWeight : total;
        return participationFloorBps * base / BPS_DENOMINATOR;
    }

    /// @dev MIRRORS `ChallengeGame`'s own accused definition exactly, and
    ///      deliberately does not invent a second one: the ledger's covering
    ///      approvers, filtered to those whose committed share is still
    ///      non-zero. The ledger reports a RELEASED commitment as zero rather
    ///      than dropping the entry, and a guardian that released before the
    ///      filing backed nothing on this proposal — so it is not slashed for
    ///      it, and by the same token it is not barred from voting on it. The
    ///      set that loses its stake on a conviction and the set that may not
    ///      vote on that conviction are one list read from one place.
    /// @dev  THE LEDGER COMES FROM THE GAME, NOT FROM `governor`. See
    ///       `IChallengeGameLedger` for why substituting the challenger-
    ///       supplied governor's ledger would hand the accused an empty
    ///       accused set.
    /// @dev  WEIGHT IS SUMMED AT `snapshotTs`, the case's stored instant, so
    ///       the number subtracted from the floor is measured on exactly the
    ///       same electorate as the votes it is compared against. RAW
    ///       `getPastStake`, not aged `getPastVotes` (review finding F17):
    ///       `_participationFloor` subtracts this sum from `getPastTotalVotes`,
    ///       which sums raw own stake — the two must be the same basis or the
    ///       subtraction compares two different measures of the same WOOD.
    /// @dev  A DOUBLE-LISTED APPROVER WOULD DOUBLE-COUNT ITS WEIGHT, so the
    ///       `isAccused` flag is checked before accumulating (dedup guard).
    ///       The ledger does not produce duplicates today; the guard costs one
    ///       extra SLOAD per approver and makes the floor's denominator
    ///       independent of that.
    /// @dev  THE LOOP IS BOUNDED, not unbounded despite the caller-controlled
    ///       `proposalId`: `approversOf` returns the same list
    ///       `GuardianRegistry` walks on every approve/settle, which is capped
    ///       at `MAX_APPROVERS_PER_PROPOSAL = 100` (`GuardianRegistry.sol`).
    ///       So this loop is at most 100 iterations, each one `getPastStake`
    ///       staticcall. FORWARD NOTE for Task 8: the auto-referral path runs
    ///       `refer` (and this loop) inside `ChallengeGame.dispute`'s
    ///       try/catch, so that call pays for up to ~100 `getPastStake`
    ///       staticcalls in the worst case — size the try/catch's gas stipend
    ///       for it.
    function _recordAccused(
        uint256 caseId,
        ITokenCourt.Case storage c,
        address game,
        address governor,
        uint256 proposalId,
        uint256 snapshotTs
    ) internal {
        address ledger = IChallengeGameLedger(game).exposureLedger();
        (address[] memory approvers, uint256[] memory committedUsd) =
            IExposureLedger(ledger).approversOf(governor, proposalId);

        address swood = stakedWood;
        uint256 weight;
        uint256 count;
        for (uint256 i; i < approvers.length; ++i) {
            if (committedUsd[i] == 0) continue; // released before the filing: backs nothing, answers for nothing
            address approver = approvers[i];
            if (isAccused[caseId][approver]) continue; // dedup guard

            isAccused[caseId][approver] = true;
            _accused[caseId].push(approver);
            count += 1;
            weight += IStakedWood(swood).getPastStake(approver, snapshotTs);
        }

        c.accusedWeight = weight;
        emit AccusedSetRecorded(caseId, count, weight);
    }
}
