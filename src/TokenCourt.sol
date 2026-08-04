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

/// @notice The one thing the court needs from the electorate that
///         `IStakedWood` deliberately does not declare: its age floor, to
///         enforce `participationFloorBps < ageFloorBps` (issue #84). Kept
///         local rather than added to the shared interface for the same
///         reason `script/DeployTokenCourt.s.sol`'s own pre-flight carries
///         this exact function locally — widening `IStakedWood` would touch
///         every mock implementing it and quietly weaken
///         `_participationFloor`'s natspec, which leans on `IStakedWood` NOT
///         exposing this parameter as part of why `FLOOR_LOOKBACK` is
///         hardcoded rather than read live.
interface IStakedWoodAgeFloor {
    function ageFloorBps() external view returns (uint256);
}

/**
 * @title TokenCourt
 * @notice Single-layer WOOD-vote adjudication of disputed `ChallengeGame`
 *         challenges. One referral opens one vote window, one tally against
 *         a participation floor produces the verdict. There is no panel, no
 *         appeal, no bad-faith track.
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
 * @dev    THIS COURT'S RESISTANCE TO CAPTURE IS NOW LOAD-BEARING FOR CHALLENGE
 *         ECONOMICS, in a way it was not when slash proceeds funded victim
 *         compensation. Convictions BURN the accused's bond, and burned WOOD
 *         raises every remaining holder's share of the supply — so a
 *         WOOD-heavy party profits from ANY conviction, on top of the
 *         prosecutor's fee, and profits whether or not the accused was
 *         actually guilty.
 *
 *         That turns "can this court be swayed?" from a FAIRNESS question into
 *         a PROFIT question. A holder of fraction `f` of supply collects
 *         `f x burn` per conviction; the larger `f`, the lower the confidence
 *         at which filing against an honest guardian becomes worth trying.
 *         Under the old escrow the same manipulation paid only vault
 *         shareholders, so an attacker had to hold the drained vault's shares
 *         to benefit — a far narrower and more visible position.
 *
 *         Nothing here is broken by that; it raises the assurance this
 *         contract must carry. Treat the participation floor, the vote window,
 *         and the snapshot instant as economic parameters, not just procedural
 *         ones, and re-examine them alongside `ChallengeGame.challengerBondBps`
 *         rather than in isolation (burn-slash-proceeds design.md R4).
 *
 * @dev    NON-UPGRADEABLE, PLAIN `Ownable2Step` — the house shape for
 *         single-owner administrative contracts in this protocol (mirrors
 *         `ChallengeGame`). No UUPS/beacon proxy: the court has no storage
 *         layout to protect across upgrades and no shared implementation to
 *         coordinate, so the upgrade machinery would be pure surface area.
 *
 * @dev    NO PAUSE EXISTS ON THIS CONTRACT. The human backstop for
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
    /// @notice How far BEFORE a case's snapshot the participation floor's
    ///         electorate base is cross-checked. The base is the SMALLER of
    ///         the UNACCUSED electorate at the snapshot and the UNACCUSED
    ///         electorate this long before it — the accused cohort is
    ///         subtracted at BOTH instants, each against the electorate
    ///         measured at that same instant (finding #6) — so stake younger
    ///         than this cannot raise the floor on EITHER side of the min.
    ///         (issue #82) `vote`'s own ballot weight is bounded by the same
    ///         lookback: a caller's raw stake growth over this window gates a
    ///         min against the caller's aged weight this long ago, so the
    ///         numerator and the floor's denominator are measured against the
    ///         same pair of instants — see `vote`'s growth-gated-min @dev
    ///         block.
    /// @dev    A `constant`, NOT an owner parameter, and deliberately so — see
    ///         `_participationFloor` for the full argument. In short: an owner
    ///         setter here would be a lever to shrink the lookback to zero
    ///         immediately before a drain, which is precisely the attack this
    ///         constant closes; and a constant is the strongest possible form
    ///         of the "pin it at `refer`" discipline, since a value that
    ///         cannot change cannot move under a live case at all.
    uint256 public constant FLOOR_LOOKBACK = 30 days;

    /// @notice The wired `IChallengeGame` this court adjudicates for and
    ///         reads challenge state from. Zero while unwired.
    address public challengeGame;
    /// @notice The wired `IStakedWood` electorate source. Zero while unwired.
    address public stakedWood;
    /// @notice The vote window newly referred cases receive. Bounded by
    ///         `MAX_VOTE_WINDOW`; a live case keeps the window it was
    ///         referred under regardless of later changes here.
    uint256 public voteWindow = 5 days;
    /// @notice The anti-capture participation floor, in bps of
    ///         `min(total - accusedWeight, earlier - accusedWeightAtLookback)`
    ///         — each subtraction floored at zero and taken against its OWN
    ///         instant's accused weight before the lookback min — see
    ///         `_participationFloor` for the full lookback-min rationale.
    uint256 public participationFloorBps = 1_000;

    /// @notice Count of cases ever referred. Case ids are 1-indexed.
    uint256 public caseCount;
    mapping(uint256 caseId => ITokenCourt.Case) internal _cases;
    /// @notice The case id referred for a challenge on a given game, or zero
    ///         if none has been.
    /// @dev Keyed by (game, challenge id), not by id alone. `ChallengeGame` is
    ///      non-upgradeable, so redeploying it is the migration path
    ///      (`setChallengeGame`) — but a fresh game's `challengeCount`
    ///      restarts at 0, so its ids collide with every case the old game
    ///      already minted. Single-keying would make every colliding
    ///      challenge revert `AlreadyReferred` forever and time out to
    ///      `_fail`, auto-acquitting the accused and paying it the
    ///      challenger's bond.
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
    /// @dev Guards the wiring itself, same class as `ChallengeGame.setCourt`'s
    ///      own re-wire guard. Re-pointing to a new game is a setter that can
    ///      break the window invariant just like `setVoteWindow` below, and
    ///      the two compose into a bypass if only one is guarded: e.g. this
    ///      court's `setVoteWindow` raises `voteWindow` while unwired (passes
    ///      vacuously — no game to check against yet), then this setter wires
    ///      it to a game whose own clocks cannot fit that window. Checked
    ///      against the new game's own `autoSlashDelay`/`disputeTimeout`, not
    ///      whatever the old `challengeGame` (if any) reported — this setter
    ///      requires non-zero unconditionally, so unlike `ChallengeGame.setCourt`
    ///      there is no vacuous branch to preserve here; every call validates.
    function setChallengeGame(address newGame) external onlyOwner {
        if (newGame == address(0)) revert ZeroAddress();
        IChallengeGame game_ = IChallengeGame(newGame);
        if (game_.autoSlashDelay() + voteWindow + FINALIZE_BUFFER > game_.disputeTimeout()) {
            revert WindowInvariantViolated();
        }
        emit ChallengeGameSet(challengeGame, newGame);
        challengeGame = newGame;
    }

    /// @dev THERE IS NO PATH TO AN OWNERLESS COURT. `Ownable.renounceOwnership`
    ///      would leave `setChallengeGame` / `setStakedWood` /
    ///      `setVoteWindow` / `setParticipationFloorBps` permanently
    ///      unreachable, and this contract is non-upgradeable, so there is no
    ///      recovery afterwards. Those setters are the rescue path for a
    ///      compromised or redeployed dependency — the `_participationFloor`
    ///      docs below lean on the live `participationFloorBps` read as an
    ///      operational lever precisely because a live owner exists to pull
    ///      it, and `ChallengeGame.setCourt(0)`-style escape hatches on the
    ///      other side of the wiring assume the same. `pure`, not `onlyOwner`:
    ///      it is refused for everyone, the owner included, so there is no
    ///      "the owner meant it" branch to get wrong.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /// @inheritdoc ITokenCourt
    /// @dev Guards the wiring itself, same class as `setChallengeGame`'s own
    ///      re-wire guard above. Re-pointing to a new electorate is a setter
    ///      that can break the floor invariant just like
    ///      `setParticipationFloorBps` below, and the two compose into a
    ///      bypass if only one is guarded: e.g. this court's
    ///      `setParticipationFloorBps` raises `participationFloorBps` while
    ///      unwired (passes vacuously — no age floor to check against yet),
    ///      then this setter wires it to an electorate whose own age floor
    ///      that raised value already meets or exceeds. Checked against the
    ///      new sWOOD's own LIVE `ageFloorBps()`, not whatever the old
    ///      `stakedWood` (if any) reported — this setter requires non-zero
    ///      unconditionally, so there is no vacuous branch to preserve here;
    ///      every call validates. A target without `ageFloorBps()` reverts on
    ///      the read (fail-closed) — no real electorate lacks it, since the
    ///      court also needs its `getPastTotalVotes`/`getPastStake`/`getVotes`.
    function setStakedWood(address newStakedWood) external onlyOwner {
        if (newStakedWood == address(0)) revert ZeroAddress();
        if (participationFloorBps >= IStakedWoodAgeFloor(newStakedWood).ageFloorBps()) {
            revert FloorInvariantViolated();
        }
        emit StakedWoodSet(stakedWood, newStakedWood);
        stakedWood = newStakedWood;
    }

    /// @inheritdoc ITokenCourt
    /// @dev Mirrors `ChallengeGame._requireWindowFits`: the cross-contract
    ///      invariant `autoSlashDelay + voteWindow + FINALIZE_BUFFER <=
    ///      disputeTimeout` spans both contracts, so this setter must
    ///      enforce it too, reading the game's LIVE `autoSlashDelay`/
    ///      `disputeTimeout` rather than trusting a stale value. Vacuous with
    ///      no game wired: there is no referral clock to fit yet.
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
    /// @dev Mirrors `setVoteWindow`'s shape: the cross-contract invariant
    ///      `participationFloorBps < ageFloorBps` spans both contracts, so
    ///      this setter enforces it against the wired sWOOD's LIVE
    ///      `ageFloorBps()` rather than trusting a stale value. Vacuous with
    ///      no electorate wired: there is no age floor to compare against
    ///      yet — `setStakedWood` above closes that vacuous branch by
    ///      validating unconditionally on the wiring side.
    ///
    ///      Strictness is strict `<`, not `<=`: `finalize` clears at
    ///      `turnout >= floor`, turnout sums AGED weight bounded below by
    ///      `ageFloorBps/10_000` of raw stake, and the floor's base is RAW
    ///      stake, so the raw-turnout fraction needed to clear is
    ///      `participationFloorBps / ageFloorBps`. At equality that fraction
    ///      is exactly 100% — every un-accused staked wei voting at age
    ///      zero — which is not a liveness guarantee anyone can stand on,
    ///      and is exactly what the deploy pre-flight (`floorBps <
    ///      ageFloorBps`) already rejects; the setter must agree with it.
    ///
    ///      DELIBERATELY NOT GUARDED: `StakedWood.setAgeFloorBps` lowering
    ///      the OTHER side of this pair after the fact. sWOOD is the
    ///      base-layer custodian and holds no pointer back to this court;
    ///      giving it one would invert the dependency direction for a
    ///      court-local liveness property. That lever is covered by the
    ///      wire-time pre-flight and off-chain monitoring, not by this
    ///      setter — see issue #84.
    function setParticipationFloorBps(uint256 newBps) external onlyOwner {
        if (newBps == 0 || newBps > BPS_DENOMINATOR) revert InvalidParameter();
        address sw = stakedWood;
        if (sw != address(0) && newBps >= IStakedWoodAgeFloor(sw).ageFloorBps()) {
            revert FloorInvariantViolated();
        }
        emit ParticipationFloorBpsSet(participationFloorBps, newBps);
        participationFloorBps = newBps;
    }

    /// @inheritdoc ITokenCourt
    /// @dev    THE SNAPSHOT IS COMPUTED HERE, ONCE, AND STORED (decision D2).
    ///         It is `executedAt - 1` — the block before the challenged
    ///         proposal executed. It once had a second consumer, the
    ///         compensation path's apportionment; that is gone with the escrow
    ///         and the instant now serves only to fix THIS court's electorate.
    ///         Storing it rather than re-deriving
    ///         it on every `vote`/`finalize` call is what keeps the electorate
    ///         that judges guilt identical no matter how many blocks pass
    ///         before the window closes, and it means the vote cannot be made
    ///         to disagree with itself about who is entitled to vote — not
    ///         even if the governor's proposal record moved underneath it.
    /// @dev    NOTHING HERE EXTENDS THE CHALLENGE'S OWN CLOCK. `ChallengeGame`
    ///         still fails a disputed challenge to the accused at
    ///         `filedAt + disputeTimeoutAtFiling`, so a referral filed very
    ///         late would leave the vote too little time to reach a verdict.
    ///         Rather than open a case doomed to lose the race, THE CLOCK
    ///         CHECK below refuses to open one at all unless `voteWindow +
    ///         FINALIZE_BUFFER` still fits before the timeout — turning a
    ///         runtime race into a structural impossibility: a case that
    ///         exists is always one that can finish.
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
    /// @dev    THE EXPOSURE LEDGER IS PINNED HERE TOO, under the same
    ///         discipline as `snapshotTs` above and `game` beside it: one read
    ///         of `IChallengeGame.exposureLedger()`, stored in `Case.ledger`
    ///         AND handed to `_recordAccused`, so the accused set and the
    ///         record of where it came from cannot diverge. An owner
    ///         `ChallengeGame.setExposureLedger` call after this point is
    ///         inert for this case — it cannot empty the accused set (which
    ///         would let every real approver vote on its own case), cannot
    ///         zero `accusedWeight`, and so cannot push the participation
    ///         floor to its maximum and compound the denial-of-quorum
    ///         behaviour.
    /// @dev    THE RESIDUAL WINDOW IS FILE→REFER AND STAYS OPEN. A re-point
    ///         made strictly between `ChallengeGame.file` and this call is
    ///         absorbed by the pin rather than blocked by it: the empty
    ///         accused set is what gets pinned, because `refer` is the
    ///         earliest instant the court exists for. Owner-only, and
    ///         recoverable by re-pointing back before `refer`. Closing it
    ///         requires an at-`file` pin inside `ChallengeGame`'s `Challenge`
    ///         struct or a live-challenge guard on `setExposureLedger` — a
    ///         follow-up decision on that contract, deliberately not expanded
    ///         into here. See `_recordAccused` for the full statement.
    function refer(uint256 challengeId) external returns (uint256 caseId) {
        address game = challengeGame;
        address swood = stakedWood;
        // Requires wired: a case can no longer exist before its electorate
        // does.
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

        // `ch.executedAt` is the game's OWN pin: `ChallengeGame` snapshots
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

        // THE LEDGER IS RESOLVED EXACTLY ONCE, here, and every consumer below
        // reads that resolved address rather than the game's live pointer.
        address ledger = IChallengeGameLedger(game).exposureLedger();

        ITokenCourt.Case storage c = _cases[caseId];
        c.challengeId = challengeId;
        c.game = game; // pinned: setChallengeGame afterward must not redirect finalize's rule call
        c.ledger = ledger; // pinned: setExposureLedger afterward must not re-derive this case's accused set
        c.snapshotTs = snapshotTs;
        c.referredAt = block.timestamp;
        c.voteWindowAtReferral = window;
        c.phase = ITokenCourt.Phase.Voting;
        // Pinned from the SAME `ch` memory struct read above for
        // `executedAt` - no second external read. `vote` bars this address
        // exactly like it bars the accused set: a `Guilty` verdict pays the
        // challenger the accused's bond plus the escalated pool
        // (`IChallengeGame._settle`), so an unbarred challenger voting
        // `Guilty` on its own filing would be a self-dealing conviction, not
        // a jury verdict (finding #7).
        c.challenger = ch.challenger;

        emit CaseReferred(caseId, challengeId, ch.governor, ch.proposalId, snapshotTs);

        // THE ACCUSED SET IS FIXED HERE, under the same rule as the snapshot
        // directly above it. `vote` bars this set from casting a ballot, and
        // the weight recorded below is what the participation floor's base
        // subtracts.
        _recordAccused(caseId, c, ledger, ch.governor, ch.proposalId, snapshotTs);
    }

    /// @inheritdoc ITokenCourt
    /// @dev    DO NOT RE-WEIGHT THE RESULT. `getPastVotes` is documented
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
    ///         stored timestamp. The single-instant snapshot is not the whole
    ///         defence any more, though: stake acquired BEFORE the snapshot
    ///         but still inside the `FLOOR_LOOKBACK` window is priced by the
    ///         growth-gated min below rather than admitted at face value —
    ///         see that block for why the snapshot alone under-priced it
    ///         (issue #82).
    /// @dev    THE GROWTH-GATED MIN (issue #82). The bare snapshot read above
    ///         let WOOD staked one second before a drain vote at
    ///         `ageFloorBps` of raw (25% at deployed values) — enough,
    ///         combined with the accused's own non-participation, to buy a
    ///         tie (`NotGuilty`) for the cost of ~`FLOOR_LOOKBACK` of capital
    ///         lock. The fix: with `lookbackTs = snapshotTs > FLOOR_LOOKBACK
    ///         ? snapshotTs - FLOOR_LOOKBACK : 0`, `rawNow =
    ///         getPastStake(caller, snapshotTs)` and `rawThen =
    ///         getPastStake(caller, lookbackTs)`, the ballot is `min(weightNow,
    ///         weightThen)` when `rawNow > rawThen` (STRICT) AND an electorate
    ///         existed at the lookback (`getPastTotalVotes(lookbackTs) != 0`);
    ///         otherwise it is the unclamped `weightNow`, bit-identical to
    ///         today.
    ///         GATE ON RAW, CLAMP ON WEIGHT — deliberate asymmetry, not a
    ///         shortcut. Age growth without raw growth is pure aging:
    ///         legitimate by construction, since age cannot be acquired
    ///         inside the window without capital that was already present a
    ///         full lookback before the snapshot. Raw growth is the only
    ///         observable that isolates the attack vector (capital arriving
    ///         inside the window) from that legitimate aging. Gating on
    ///         WEIGHT growth instead would fire on every steady, merely-aging
    ///         position too (aging always grows weight below par) and
    ///         collapse back into an unconditional min that re-taxes the
    ///         honest 30-to-60-day cohort — a shape already tried and
    ///         rejected (openspec/changes/fix-ballot-growth-lookback,
    ///         variant 2a).
    ///         THE ADVERSARY: an address that stakes (or tops up) inside
    ///         `FLOOR_LOOKBACK` before a drain it intends to vote on.
    ///         `rawThen = 0` for a fresh address forces the gate true
    ///         unconditionally and `weightThen = 0 x anything / 10_000 = 0`
    ///         — zero raw times any age multiplier is zero — so the ballot
    ///         is refused outright (`NoVotingPower`). A partial pre-existing
    ///         position of size `P` topped up at drain time still has
    ///         `rawThen = P`, still gates true for any top-up size, and the
    ///         ballot is bounded by `weightThen <= P`'s month-ago aged worth
    ///         — the top-up buys nothing.
    ///         STRICT `>` CLOSES THE SHRINK CASE: a position whose raw stake
    ///         held or fell over the window never has the clamp evaluate at
    ///         all (the total read short-circuits away too), so it is never
    ///         handed the larger historical figure it did not earn.
    ///         THE BOOTSTRAP FALLBACK is keyed on the TOTAL electorate at the
    ///         lookback (`getPastTotalVotes(lookbackTs) == 0`), never on the
    ///         caller's own `rawThen`/`weightThen` — a per-caller fallback
    ///         would re-admit exactly the fresh-whale ballot this clamp
    ///         exists to remove, since a zero lookback position is the
    ///         attack's own signature. Mirrors `_participationFloor`'s own
    ///         zero-lookback-electorate fallback (`earlier == 0`, which
    ///         forces `earlierReduced == 0` too — see that function) below
    ///         for the identical reason:
    ///         without it, every case referred inside the protocol's first
    ///         `FLOOR_LOOKBACK` of staking history would be unvotable by
    ///         anyone, a guaranteed `Inconclusive`.
    /// @dev    RESIDUALS — WHAT THE GATE DOES AND DOES NOT CLOSE. (1) Dormant
    ///         capital parked AT OR BEFORE `lookbackTs` gates false and votes
    ///         its full unclamped aged weight — at deployed values (lookback
    ///         = maturation = 30 days) that is PAR. This is the direct price
    ///         of not taxing the honest steady cohort: the gate cannot
    ///         distinguish premeditated month-old capital from an honest
    ///         month-old guardian, they are on-chain identical. Counter-levers
    ///         are unchanged: the stake is public and idle for a full month
    ///         before the drain it exists to protect, and a ballot still has
    ///         to WIN against honest turnout. (2) A one-second boundary cliff
    ///         at exactly `lookbackTs` is inherent to any two-point rule
    ///         (parked at `lookbackTs` votes at par; parked one second later
    ///         gates true and votes zero) and cuts AGAINST the attacker, not
    ///         for it. (3) The touch-stake residual (stake before
    ///         `lookbackTs`, unstake mid-window, re-stake at drain time) is
    ///         UNCHANGED: `rawNow == rawThen` gates false, and the re-stake's
    ///         forward re-anchor discounts `weightNow` to `ageFloorBps` of raw
    ///         on its own, with no help from the clamp. Closing either
    ///         residual needs a true windowed minimum over the checkpoint
    ///         trace (gas-unbounded) or new state; out of scope here,
    ///         documented rather than hidden.
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
    /// @dev    NOR MAY THE PROSECUTOR (finding #7) — the same inversion from
    ///         the opposite side. `AccusedCannotVote` and
    ///         `ChallengerCannotVote` are two halves of one rule: neither
    ///         party with a direct payout riding on the verdict may cast a
    ///         ballot on it. Without this bar a challenger could self-fund a
    ///         majority with as little as `participationFloorBps` of the
    ///         unaccused electorate (10% at deployed values, and LESS the
    ///         more approvers its own filing names, since the floor's base is
    ///         `total - accusedWeight`) and be paid the accused's bond by its
    ///         own vote.
    /// @dev    OPEN LIMITATION: THE BAR IS ON THE APPROVING ADDRESS, NOT THE
    ///         PARTY BEHIND IT. `isAccused` is
    ///         built from the ledger's approver list — addresses — and
    ///         permissionless staking means one economic actor can approve
    ///         (and back coverage for) the same proposal from several
    ///         addresses, or route the drain's benefit to an address that
    ///         never approved at all. Splitting across addresses defeats the
    ///         bar outright: none of the beneficiary's other addresses are in
    ///         the accused set, so they vote freely. The floor mechanics make
    ///         this worse, not neutral: `_participationFloor` subtracts the
    ///         accused set's raw stake from each side's own-instant total,
    ///         same-instant on both, and clamps each subtraction at zero, so
    ///         once the REDUCED branch binds (`total - accusedWeight <=
    ///         earlier - accusedWeightAtLookback`), every address the
    ///         accused set DOES name shrinks the floor the siblings'
    ///         un-accused addresses must clear to carry the vote — all the
    ///         way down to a floor of zero once the named cohort covers the
    ///         base. (While the EARLIER-REDUCED branch binds instead, naming
    ///         an address that already held stake at the LOOKBACK instant
    ///         shrinks `accusedWeightAtLookback` the same way — lowering
    ///         `earlierReduced` — but naming one that only acquired stake
    ///         inside the lookback window moves `accusedWeightAtLookback` not
    ///         at all, since that read is fixed to the past; see the lookback
    ///         rationale below.) In neither branch does a larger accused
    ///         cohort ever raise the bar the remaining electorate must clear —
    ///         it only lowers or holds it, once it moves the floor at all.
    ///         This is
    ///         likely unfixable under permissionless staking (there is no
    ///         on-chain notion of
    ///         "the same party"); the natspec must not claim the bar covers a
    ///         defendant or a party — only that it covers the specific
    ///         addresses the ledger already named as approvers.
    /// @dev    NO VOTE CHANGES. `AlreadyVoted` refuses a second call from
    ///         the same address outright rather than accepting the latest one
    ///         — there is no path to change a cast vote, only to be refused a
    ///         second one.
    /// @dev    THE WINDOW IS THE CASE'S PINNED `voteWindowAtReferral`, never
    ///         the live `voteWindow` — see that field's own rationale: a
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
    /// @dev    PRESENT HOLDINGS ARE A GATE, NEVER A WEIGHT. Historical weight
    ///         still decides how much a vote counts — that is the flash-loan
    ///         defence above, and it is unchanged. This decides only WHETHER
    ///         the caller may vote at all — you must be an active guardian
    ///         (present stake, no
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
    ///         exactly the 25%-of-historic-weight shape described above, now
    ///         costing `minGuardianStake` instead of nothing — a residual
    ///         bounded by that cost, not eliminated. That is the inherent
    ///         shape of a binary gate, not a bug in it. THE GROWTH-GATED MIN
    ///         ABOVE DOES NOT CLOSE THIS: a full unstake-then-re-stake of the
    ///         same amount reads `rawNow == rawThen` at the two lookback
    ///         instants (the re-stake happened after `lookbackTs` in the
    ///         attack's own timeline), so the gate is false and the
    ///         `ageFloorBps` discount comes entirely from `weightNow`'s own
    ///         re-anchor, with no help from the clamp either way (issue #82
    ///         design §6, "touch-stake" residual).
    ///         Re-WEIGHTING on present holdings would reintroduce the
    ///         post-hoc accumulation the snapshot exists to close, so this
    ///         stays binary.
    function vote(uint256 caseId, bool guilty) external {
        ITokenCourt.Case storage c = _cases[caseId];
        if (c.phase != ITokenCourt.Phase.Voting) revert WrongPhase();
        if (block.timestamp >= c.referredAt + c.voteWindowAtReferral) revert WindowClosed();
        if (voteOf[caseId][msg.sender] != ITokenCourt.Ruling.None) revert AlreadyVoted();
        if (isAccused[caseId][msg.sender]) revert AccusedCannotVote();
        // THE PROSECUTOR MAY NOT VOTE EITHER (finding #7). `AccusedCannotVote`
        // bars the defendant; nothing barred the challenger, even though a
        // `Guilty` verdict pays `c.challenger` the accused's bond plus the
        // escalated pool (`IChallengeGame._settle`'s escalated branch) - an
        // unbarred challenger voting `Guilty` on its own filing is a
        // self-dealing conviction, not a jury verdict, and the floor's own
        // `total - accusedWeight` shape makes a unilateral conviction easier
        // the more approvers the challenge names, not harder. `c.challenger`
        // is pinned once in `refer` from the same `Challenge` memory struct
        // read there for `executedAt` - see that pin's own rationale.
        if (msg.sender == c.challenger) revert ChallengerCannotVote();

        IStakedWood swood = IStakedWood(stakedWood);
        uint256 weight = swood.getPastVotes(msg.sender, c.snapshotTs);
        // GROWTH-GATED MIN — see the @dev block above `vote` (issue #82).
        // Gate on RAW stake growth over `FLOOR_LOOKBACK`, strict `>`; clamp
        // on the finished AGED weights. Gate first in the `&&` so the
        // lookback-total read short-circuits away for every non-growth
        // voter (the perpetual steady majority never pays for it).
        uint256 lookbackTs = c.snapshotTs > FLOOR_LOOKBACK ? c.snapshotTs - FLOOR_LOOKBACK : 0;
        if (
            swood.getPastStake(msg.sender, c.snapshotTs) > swood.getPastStake(msg.sender, lookbackTs)
                && swood.getPastTotalVotes(lookbackTs) != 0
        ) {
            uint256 weightThen = swood.getPastVotes(msg.sender, lookbackTs);
            if (weightThen < weight) weight = weightThen;
        }
        if (weight == 0) revert NoVotingPower();
        // Present-holdings gate — see the @dev block above `vote`.
        if (swood.getVotes(msg.sender) == 0) revert NoPresentHoldings();

        voteOf[caseId][msg.sender] = guilty ? ITokenCourt.Ruling.Guilty : ITokenCourt.Ruling.NotGuilty;
        if (guilty) {
            c.guiltyVotes += weight;
        } else {
            c.notGuiltyVotes += weight;
        }

        emit VoteCast(caseId, msg.sender, guilty, weight);
    }

    /// @inheritdoc ITokenCourt
    /// @dev    THE VERDICT TABLE, and why each branch fails safe:
    ///         - `turnout == 0 || turnout < floor` -> `Inconclusive`. This is a
    ///           NON-EVENT that unwinds both sides — the accused's
    ///           counter-bond whole, the challenger's bond minus the escalating
    ///           Inconclusive burn (`IChallengeGame._refundAll`) — never an
    ///           acquittal-with-forfeit: neither side
    ///           pays the OTHER. A thin or absent
    ///           vote answers nothing about guilt, so it must not be read as an
    ///           answer in either direction — the anti-capture floor exists
    ///           precisely so a small, possibly rented, stake cannot manufacture
    ///           either a conviction or a clean acquittal by being the only
    ///           voice in the room.
    ///         - `guiltyVotes > notGuiltyVotes` -> `Guilty`. A STRICT majority is
    ///           required, not a plurality — see the next branch.
    ///         - otherwise (a tie included) -> `NotGuilty`. A tie carries no
    ///           ground truth either way; failing it to `NotGuilty` rather than
    ///           `Guilty` is deliberate, because `Guilty` triggers a 100%-style
    ///           slash (`IChallengeGame.rule`) and an even vote is the worst
    ///           possible basis for destroying stake. THIS BRANCH STANDS ON
    ///           THAT ARGUMENT ALONE, not on any enum-ordering coincidence: the
    ///           zero value of `IChallengeGame.Verdict` is `Inconclusive`
    ///           (`{Inconclusive, NotGuilty, Guilty}`), NOT `NotGuilty`, so a
    ///           tie deliberately resolves to a DIFFERENT value than an
    ///           uninitialised `Verdict` would. Every branch above assigns
    ///           `verdict` explicitly; nothing here relies on a default.
    /// @dev    STATE IS CLOSED BEFORE THE EXTERNAL CALL, and the `rule` call is
    ///         wrapped in try/catch. Between
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
    ///         challenge is still `Disputed` and fully rulable, an unwired
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
    /// @dev    OPEN LIMITATION: LAST-MOVER ADVANTAGE IS UNMITIGATED. Every
    ///         vote is visible on-chain the instant it lands (`VoteCast`), the
    ///         deadline is hard (`referredAt + voteWindowAtReferral`), and a
    ///         TIE ACQUITS (`NotGuilty`, see the verdict table above) — so the
    ///         acquitting side only has to MATCH the guilty tally in the
    ///         final block, not exceed it, while the guilty side must move
    ///         first to be seen at all. Public tallies mean nothing is
    ///         learned by waiting except everyone else's position, so the
    ///         rational strategy for a well-funded acquittal is to hold votes
    ///         back and land exactly enough weight after the last honest vote
    ///         to tie or win, with no window left for a response: a tally
    ///         that moves decisively in the final hour of the vote window is
    ///         what a bought vote looks like. The mitigation short of
    ///         commit-reveal is a vote-extension (any late vote pushes the
    ///         deadline out), which this contract deliberately does not
    ///         implement.
    function finalize(uint256 caseId) external {
        ITokenCourt.Case storage c = _cases[caseId];
        if (c.phase != ITokenCourt.Phase.Voting) revert WrongPhase();
        if (block.timestamp < c.referredAt + c.voteWindowAtReferral) revert WindowOpen();

        uint256 guiltyVotes = c.guiltyVotes;
        uint256 notGuiltyVotes = c.notGuiltyVotes;
        uint256 turnout = guiltyVotes + notGuiltyVotes;
        uint256 floor = _participationFloor(c.snapshotTs, c.accusedWeight, c.accusedWeightAtLookback);

        IChallengeGame.Verdict verdict;
        if (turnout == 0 || turnout < floor) {
            verdict = IChallengeGame.Verdict.Inconclusive;
        } else if (guiltyVotes > notGuiltyVotes) {
            verdict = IChallengeGame.Verdict.Guilty;
        } else {
            verdict = IChallengeGame.Verdict.NotGuilty; // tie fails safe
        }

        // Terminal before the external call: a swallowed WrongStatus below is
        // bookkeeping, not stranded funds, with zero custody. Everything else
        // - NotCourt included - bubbles and reverts these writes too.
        c.verdict = verdict;
        c.finalizedAt = block.timestamp;
        c.phase = ITokenCourt.Phase.Resolved;
        emit CaseFinalized(caseId, verdict, guiltyVotes, notGuiltyVotes, floor);

        try IChallengeGame(c.game).rule(c.challengeId, verdict) {}
        catch (bytes memory reason) {
            // SWALLOW ONLY `WrongStatus` - the one revert that genuinely means
            // "there is nothing left to rule": once `refer` has succeeded a
            // challenge can only leave `Disputed` by going terminal, which is
            // the race this catch exists for.
            //
            // `NotCourt` does NOT mean that. It means the game was re-pointed
            // away while the challenge is STILL `Disputed` and fully rulable,
            // so swallowing it closes the case with a verdict recorded and
            // undelivered - and re-wiring cannot redeliver it, because `refer`
            // reverts `AlreadyReferred`. The challenge then times out and
            // acquits, paying the accused the challenger's forfeited bond. It
            // is transient and retryable, so it bubbles with everything else.
            bytes4 sel = reason.length >= 4 ? bytes4(reason) : bytes4(0);
            if (sel != IChallengeGame.WrongStatus.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
            emit ChallengeAlreadyTerminal(caseId, c.challengeId);
        }
    }

    /// @dev THE FLOOR'S BASE IS `min(earlierReduced, reduced)`, where
    ///      `reduced = max(0, total - accusedWeight)` and
    ///      `earlierReduced = max(0, earlier - accusedWeightAtLookback)` —
    ///      EVERY subtraction is same-instant: `total` and `accusedWeight`
    ///      are reduced against EACH OTHER at `snapshotTs`, and, SEPARATELY,
    ///      `earlier` and `accusedWeightAtLookback` are reduced against each
    ///      other at `snapshotTs - FLOOR_LOOKBACK`; only the two
    ///      already-reduced, same-instant results are then subjected to the
    ///      lookback min below. `accusedWeight`/`accusedWeightAtLookback` sum
    ///      `getPastStake` over the accused set at `snapshotTs`/its lookback
    ///      respectively, the exact same raw-own-stake basis
    ///      `getPastTotalVotes` sums over the whole electorate — so every
    ///      subtraction compares the same measure of the same WOOD at the
    ///      same timestamp.
    ///
    ///      TWO DISTINCT BUGS WERE FOUND IN EARLIER REVISIONS OF THIS
    ///      SUBTRACTION, and both taught the same lesson — same-instant or
    ///      nothing:
    ///        (1) `#96`: subtracting `accusedWeight` from `min(earlier,
    ///            total)` rather than from `total` alone mixed two
    ///            timestamps — in a growing protocol, "the accused today"
    ///            routinely exceeds "the whole electorate a month ago" with
    ///            no attacker action at all, which read as `base == 0` and
    ///            collapsed the floor to nothing while a large, honest,
    ///            unaccused electorate stood by unable to move it.
    ///        (2) finding #6: the #96 fix corrected (1) but left `earlier`
    ///            itself un-reduced by ANY accused-weight term — only
    ///            `reduced` subtracted the accused cohort, so `earlier` and
    ///            `reduced` were not the same KIND of number, and an
    ///            attacker could choose which one bound the min by staking
    ///            large from a never-approving address at `snapshotTs`:
    ///            that raises `total` (and so `reduced`) without moving
    ///            `earlier` at all, which can flip the min from the
    ///            (small, accused-reduced) `reduced` term to the (large,
    ///            un-reduced) `earlier` term — inflating the floor past what
    ///            the honest unaccused electorate could ever reach.
    ///            `accusedWeightAtLookback` closes it by giving `earlier` the
    ///            same same-instant reduction `reduced` already had.
    /// @dev BOTH CLAMPS ARE DEFENCE-IN-DEPTH, NOT A LIVE BRANCH:
    ///      `accusedWeight` sums `getPastStake` over the accused set, which
    ///      is a SUBSET of the addresses `total` (`getPastTotalVotes`) sums,
    ///      read from the same source at the same instant `snapshotTs` — a
    ///      subset-sum of `total` cannot exceed `total`, so
    ///      `accusedWeight <= total` holds structurally under one
    ///      consistently-wired `StakedWood`. `max(0, total - accusedWeight)`
    ///      never actually clamps in normal operation; it exists for the one
    ///      path that could desynchronize the subset relationship — a
    ///      `setStakedWood` re-point landing between the two reads, so
    ///      `accusedWeight` and `total` briefly come from different sources.
    ///      The SAME argument holds one lookback instant earlier:
    ///      `accusedWeightAtLookback` sums `getPastStake` over the identical
    ///      accused set at `snapshotTs - FLOOR_LOOKBACK`, a subset of what
    ///      `earlier` (`getPastTotalVotes` at that same instant) sums, so
    ///      `accusedWeightAtLookback <= earlier` holds by the same structural
    ///      argument and `max(0, earlier - accusedWeightAtLookback)` is, in
    ///      normal operation, likewise a clamp that never fires.
    ///      MONOTONICITY HOLDS, BUT NOT VIA STAKING: an accused approver
    ///      cannot lower the base by staking more, because staking raises
    ///      `total` by exactly the same amount it raises `accusedWeight`
    ///      (the staked address's balance is counted in both, being a member
    ///      of the subset) — so `total - accusedWeight` is unchanged, and
    ///      there is no "buy a forced `Inconclusive` for one extra wei of
    ///      stake" attack. What IS monotone non-increasing is the base as a
    ///      function of WHO is named accused: naming one more address as
    ///      accused (a structural act by the challenge, at `_recordAccused`,
    ///      not a staking action) can only remove that address's already-
    ///      staked balance from `total - accusedWeight`, never add to it.
    ///
    ///      A ZERO FLOOR IS SAFE HERE, and — unlike the earlier revision —
    ///      that claim is now TRUE rather than merely asserted: because the
    ///      subtraction is same-instant, `base == 0` if and only if
    ///      `accusedWeight >= total`, i.e. the accused genuinely ARE the
    ///      entire snapshot electorate. `finalize`'s `turnout == 0` check
    ///      sits ahead of the `turnout < floor` comparison and forces
    ///      `Inconclusive` on a silent electorate no matter what this
    ///      returns, so a zero floor can never let a zero-turnout case
    ///      resolve on the merits — and when it is non-zero-but-thin AND the
    ///      REDUCED branch binds (`reduced <= earlierReduced`), the single
    ///      unaccused voter it admits is genuinely the entire unaccused
    ///      electorate at `snapshotTs`, not an artifact of comparing stake at
    ///      two different timestamps. When the EARLIER-REDUCED branch binds
    ///      instead (`earlierReduced < reduced`), the floor is a month-old
    ///      value too — but, since finding #6, it is the month-old UNACCUSED
    ///      electorate (`earlier - accusedWeightAtLookback`), not the bare
    ///      month-old total: it IS related to who was unaccused, just at the
    ///      lookback instant rather than today's. That is the lookback
    ///      trading precision for anti-inflation, not a claim about who is
    ///      currently in the room.
    /// @dev THE BASE IS THE MIN OVER A LOOKBACK, OF TWO ACCUSED-REDUCED
    ///      READS, NOT ONE. The snapshot defends the NUMERATOR: vote weight
    ///      is read at `executedAt - 1`, so post-drain buyers and flash loans
    ///      count for nothing. The DENOMINATOR had the opposite exposure
    ///      profile, and a single `getPastTotalVotes(snapshotTs)` read minus
    ///      same-instant `accusedWeight` was wide open to it: the base is
    ///      RAISED by anyone staked BEFORE `executedAt` FROM A NEVER-APPROVING
    ///      ADDRESS, and the attacker is exactly the party who knows when
    ///      `executedAt` will be, because it is their own drain.
    ///
    ///      The attack the two-sided min closes: stake large from an address
    ///      that never approves anything, immediately before executing the
    ///      malicious proposal. `StakedWood.stakeAsGuardian` is
    ///      permissionless — no registry gate, no cap, only a
    ///      `minGuardianStake` floor — and `_recordAccused` subtracts only
    ///      LEDGER APPROVERS, so that stake is never subtracted back out of
    ///      `reduced`. With `E` the honest electorate's raw stake and `f` the
    ///      turnout achievable after age-weighting, denial needs only
    ///      `X > (10f - 1) * E` (roughly `2E` at `f ~ 0.3` and the default
    ///      10% floor) to put `reduced` beyond ANY achievable turnout.
    ///      `finalize` then returns `Inconclusive` — no slash, no `_convicted`
    ///      mark, no adapter demotion, counter-bond returned whole, coverage
    ///      freeze released — and the attacker never voted, never coordinated,
    ///      and is never slashable (`slashVerdict` only ever touches the
    ///      approver array), recovering its capital after the cooldown.
    ///
    ///      THIS IS NOT THE ALREADY-ACCEPTED ADDRESS-SPLITTING RISK, which is
    ///      accepted purely as helping siblings WIN a vote (`NotGuilty`, on
    ///      the merits, needing voters). Moving stake OUT of the accused set
    ///      is simultaneously a DENIAL-OF-QUORUM lever
    ///      needing no voters at all, and it lands on `Inconclusive` rather
    ///      than `NotGuilty` — a different outcome with a different unwind.
    ///
    ///      FINDING #6 — WHY `reduced` ALONE WAS NOT ENOUGH. Taking the min
    ///      of `reduced` with the BARE `earlier` (the pre-fix shape) did not
    ///      close the attack above; it only relocated it. `earlier` carried
    ///      no accused subtraction at all, so it was a DIFFERENT KIND of
    ///      number than `reduced` — and the min between an accused-reduced
    ///      quantity and a non-reduced one is not a floor on "unaccused
    ///      turnout a month apart", it is whichever of the two the attacker
    ///      makes smaller. The same fresh, never-approving stake `X` that
    ///      inflates `reduced` above `earlier` (by raising `total` alone)
    ///      flips the min to `earlier` — a term the attack does NOT need to
    ///      touch at all, because `earlier` was never reduced by the accused
    ///      cohort in the first place. So the natspec claim that "an
    ///      inflating stake must sit on-chain, visible and idle, for a month"
    ///      was FALSE under that shape: `X` never had to appear in `earlier`,
    ///      only to move `reduced` far enough to change which term the min
    ///      selects — turnout then had to clear a floor sized off the WHOLE
    ///      month-old electorate, unreachable once the honest cohort is a
    ///      minority of it. `accusedWeightAtLookback` fixes this by giving
    ///      `earlier` the identical same-instant reduction `reduced` already
    ///      had, so BOTH terms of the min are now "unaccused electorate at an
    ///      instant" — the same kind of number — and an attacker's fresh
    ///      stake can inflate at most one of the two terms without also
    ///      appearing (and being reduced) in the other. Reading two extra
    ///      immutable historical checkpoints (`earlier`,
    ///      `accusedWeightAtLookback`) costs staticcalls, not new state.
    /// @dev WHY THE MIN AND NOT THE EARLIER-REDUCED READ ALONE. The min is
    ///      what makes the defence one-directional. Reading only
    ///      `earlierReduced` would let an attacker stake before
    ///      `snapshotTs - FLOOR_LOOKBACK` and `requestUnstakeGuardian` after
    ///      it — inflating the base while holding the capital for a fraction
    ///      of the window — and would also raise the floor whenever the
    ///      electorate legitimately SHRANK over the month. The min can only
    ///      ever lower the base relative to today's behaviour, which is the
    ///      safe direction for the one property that must hold: a pre-drain
    ///      staker must not be able to push the floor out of reach.
    /// @dev WHY 30 DAYS. It is the maturation horizon the NUMERATOR already
    ///      uses: `StakedWood._ageFactorBps` ramps a stake's vote weight from
    ///      `ageFloorBps` to par linearly over `maturationPeriod`, whose
    ///      deployed value is 30 days (bounded [7, 90]). `min(total(t),
    ///      total(t - 30 days))` is a conservative global proxy for "raw stake
    ///      that has been staked at least 30 days", so the denominator now
    ///      admits stake on the same maturity horizon the numerator weights it
    ///      on, instead of admitting day-old stake at full value. It is also
    ///      comfortably longer than a full `SyndicateGovernor` proposal
    ///      lifecycle, so an attacker cannot wait until their proposal is
    ///      already certain to execute before committing the capital: the
    ///      stake must be down before the proposal is even filed.
    ///      Hardcoded rather than read live off `StakedWood.maturationPeriod`
    ///      deliberately — a live read would hand a second contract's owner a
    ///      lever to shrink this court's lookback to 7 days, and `IStakedWood`
    ///      does not expose the parameter anyway.
    /// @dev THE ZERO FALLBACK, AND THE ONE RESIDUAL IT LEAVES. When the
    ///      lookback instant predates the FIRST guardian stake ever
    ///      (`getPastTotalVotes` returns 0 — checkpoint traces read zero
    ///      before their first entry, so `earlier == 0` and, necessarily,
    ///      `accusedWeightAtLookback == 0` too — nobody, accused or not,
    ///      existed yet) there is no earlier electorate to compare against,
    ///      and the code falls back to `reduced` — the same-instant,
    ///      already-accused-reduced value — rather than to a base of zero.
    ///      `snapshotTs < FLOOR_LOOKBACK` (a proposal executing in the
    ///      chain's first month) clamps the lookback instant to 0 and lands
    ///      in the same branch, which is also what keeps both subtractions
    ///      from underflowing. The fallback is keyed on `earlierReduced == 0`
    ///      exactly, and that condition is true in bootstrap (`0 - 0 == 0`)
    ///      whether or not it is ALSO true in the non-bootstrap edge case
    ///      where the accused happened to be the entire lookback electorate
    ///      (`accusedWeightAtLookback >= earlier > 0`) — either way the
    ///      fallback lands on `reduced`, never on a bare, un-reduced
    ///      `earlier`.
    ///
    ///      Falling back to ZERO would be the wrong failure. It would disable
    ///      the anti-capture floor outright for the protocol's first
    ///      `FLOOR_LOOKBACK` of staking history, letting a single dust-weight
    ///      guardian carry a case alone — and a wrongful `Guilty` destroys an
    ///      honest guardian's entire stake, which is strictly more destructive
    ///      than the forced `Inconclusive` the fallback leaves possible.
    ///      Falling back to `reduced` during bootstrap never produces a
    ///      higher floor than the ordinary min-based branch would elsewhere,
    ///      because `reduced` is always one of the two operands the min would
    ///      have chosen from anyway. The residual is the bootstrap window
    ///      only, it shrinks to nothing once the protocol has a month of
    ///      stake history, and it is the period in which TVL — and therefore
    ///      the payoff for denying a verdict — is smallest.
    /// @dev THE ACCUSED'S OWN TOP-UP IS ALREADY NEUTRAL, WITH OR WITHOUT THE
    ///      MIN: an accused approver topping up its stake just before the
    ///      drain raises `total` and `accusedWeight` together, by the same
    ///      amount, so `total - accusedWeight` (`reduced`) — and therefore the
    ///      base — is unchanged regardless of which branch binds; `earlier`
    ///      and `accusedWeightAtLookback` are historical checkpoint reads a
    ///      present-tense top-up cannot touch at all. A NON-approving sibling
    ///      address topping up NOW raises only `total`, which raises `reduced`
    ///      immediately, with no lookback delay, WHENEVER THE REDUCED BRANCH
    ///      BINDS. The min only withholds that immediate effect while the
    ///      EARLIER-REDUCED branch still binds — in that regime alone, a
    ///      same-block top-up moves the base by nothing unless it was already
    ///      staked (and, if by an accused approver, already counted in
    ///      `accusedWeightAtLookback`) a month earlier.
    /// @dev THE FLOOR READS THE LIVE `participationFloorBps`, DELIBERATELY NOT
    ///      PINNED per-case. This is the opposite choice from `snapshotTs` and
    ///      `voteWindowAtReferral`, which ARE pinned at `refer` — and the
    ///      difference is deliberate, not an oversight carried over from that
    ///      pattern. `snapshotTs`/`voteWindowAtReferral` are pinned because a
    ///      live re-read would let the owner move a case's electorate or clock
    ///      out from under a vote already in progress. The participation floor
    ///      has no such hazard: it is read exactly once, at `finalize`, after
    ///      voting has already closed — there is no window during which a
    ///      change to it could retroactively alter anyone's cast ballot. This
    ///      is by design: a floor change is meant to apply to any case
    ///      finalizing after it takes effect, including one already `Voting`
    ///      when the owner adjusts it.
    /// @dev  THE LIVE READ ALSO MEANS the owner can, by raising
    ///       `participationFloorBps` before a pending `finalize`, push a live
    ///       case that would otherwise have cleared the floor down into
    ///       `Inconclusive` instead. Accepted for the same reason above, but
    ///       NOT MONEY-NEUTRAL: `IChallengeGame._refundAll` burns a slice of
    ///       the challenger's bond on the `Inconclusive` path. The lever
    ///       still cannot MANUFACTURE a conviction or an acquittal it did not
    ///       earn, and it still moves nothing to the accused or to the owner
    ///       — but forcing a live case into `Inconclusive` instead of the
    ///       `Guilty`/`NotGuilty` verdict it would otherwise have reached
    ///       destroys a real slice of the challenger's bond that a clean
    ///       verdict would not have (a `Guilty` verdict returns the bond
    ///       WHOLE; only the forced `Inconclusive` burns any of it). The
    ///       magnitude is small and itself bounded — the same escalating
    ///       schedule that prices every other `Inconclusive` unwind, capped
    ///       well below what a real verdict recovers — but it is destroyed
    ///       value, not a neutral withholding, and the owner is trusted not
    ///       to use this lever that way for the same reason the owner is
    ///       trusted with every other live-read parameter in this contract
    ///       family.
    /// @dev  `stakedWood` IS LIKEWISE READ LIVE HERE, not pinned per-case: this
    ///       `total`/`earlier` come from whichever contract `stakedWood` names
    ///       at `finalize` time, while `accusedWeight`/`accusedWeightAtLookback`
    ///       were already fixed against whatever `stakedWood` named back at
    ///       `refer`, and the votes summed into `guiltyVotes`/`notGuiltyVotes`
    ///       were weighed against whatever it named at each `vote` call. A
    ///       `setStakedWood` re-point between `vote` and `finalize` therefore
    ///       changes the floor's basis to a different contract's checkpoints
    ///       than the ones the cast votes were weighed against. Accepted for
    ///       the same reason the game's own wiring setters
    ///       (`setChallengeGame`, `setStakedWood`) stay live rather than
    ///       pinned per-case: they are the owner's rescue path for a
    ///       compromised or upgraded dependency, and the owner is trusted.
    ///       Flagged here as a deliberately deferred hazard, not an oversight.
    function _participationFloor(uint256 snapshotTs, uint256 accusedWeight, uint256 accusedWeightAtLookback)
        internal
        view
        returns (uint256)
    {
        IStakedWood swood = IStakedWood(stakedWood);
        uint256 total = swood.getPastTotalVotes(snapshotTs);
        // Clamped, never subtracted below zero: a proposal executing in the
        // chain's first `FLOOR_LOOKBACK` reads the trace at 0, which is empty
        // by definition and lands in the `earlierReduced == 0` fallback below.
        uint256 lookbackTs = snapshotTs > FLOOR_LOOKBACK ? snapshotTs - FLOOR_LOOKBACK : 0;
        uint256 earlier = swood.getPastTotalVotes(lookbackTs);
        // SAME-INSTANT SUBTRACTION, THEN THE LOOKBACK MIN — order matters,
        // and it now applies IDENTICALLY on both sides of the min (finding
        // #6). `accusedWeight` is always measured at `snapshotTs`, and
        // `accusedWeightAtLookback` is the SAME accused set measured at
        // `lookbackTs` — each is subtracted from the total taken at its OWN
        // instant, never cross-instant. Subtracting a same-instant
        // `accusedWeight` from a 30-day-old `earlier` (or not subtracting
        // anything from `earlier` at all) compares two different instants:
        // in a growing protocol, "the accused today" routinely exceeds "the
        // whole electorate a month ago" with no attacker action at all
        // (issue #96), and leaving `earlier` un-reduced let a fresh,
        // never-approving stake at `snapshotTs` inflate `reduced` past
        // `earlier` and flip the min to the un-reduced term instead (finding
        // #6) — collapsing the floor's protection either way, by feeding the
        // min two operands that were not the same kind of number. Reducing
        // each `total` against its OWN instant's accused weight first keeps
        // every operand answering the same question — "how much of THIS
        // instant's electorate is unaccused" — before the lookback min ever
        // compares them.
        uint256 reduced = total > accusedWeight ? total - accusedWeight : 0;
        uint256 earlierReduced = earlier > accusedWeightAtLookback ? earlier - accusedWeightAtLookback : 0;
        // The smaller of the two UNACCUSED electorates, EXCEPT when there is
        // no earlier electorate at all to compare against
        // (`earlierReduced == 0`), in which case the same-instant reduction
        // stands — see the fallback rationale above for why zero is the
        // wrong failure there. `earlierReduced == 0` also covers, harmlessly,
        // the edge case where the accused were themselves the entire
        // lookback electorate (`accusedWeightAtLookback >= earlier > 0`): the
        // fallback to `reduced` is correct there too, since `reduced` is
        // never larger than the min would otherwise have picked.
        //
        // Monotone non-increasing in `accusedWeight` by construction, and it
        // now reaches zero ONLY when the accused genuinely are the entire
        // snapshot electorate (`accusedWeight >= total`) — the one case
        // where `finalize`'s `turnout == 0` guard correctly and truthfully
        // covers an empty room, rather than merely a floor that says nothing
        // about who could have voted.
        uint256 base = (earlierReduced != 0 && earlierReduced < reduced) ? earlierReduced : reduced;
        return participationFloorBps * base / BPS_DENOMINATOR;
    }

    /// @dev THE PREDICATE IS THE PLEDGE, NOT THE LIVE BOOKING (issue #83).
    ///      Both fields sit on the ledger, both are keyed by the same review
    ///      key, and both look like they answer "did this guardian underwrite
    ///      this proposal?". Only one of them is a fact nobody can rewrite
    ///      under a live case:
    ///
    ///        `_reservedUsd`  — THE PLEDGE. `recordApproval` is its only
    ///          writer, `releaseApproval` its only eraser, and a filed
    ///          challenge blocks that eraser outright (`CoverageFrozen`).
    ///          Read here, through `pledgedOf`.
    ///        `_recorded.usd` — THE LIVE BOOKING. `settleCoverage` rewrites
    ///          it in BOTH directions; that call is permissionless,
    ///          re-runnable by design, and deliberately not freeze-gated.
    ///          Read through `approversOf`, which this function used to use.
    ///
    ///      Filtering on the booking put the accused set inside a stranger's
    ///      reach, with no attacker capital and no privileged role. A guardian
    ///      convicted on a SEPARATE, CONCURRENT challenge lands at exactly
    ///      zero own stake (Plan B pre-flights `maxSlashBps == 10_000`, so
    ///      `StakedWood._slashOne` takes the whole live balance). Its
    ///      slashable bond is then zero, so the next `settleCoverage` on THIS
    ///      proposal books it at zero — and anyone may make that call, at any
    ///      time after `executeBy`. The guardian dropped out of the loop
    ///      below, never had `isAccused` set, and walked straight past `vote`'s
    ///      `AccusedCannotVote` bar. Its BALLOT still weighed the full
    ///      pre-slash amount, because `vote` reads `getPastVotes` at
    ///      `c.snapshotTs == executedAt - 1` and checkpoints are append-only —
    ///      an instant no later slash can reach back to. The result was the
    ///      exact inversion this bar exists to prevent: the accused judging,
    ///      at full weight, the case its own approval caused. The pledge is
    ///      immune to every step of it — no conviction, no price move and no
    ///      settlement pass can lower it.
    /// @dev A RELEASED APPROVER IS STILL EXCLUDED, which is what this filter
    ///      was written for, and it survives the change untouched.
    ///      `releaseApproval` zeroes the pledge AND swap-and-pops the guardian
    ///      out of `_approversOf`, so a commitment released before the filing
    ///      is not in the list this loop walks at all. It is NOT reported as a
    ///      zero-share entry — an earlier revision of this comment claimed the
    ///      ledger keeps the full historical set that way, and that has been
    ///      false since the swap-and-pop landed. The zero-check below is kept
    ///      as the belt to that brace: filtering on one predicate rather than
    ///      on list membership costs nothing and stays correct if the ledger
    ///      ever does start retaining released entries.
    /// @dev THE BAR IS WIDER THAN THE SLASH, BY CONSTRUCTION. The earlier
    ///      claim that the two sets are "one list read from one place" was
    ///      never true: they are two reads, at two instants, in two contracts.
    ///      `ChallengeGame._settle` derives who is SLASHED from `slashBpsFor`
    ///      at RULE time, and that view still filters on the live booking.
    ///      What holds is CONTAINMENT, which is the direction that matters:
    ///      `_recorded.usd != 0` implies `_reservedUsd != 0` — the booking is
    ///      derived from the pledge and bounded by it, and a release clears
    ///      both — so everyone a conviction can take stake from is barred
    ///      here. Nobody votes on a case that is about to slash them.
    ///
    ///      The converse gap — barred here, slashed nothing there — costs
    ///      nothing to leave open. A booking only reaches zero once the
    ///      guardian's own slashable bond has; `_slashOne` clamps every rate
    ///      to live stake and the delegated leg is always zero. So the entry
    ///      `slashBpsFor` drops is one there was never anything to collect
    ///      from. Widening that read as well would change the conviction path
    ///      without recovering a wei, so it is deliberately left alone.
    /// @dev  THE LEDGER COMES FROM THE GAME, NOT FROM `governor`. See
    ///       `IChallengeGameLedger` for why substituting the challenger-
    ///       supplied governor's ledger would hand the accused an empty
    ///       accused set. It arrives as a PARAMETER, already resolved: `refer`
    ///       performs the one `exposureLedger()` read and stores it in
    ///       `Case.ledger`, so the address this function derives the accused
    ///       set from and the address the case record advertises are the same
    ///       value by construction, not by two reads happening to agree. A
    ///       second live resolution here would be exactly the drift the pin
    ///       exists to deny.
    /// @dev  THE RESIDUAL RE-POINT WINDOW IS FILE→REFER, AND IT IS OUT OF THE
    ///       COURT'S REACH. `ChallengeGame.setExposureLedger` vets the
    ///       INCOMING ledger — non-zero, `challengeWindow` wide enough, and
    ///       `coverageFreezer` already pointed back at the game
    ///       (`RoleNotGranted`) — but none of those consult LIVE CHALLENGES,
    ///       so a re-point still lands mid-challenge freely. Pinning at
    ///       `refer` closes the refer→finalize half: once a
    ///       case exists, no re-point can empty its accused set, zero its
    ///       `accusedWeight`, or raise the participation floor under it. The
    ///       other half remains — an owner who re-points strictly BETWEEN
    ///       `file` and `refer` still has the empty set pinned, because there
    ///       is no earlier instant the court is present for. That failure is
    ///       owner-only and recoverable (re-point back before `refer`, or wait
    ///       for the challenge's own timeout), and closing it belongs to
    ///       `ChallengeGame`: either an at-`file` pin in the `Challenge`
    ///       struct, or a live-challenge guard on `setExposureLedger`. Both
    ///       are deliberately out of scope here.
    /// @dev  WEIGHT IS SUMMED AT `snapshotTs` AND, SEPARATELY, AT
    ///       `snapshotTs - FLOOR_LOOKBACK` (finding #6), the two instants
    ///       `_participationFloor` reduces its own `total`/`earlier` reads
    ///       against — so the numbers subtracted from the floor are measured
    ///       on exactly the same electorates the floor's two terms are drawn
    ///       from, at the SAME accused set both times (one loop, two sums,
    ///       never two different membership lists). RAW `getPastStake`, not
    ///       aged `getPastVotes`, for BOTH sums: `_participationFloor`
    ///       subtracts each from a `getPastTotalVotes` read, which sums raw
    ///       own stake — the two must be the same basis or the subtraction
    ///       compares two different measures of the same WOOD. The raw basis
    ///       is not merely a units argument — it also denies the accused a
    ///       free lever on its own conviction threshold. If this summed aged
    ///       `getPastVotes` instead, an accused approver
    ///       could call `requestUnstakeGuardian` — free, permissionless,
    ///       cancellable — between the drain and `refer`, re-anchoring its
    ///       `stakedAt` and flooring its own contribution to `ageFloorBps`.
    ///       That shrinks the subtrahend, RAISES the floor, and can push a
    ///       case the accused was certain to lose into `Inconclusive` (which
    ///       escapes the slash entirely — the accused's counter-bond returns
    ///       whole, and only the challenger's bond takes the escalating
    ///       Inconclusive burn). The raw basis is immune: `getPastStake`
    ///       reads the checkpointed
    ///       amount directly, with no live, re-anchorable factor for a
    ///       pending unstake request to move.
    /// @dev  A DOUBLE-LISTED APPROVER WOULD DOUBLE-COUNT ITS WEIGHT, so the
    ///       `isAccused` flag is checked before accumulating (dedup guard).
    ///       The ledger does not produce duplicates today; the guard costs one
    ///       extra SLOAD per approver and makes the floor's denominator
    ///       independent of that.
    /// @dev  THE LOOP IS BOUNDED, not unbounded despite the caller-controlled
    ///       `proposalId`: `pledgedOf` returns the same list
    ///       `GuardianRegistry` walks on every approve/settle, which is capped
    ///       at `MAX_APPROVERS_PER_PROPOSAL = 100` (`GuardianRegistry.sol`).
    ///       So this loop is at most 100 iterations, each one now TWO
    ///       `getPastStake` staticcalls (`snapshotTs` and, since finding #6,
    ///       `snapshotTs - FLOOR_LOOKBACK`) rather than one.
    /// @dev  NO GAS STIPEND IS SIZED FOR THIS LOOP, DELIBERATELY. The
    ///       auto-referral path does run `refer` (and this loop) inside
    ///       `ChallengeGame.dispute`'s try/catch, which pays for up to ~100
    ///       PAIRS of `getPastStake` staticcalls in the worst case — but no
    ///       gas floor fronts that call. `dispute` is how the accused BUY
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
    ///       above; the second `getPastStake` staticcall per approver added
    ///       for finding #6 roughly doubles the loop's prior ~5.06M-gas
    ///       measurement at that cap, which is still well inside what a real
    ///       transaction forwards. Re-measure at the 100-approver cap before
    ///       relying on an exact figure — see `ChallengeGame.dispute`'s own
    ///       natspec for the full argument.
    function _recordAccused(
        uint256 caseId,
        ITokenCourt.Case storage c,
        address ledger,
        address governor,
        uint256 proposalId,
        uint256 snapshotTs
    ) internal {
        (address[] memory approvers, uint256[] memory pledgedUsd) =
            IExposureLedger(ledger).pledgedOf(governor, proposalId);

        address swood = stakedWood;
        // Same lookback instant `_participationFloor` reduces `earlier`
        // against — computed once here so the accused set's weight at BOTH
        // instants comes from one loop over one membership list (finding
        // #6).
        uint256 lookbackTs = snapshotTs > FLOOR_LOOKBACK ? snapshotTs - FLOOR_LOOKBACK : 0;
        uint256 weight;
        uint256 weightAtLookback;
        uint256 count;
        for (uint256 i; i < approvers.length; ++i) {
            // The PLEDGE, not the live booking: a release before the filing
            // backs nothing and answers for nothing, but a settlement pass
            // writing a booking down to zero is not a release (#83).
            if (pledgedUsd[i] == 0) continue;
            address approver = approvers[i];
            if (isAccused[caseId][approver]) continue; // dedup guard

            isAccused[caseId][approver] = true;
            _accused[caseId].push(approver);
            count += 1;
            weight += IStakedWood(swood).getPastStake(approver, snapshotTs);
            weightAtLookback += IStakedWood(swood).getPastStake(approver, lookbackTs);
        }

        c.accusedWeight = weight;
        c.accusedWeightAtLookback = weightAtLookback;
        emit AccusedSetRecorded(caseId, count, weight);
    }
}
