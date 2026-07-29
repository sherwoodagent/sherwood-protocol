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
    /// @notice The case id referred for a challenge on a given game, or zero
    ///         if none has been.
    /// @dev KEYED BY (GAME, CHALLENGE ID), not by id alone (B1).
    ///      `ChallengeGame` is non-upgradeable, so redeploying it IS the
    ///      migration path and `setChallengeGame` exists to serve it - but a
    ///      fresh game's `challengeCount` restarts at 0, so its ids collide
    ///      with every case the old game already minted. Single-keyed, every
    ///      colliding challenge reverted `AlreadyReferred` on BOTH the
    ///      auto-referral and the permissionless manual fallback, forever, and
    ///      timed out to `_fail` - auto-acquitting the accused and paying it the
    ///      challenger's bond, once per id the old game ever used. Pinning
    ///      `Case.game` fixed the `finalize` half of this; this fixes `refer`.
    mapping(address game => mapping(uint256 challengeId => uint256 caseId)) public caseOfChallenge;
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
    /// @dev THE MIRROR OF `ChallengeGame._requireWindowFits` (B3): the
    ///      cross-contract invariant `autoSlashDelay + voteWindow +
    ///      FINALIZE_BUFFER <= disputeTimeout` spans both contracts, so this
    ///      setter must enforce it too, reading the game's LIVE
    ///      `autoSlashDelay`/`disputeTimeout` rather than trusting whatever held
    ///      the last time either contract's setters happened to check it.
    ///      Vacuous with no game wired: there is no referral clock to fit yet.
    function setVoteWindow(uint256 newWindow) external onlyOwner {
        if (newWindow == 0 || newWindow > MAX_VOTE_WINDOW) revert InvalidParameter();
        address g = challengeGame;
        if (g != address(0)) {
            IChallengeGame game_ = IChallengeGame(g);
            if (game_.autoSlashDelay() + newWindow + FINALIZE_BUFFER > game_.disputeTimeout()) {
                revert WindowInvariantViolated();
            }
        }
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
    ///         Claiming `caseOfChallenge[game][challengeId]` before that read
    ///         is what keeps a second `refer` on the same (game, challenge)
    ///         harmless — not impossible, just a no-op `AlreadyReferred` — if
    ///         `challengeOf` ever loses its `view` or the game ever calls back
    ///         into the court.
    function refer(uint256 challengeId) external returns (uint256 caseId) {
        address game = challengeGame;
        address swood = stakedWood;
        // Requires wired (review finding E4 closed structurally): a case can
        // no longer exist before its electorate does.
        if (game == address(0) || swood == address(0)) revert ZeroAddress();
        if (caseOfChallenge[game][challengeId] != 0) revert AlreadyReferred();

        caseId = ++caseCount;
        caseOfChallenge[game][challengeId] = caseId;

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
        c.game = game; // pinned: setChallengeGame afterward must not redirect finalize's rule call
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
    ///         accused APPROVING ADDRESSES, because a guardian has to stake
    ///         WOOD to back coverage at all. Left in, they could be routinely
    ///         large enough on their own to clear the participation floor and
    ///         carry the vote: an accused address that can outvote its own
    ///         jury inverts the layer, turning "the electorate judges the
    ///         accused" into "the accused judges itself".
    /// @dev    A1 (open, not fixed, spec 2026-07-29 §7): THE BAR IS ON THE
    ///         APPROVING ADDRESS, NOT THE PARTY BEHIND IT. `isAccused` is
    ///         built from the ledger's approver list — addresses — and
    ///         permissionless staking means one economic actor can approve
    ///         (and back coverage for) the same proposal from several
    ///         addresses, or route the drain's benefit to an address that
    ///         never approved at all. Splitting across addresses defeats the
    ///         bar outright: none of the beneficiary's other addresses are in
    ///         the accused set, so they vote freely. The floor mechanics make
    ///         this worse, not neutral: `_participationFloor` subtracts the
    ///         accused set's raw stake from the electorate base, so every
    ///         address the accused set DOES name shrinks the floor the
    ///         siblings' un-accused addresses must clear to carry the vote —
    ///         a larger accused cohort makes the remaining, still-interested
    ///         electorate's job easier, not harder. This is likely unfixable
    ///         under permissionless staking (there is no on-chain notion of
    ///         "the same party"); the natspec must not claim the bar covers a
    ///         defendant or a party — only that it covers the specific
    ///         addresses the ledger already named as approvers.
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
    /// @dev    PRESENT HOLDINGS ARE A GATE, NEVER A WEIGHT (spec 2026-07-29
    ///         §3, B4). Historical weight still decides how much a vote
    ///         counts — that is the D2 flash-loan defence above, and it is
    ///         unchanged. This decides only WHETHER the caller may vote at
    ///         all — you must be an active guardian (present stake, no
    ///         pending unstake request) at the INSTANT you cast, nothing
    ///         about before or after. `requestUnstakeGuardian` — not
    ///         `claimUnstakeGuardian` — is where the leak actually opens: it
    ///         re-anchors `stakedAt` and pushes a 0 stake checkpoint, so
    ///         `getVotes` already reads zero from the request instant, well
    ///         before the cooldown that `claimUnstakeGuardian` waits out. The
    ///         gate is evaluated only at vote time, so it does not make
    ///         voting capital illiquid for the rest of the case — vote, then
    ///         request, then claim once `coolDownPeriod` elapses (floor 1
    ///         day), all comfortably before `finalize`, is untouched. Nor
    ///         does it drive alignment to exactly zero: a fully exited holder
    ///         can re-stake `minGuardianStake` and pass the gate again —
    ///         voting at the historic raw checkpoint discounted to
    ///         `ageFloorBps`, because the re-stake re-anchors `stakedAt`, NOT
    ///         at its original historic weight. That returns the bypass to
    ///         exactly the 25%-of-historic-weight shape B4 describes, now
    ///         costing `minGuardianStake` instead of nothing — a residual
    ///         bounded by that cost, not eliminated. That is the inherent
    ///         shape of a binary gate, not a bug in it.
    ///         Re-WEIGHTING on present holdings would reintroduce the
    ///         post-hoc accumulation the snapshot exists to close, so this
    ///         stays binary.
    function vote(uint256 caseId, bool guilty) external {
        ITokenCourt.Case storage c = _cases[caseId];
        if (c.phase != ITokenCourt.Phase.Voting) revert WrongPhase();
        if (block.timestamp >= c.referredAt + c.voteWindowAtReferral) revert WindowClosed();
        if (voteOf[caseId][msg.sender] != ITokenCourt.Ruling.None) revert AlreadyVoted();
        if (isAccused[caseId][msg.sender]) revert AccusedCannotVote();

        uint256 weight = IStakedWood(stakedWood).getPastVotes(msg.sender, c.snapshotTs);
        if (weight == 0) revert NoVotingPower();
        // Present-holdings gate (B4) — see the @dev block above `vote`.
        if (IStakedWood(stakedWood).getVotes(msg.sender) == 0) revert NoPresentHoldings();

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
    ///         reverts `WrongStatus`. Writing `phase = Resolved` and emitting
    ///         `CaseFinalized` FIRST, then tolerating ONLY THAT ONE revert
    ///         (`ChallengeAlreadyTerminal`), is what stops a terminal-race loser
    ///         from wedging this case open forever: the court holds no WOOD, as
    ///         stated in the contract-level docs above, so a verdict that never
    ///         lands on the game is bookkeeping — a case this contract will
    ///         never again act on — not a stuck-funds hazard.
    /// @dev    THE CATCH IS SELECTOR-FILTERED, NOT BARE. A bare catch here is a
    ///         verdict-burning primitive: `rule`'s callee-side gas floor
    ///         (`InsufficientSlashGas`, sized against the slash's approver
    ///         count) can be forced to revert by an under-gassed `finalize`
    ///         call while the parent still has plenty of gas left to complete
    ///         on the refund — so a bare catch would write `Resolved` and drop
    ///         a `Guilty` verdict PERMANENTLY, for the price of choosing a gas
    ///         limit, with the accused as the obvious profiteer: acquitted by
    ///         timeout later, and paid the challenger's forfeited bond. Only
    ///         `WrongStatus` means "nothing is left to rule" — every other
    ///         revert (`InsufficientSlashGas` chief among them, but also
    ///         `NotCourt` from an owner re-pointing the game's `court` while the
    ///         challenge is still `Disputed` and fully rulable (B2), an unwired
    ///         escrow/slasher, or a token failure inside the slash) is
    ///         TRANSIENT: it bubbles the whole `finalize` call back out, which
    ///         reverts the state writes above too, so the case is left exactly
    ///         where it was — `Voting`, tally intact — for an honest caller to
    ///         retry once the condition clears. `NotCourt` in particular must
    ///         NOT be swallowed here: doing so would close the case with a
    ///         verdict recorded and undelivered, and re-wiring the court back
    ///         could not redeliver it (`refer` reverts `AlreadyReferred`) — the
    ///         same verdict-burning outcome this filter exists to prevent,
    ///         reached by an owner action instead of a gas dial.
    /// @dev    PERMISSIONLESS, like `refer` and `resolve` on the game side: the
    ///         caller chooses nothing here. The window, the tally, and the
    ///         verdict are all already fixed by state and the clock before this
    ///         call runs; opening it to anyone just removes the last place a
    ///         privileged party could sit on a decided case.
    /// @dev    A2 (open, not fixed, spec 2026-07-29 §7): LAST-MOVER ADVANTAGE
    ///         IS UNMITIGATED. Every vote is visible on-chain the instant it
    ///         lands (`VoteCast`), the deadline is hard
    ///         (`referredAt + voteWindowAtReferral`), and a TIE ACQUITS
    ///         (`NotGuilty`, see the verdict table above) — so the acquitting
    ///         side only has to MATCH the guilty tally in the final block, not
    ///         exceed it, while the guilty side must move first to be seen at
    ///         all. Public tallies mean nothing is learned by waiting except
    ///         everyone else's position, so the rational strategy for a
    ///         well-funded acquittal is to hold votes back and land exactly
    ///         enough weight after the last honest vote to tie or win, with no
    ///         window left for a response. §6's trigger for revisiting M1
    ///         names this precisely: "any case where the tally moves
    ///         decisively in the final hour of the vote window" IS what a
    ///         bought vote looks like. The mitigation short of commit-reveal is
    ///         a vote-extension (any late vote pushes the deadline out), which
    ///         this contract deliberately does not implement — deferred with
    ///         §6's trigger, not fixed here.
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

        // Terminal before the external call (E1, made structural): a swallowed
        // WrongStatus below is bookkeeping, not stranded funds, with zero
        // custody. Everything else - NotCourt included (B2) - bubbles and
        // reverts these writes too.
        c.verdict = verdict;
        c.finalizedAt = block.timestamp;
        c.phase = ITokenCourt.Phase.Resolved;
        emit CaseFinalized(caseId, verdict, guiltyVotes, notGuiltyVotes, floor);

        try IChallengeGame(c.game).rule(c.challengeId, verdict) {}
        catch (bytes memory reason) {
            // SWALLOW ONLY `WrongStatus` - the one revert that genuinely means
            // "there is nothing left to rule": once `refer` has succeeded a
            // challenge can only leave `Disputed` by going terminal, which is
            // the E1 race this catch exists for.
            //
            // `NotCourt` does NOT mean that (B2). It means the game was
            // re-pointed away while the challenge is STILL `Disputed` and fully
            // rulable, so swallowing it closes the case with a verdict recorded
            // and undelivered - and re-wiring cannot redeliver it, because
            // `refer` reverts `AlreadyReferred`. The challenge then times out
            // and acquits, paying the accused the challenger's forfeited bond:
            // the same verdict-burning outcome this filter was written to
            // close, reached by an owner action instead of a gas dial. It is
            // transient and retryable, so it bubbles with everything else.
            bytes4 sel = reason.length >= 4 ? bytes4(reason) : bytes4(0);
            if (sel != IChallengeGame.WrongStatus.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
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
    /// @dev  THE LIVE READ ALSO MEANS the owner can, by raising
    ///       `participationFloorBps` before a pending `finalize`, push a live
    ///       case that would otherwise have cleared the floor down into
    ///       `Inconclusive` instead. Accepted for the same D6 reason above:
    ///       `Inconclusive` unwinds both sides whole and the proposal stays
    ///       re-challengeable, so the owner's live lever here can only ever
    ///       withhold a verdict — it moves no money to anyone and cannot
    ///       manufacture a conviction or an acquittal it did not earn.
    /// @dev  `stakedWood` IS LIKEWISE READ LIVE HERE, not pinned per-case: this
    ///       `total` comes from whichever contract `stakedWood` names at
    ///       `finalize` time, while `accusedWeight` was already fixed against
    ///       whatever `stakedWood` named back at `refer`, and the votes summed
    ///       into `guiltyVotes`/`notGuiltyVotes` were weighed against whatever
    ///       it named at each `vote` call. A `setStakedWood` re-point between
    ///       `vote` and `finalize` therefore changes the floor's basis to a
    ///       different contract's checkpoints than the ones the cast votes
    ///       were weighed against. Accepted for the same reason the game's own
    ///       wiring setters (`setChallengeGame`, `setStakedWood`) stay live
    ///       rather than pinned per-case: they are the owner's rescue path for
    ///       a compromised or upgraded dependency, and the owner is trusted.
    ///       Flagged here as a deliberately deferred hazard, not an oversight.
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
    ///       POST-A5: the raw basis is not merely a units argument — it also
    ///       denies the accused a free lever on its own conviction threshold.
    ///       If this summed aged `getPastVotes` instead, an accused approver
    ///       could call `requestUnstakeGuardian` — free, permissionless,
    ///       cancellable — between the drain and `refer`, re-anchoring its
    ///       `stakedAt` and flooring its own contribution to `ageFloorBps`.
    ///       That shrinks the subtrahend, RAISES the floor, and can push a
    ///       case the accused was certain to lose into `Inconclusive` (which
    ///       unwinds both sides whole and escapes the slash entirely). The
    ///       raw basis is immune: `getPastStake` reads the checkpointed
    ///       amount directly, with no live, re-anchorable factor for a
    ///       pending unstake request to move.
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
    ///       staticcall.
    /// @dev  TASK 8 DECIDED THE OPPOSITE OF SIZING A STIPEND FOR THIS LOOP.
    ///       The auto-referral path does run `refer` (and this loop) inside
    ///       `ChallengeGame.dispute`'s try/catch, which pays for up to ~100
    ///       `getPastStake` staticcalls in the worst case — but no gas floor
    ///       fronts that call, deliberately. `dispute` is how the accused BUY
    ///       their defence: a reverting `dispute` denies it outright and the
    ///       accused is slashed by the silence verdict without ever reaching
    ///       adjudication, which is unrecoverable. A skipped referral is not —
    ///       `refer` is permissionless, so anyone (the challenger, who wants
    ///       the slash, most of all) can call it directly once the catch
    ///       reports `AutoReferFailed`. Guarding the recoverable failure by
    ///       manufacturing the unrecoverable one is the wrong trade, so the
    ///       try/catch in `ChallengeGame.dispute` stays broad and ungated. In
    ///       practice an ordinary caller's gas budget is enough anyway: this
    ///       loop's cost is bounded by the same 100-approver cap referenced
    ///       above, measured at ~5.06M gas at that cap — well inside what a
    ///       real transaction forwards. See `ChallengeGame.dispute`'s own
    ///       natspec for the full argument.
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
