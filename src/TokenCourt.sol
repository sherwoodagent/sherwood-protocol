// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ITokenCourt} from "./interfaces/ITokenCourt.sol";
import {IChallengeGame} from "./interfaces/IChallengeGame.sol";
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";
import {IStakedWood} from "./interfaces/IStakedWood.sol";

/// @notice Which ledger the game trusts. Read from the game, never from the
///         challenger-supplied governor, which could report no approvers and
///         so empty the accused set.
interface IChallengeGameLedger {
    function exposureLedger() external view returns (address);
}

/// @notice The electorate's age floor, used to enforce
///         `participationFloorBps < ageFloorBps`. Kept local rather than
///         widened into `IStakedWood`, which every mock implements.
interface IStakedWoodAgeFloor {
    function ageFloorBps() external view returns (uint256);
}

/// @notice The proposer-bond record, read in `refer` to identify the party a
///         verdict pays. Kept local and minimal for the same reason as the two
///         interfaces above: this contract needs one selector, not the whole
///         escrow surface.
interface IProposerBondRecord {
    function bondOf(address governor, uint256 proposalId) external view returns (address proposer, uint256 amount);
}

/**
 * @title TokenCourt
 * @notice Single-layer WOOD-vote adjudication of disputed `ChallengeGame`
 *         challenges: one referral opens one vote window, one tally against a
 *         participation floor produces the verdict. No panel, no appeal.
 *
 * @dev    Holds no WOOD. Every WOOD-moving effect of a verdict (slash,
 *         demotion, bond return, payout) lives on `ChallengeGame` and
 *         `StakedWood`; this contract only decides
 *         `Guilty` / `NotGuilty` / `Inconclusive` and hands it to `rule`.
 *
 * @dev    Convictions BURN the accused's bond, which raises every remaining
 *         holder's share of supply — so a WOOD-heavy party profits from any
 *         conviction, guilty or not. Treat the participation floor, the vote
 *         window and the snapshot instant as economic parameters, not merely
 *         procedural ones.
 *
 * @dev    Non-upgradeable, plain `Ownable2Step`. No pause exists here: the
 *         system-wide backstop is `ChallengeGame.setFilingsPaused`. Pausing
 *         referral or voting would let an already-disputed challenge drift
 *         into its own `disputeTimeout` while the court sits frozen.
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
    /// @notice How far before a case's snapshot the participation floor's
    ///         electorate base is cross-checked, and the window over which
    ///         `vote` gates a ballot's own stake growth. Stake younger than
    ///         this can neither raise the floor nor vote at face value.
    /// @dev    A `constant`, not an owner parameter: a setter would be a lever
    ///         to shrink the lookback to zero immediately before a drain.
    uint256 public constant FLOOR_LOOKBACK = 30 days;
    /// @notice Lower bound, in bps of the lookback instant's TOTAL electorate,
    ///         that a NONZERO lookback term is floored at before it may win
    ///         the participation floor's min. Without it a tiny positive
    ///         residual — one unrelated guardian holding dust at the lookback —
    ///         rounds the floor to zero however large today's electorate is.
    /// @dev    Measured against `earlier`, never against `reduced`: `reduced`
    ///         is a `snapshotTs` reading and so attacker-inflatable. The
    ///         exact-zero case still falls back to unclamped `reduced`.
    /// @dev    A `constant`, for the same reason `FLOOR_LOOKBACK` is.
    uint256 internal constant MIN_LOOKBACK_BASE_BPS = 1_000; // 10%

    /// @notice The wired `IChallengeGame` this court adjudicates for and
    ///         reads challenge state from. Zero while unwired.
    address public challengeGame;
    /// @notice The wired `IStakedWood` electorate source. Zero while unwired.
    address public stakedWood;
    /// @notice The vote window newly referred cases receive. Bounded by
    ///         `MAX_VOTE_WINDOW`; a live case keeps the window it was
    ///         referred under regardless of later changes here.
    uint256 public voteWindow = 5 days;
    /// @notice Anti-capture participation floor, in bps of
    ///         `min(total - accusedWeight, earlier - accusedWeightAtLookback)`,
    ///         each subtraction same-instant and floored at zero. See
    ///         `_participationFloor`.
    uint256 public participationFloorBps = 1_000;

    /// @notice Count of cases ever referred. Case ids are 1-indexed.
    uint256 public caseCount;
    mapping(uint256 caseId => ITokenCourt.Case) internal _cases;
    /// @notice The case id referred for a challenge on a given game, or zero.
    /// @dev Keyed by (game, challenge id), not by id alone: `ChallengeGame` is
    ///      non-upgradeable, so redeploying it is the migration path, and a
    ///      fresh game's `challengeCount` restarts at 0 — single-keying would
    ///      make every colliding challenge revert `AlreadyReferred` forever.
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
    /// @dev Validates the window invariant against the NEW game's own clocks.
    ///      Without it, `setVoteWindow` could raise `voteWindow` while unwired
    ///      (passing vacuously) and this setter would then seat it on a game
    ///      whose clocks cannot fit it.
    function setChallengeGame(address newGame) external onlyOwner {
        if (newGame == address(0)) revert ZeroAddress();
        IChallengeGame game_ = IChallengeGame(newGame);
        // Same margin as `ChallengeGame._requireWindowFits`, read from the
        // game rather than duplicated: bare equality leaves as little as one
        // second to retry a dropped auto-referral.
        if (game_.autoSlashDelay() + voteWindow + FINALIZE_BUFFER + game_.MIN_REFERRAL_SLACK() > game_.disputeTimeout())
        {
            revert WindowInvariantViolated();
        }
        emit ChallengeGameSet(challengeGame, newGame);
        challengeGame = newGame;
    }

    /// @dev No path to an ownerless court. The setters are the rescue path for
    ///      a compromised or redeployed dependency and this contract is
    ///      non-upgradeable, so there is no recovery afterwards. `pure`, not
    ///      `onlyOwner`: refused for everyone, the owner included.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /// @inheritdoc ITokenCourt
    /// @dev Validates the floor invariant against the NEW electorate's live
    ///      `ageFloorBps()`, closing the vacuous branch
    ///      `setParticipationFloorBps` leaves open while unwired. A target
    ///      without `ageFloorBps()` reverts on the read (fail closed).
    function setStakedWood(address newStakedWood) external onlyOwner {
        if (newStakedWood == address(0)) revert ZeroAddress();
        if (participationFloorBps >= IStakedWoodAgeFloor(newStakedWood).ageFloorBps()) {
            revert FloorInvariantViolated();
        }
        emit StakedWoodSet(stakedWood, newStakedWood);
        stakedWood = newStakedWood;
    }

    /// @inheritdoc ITokenCourt
    /// @dev Mirrors `ChallengeGame._requireWindowFits`: the invariant
    ///      `autoSlashDelay + voteWindow + FINALIZE_BUFFER <= disputeTimeout`
    ///      spans both contracts, so it is enforced here too against the
    ///      game's live clocks. Vacuous with no game wired.
    function setVoteWindow(uint256 newWindow) external onlyOwner {
        if (newWindow == 0 || newWindow > MAX_VOTE_WINDOW) revert InvalidParameter();
        address g = challengeGame;
        if (g != address(0)) {
            IChallengeGame game_ = IChallengeGame(g);
            // Same margin as the game's own `_requireWindowFits`.
            if (
                game_.autoSlashDelay() + newWindow + FINALIZE_BUFFER + game_.MIN_REFERRAL_SLACK()
                    > game_.disputeTimeout()
            ) {
                revert WindowInvariantViolated();
            }
        }
        emit VoteWindowSet(voteWindow, newWindow);
        voteWindow = newWindow;
    }

    /// @inheritdoc ITokenCourt
    /// @dev Enforces `participationFloorBps < ageFloorBps` against the wired
    ///      sWOOD's live `ageFloorBps()`. Vacuous with no electorate wired;
    ///      `setStakedWood` closes that branch from the other side.
    ///
    ///      Strict `<`, not `<=`: turnout sums AGED weight bounded below by
    ///      `ageFloorBps / 10_000` of raw stake while the floor's base is RAW
    ///      stake, so at equality clearing the floor would need every unaccused
    ///      staked wei voting at age zero.
    ///
    ///      Deliberately not guarded: `StakedWood.setAgeFloorBps` lowering the
    ///      other side of the pair afterwards. sWOOD is the base-layer
    ///      custodian and holds no pointer back to this court; that lever is
    ///      covered by the deploy pre-flight and monitoring instead.
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
    /// @dev The snapshot is computed here, once, and stored: `executedAt - 1`,
    ///      the block before the challenged proposal executed. Storing it
    ///      rather than re-deriving it keeps the electorate that judges guilt
    ///      identical however many blocks pass before the window closes.
    /// @dev Nothing here extends the challenge's own clock, so the clock check
    ///      below refuses to open a case unless `voteWindow + FINALIZE_BUFFER`
    ///      still fits before the game's `disputeTimeout` — a case that exists
    ///      is always one that can finish.
    /// @dev `caseOfChallenge` is claimed before any external read, so a second
    ///      `refer` on the same (game, challenge) stays a harmless no-op even
    ///      if `challengeOf` ever loses its `view`.
    /// @dev The exposure ledger is pinned here too: one read, stored in
    ///      `Case.ledger` and handed to `_recordAccused`, so a later
    ///      `ChallengeGame.setExposureLedger` cannot empty this case's accused
    ///      set, zero its `accusedWeight`, or raise its floor. The residual
    ///      file-to-refer window stays open — see `_recordAccused`.
    function refer(uint256 challengeId) external returns (uint256 caseId) {
        address game = challengeGame;
        address swood = stakedWood;
        // Requires wired: a case cannot exist before its electorate does.
        if (game == address(0) || swood == address(0)) revert ZeroAddress();
        if (caseOfChallenge[game][challengeId] != 0) revert AlreadyReferred();

        caseId = ++caseCount;
        caseOfChallenge[game][challengeId] = caseId;

        IChallengeGame.Challenge memory ch = IChallengeGame(game).challengeOf(challengeId);
        // Only a contested challenge escalates: a `Filed` one is still inside
        // its auto-slash clock, and a terminal one has nothing left to decide.
        if (ch.status != IChallengeGame.Status.Disputed) revert ChallengeNotDisputed();
        // AND ONE THAT CAN ACTUALLY BE RULED. `ChallengeGame.rule` authorises
        // against the challenge's OWN `courtAtFiling` pin, not against whoever
        // is wired live — a challenge filed while the game had no court pinned
        // itself at zero and stays unrulable forever, even after `setCourt`.
        // Referring it anyway opens a case, takes real votes, and then wedges:
        // `finalize` re-raises every revert except `WrongStatus`, so `rule`'s
        // `NotCourt` rolls back the `phase = Resolved` write and the case can
        // never leave `Voting`. The tally is discarded either way, since the
        // dispute timeout routes a zero-pin challenge to `_refundAll`.
        // `ChallengeGame.dispute` now auto-refers against this same pin; THIS
        // guard is the load-bearing one, because `refer` is permissionless and
        // reachable directly regardless of how the case got escalated.
        if (ch.courtAtFiling == address(0)) revert ChallengeNotRulable();

        // The clock check: a vote that could not finish before the
        // challenge's own timeout never opens.
        uint256 window = voteWindow;
        if (block.timestamp + window + FINALIZE_BUFFER > ch.filedAt + ch.disputeTimeoutAtFiling) {
            revert InsufficientClock();
        }

        // `ch.executedAt` is the game's own pin, snapshotted at filing; the
        // settle-path slash is sized against the same field. Reading it here
        // rather than calling back into `ch.governor` makes the snapshot
        // instant equal the slash instant by construction, not by two reads
        // happening to agree.
        uint256 executedAt = ch.executedAt;
        // Unreachable through a real filing — `file` rejects an unexecuted
        // proposal — but fail closed rather than underflow the snapshot.
        if (executedAt == 0) revert InvalidParameter();
        uint256 snapshotTs = executedAt - 1;

        // Resolved exactly once; every consumer below reads this value.
        address ledger = IChallengeGameLedger(game).exposureLedger();

        ITokenCourt.Case storage c = _cases[caseId];
        c.challengeId = challengeId;
        c.game = game; // pinned: setChallengeGame afterward must not redirect finalize's rule call
        c.ledger = ledger; // pinned: setExposureLedger afterward must not re-derive this case's accused set
        c.snapshotTs = snapshotTs;
        c.referredAt = block.timestamp;
        c.voteWindowAtReferral = window;
        c.phase = ITokenCourt.Phase.Voting;
        // Pinned from the same `ch` struct read above. `vote` bars this
        // address like the accused set: a `Guilty` verdict pays the challenger
        // the accused's bond, so an unbarred challenger voting `Guilty` on its
        // own filing would be a self-dealing conviction, not a jury verdict.
        c.challenger = ch.challenger;
        // AND SO IS THE PROPOSER — the largest verdict-contingent payee of all.
        // `_settle` confiscates its ENTIRE bond on `Guilty` and every other
        // outcome returns it whole, so on the exact principle the challenger bar
        // states ("a direct payout riding on the verdict") it must not vote.
        // See `ProposerCannotVote` for why `isAccused` cannot reach it.
        //
        // PINNED HERE, NOT READ AT VOTE TIME, matching `challenger`: a verdict
        // can land a full `disputeTimeout` after filing, and the bond record is
        // deleted by `releaseBond`/`forfeitBond`, so a live read would go blind
        // exactly when it matters.
        //
        // SOURCED FROM THE BOND RECORD, not from the governor's `proposer`
        // field. The escrow entry is the authoritative statement of WHO posted
        // the capital this verdict destroys — the same `(governor, proposalId)`
        // binding `_settle`'s `forfeitBond` acts on — so the bar tracks the
        // payout by construction rather than by two sources happening to agree.
        //
        // RAW STATICCALL — same doctrine as the `counterBondContributionOf`
        // probe in `vote` and `ExposureLedger._feedPriceX8`. A typed call into an
        // escrow that does not answer this selector reverts in THIS frame with
        // no data, turning a missing selector into an undecodable failure of all
        // referral.
        //
        // THE FAILURE BRANCH IS A STATED DECISION, and here it is OPEN — no bar
        // — because the branch means there is no payout to bar. `ch.proposerBondEscrow`
        // is documented as "Zero when the proposal locked no bond, which the
        // settle path treats as nothing-to-forfeit rather than an error", and an
        // `amount == 0` record says the same thing: no bond at stake, no
        // verdict-contingent interest, nothing this bar is protecting against.
        // An escrow that cannot answer at all is a strictly narrower case still
        // — `_settle`'s own `forfeitBond` call cannot survive it either, so such
        // a challenge never reaches a paying verdict in the first place.
        address escrow = ch.proposerBondEscrow;
        if (escrow != address(0)) {
            (bool okBond, bytes memory bondRet) =
                escrow.staticcall(abi.encodeCall(IProposerBondRecord.bondOf, (ch.governor, ch.proposalId)));
            if (okBond && bondRet.length == 64) {
                (address bondProposer, uint256 bondAmount) = abi.decode(bondRet, (address, uint256));
                if (bondAmount != 0) c.proposer = bondProposer;
            }
        }

        emit CaseReferred(caseId, challengeId, ch.governor, ch.proposalId, snapshotTs);

        // The accused set is fixed here, under the same rule as the snapshot:
        // `vote` bars it, and `_participationFloor` subtracts its weight.
        _recordAccused(caseId, c, ledger, ch.governor, ch.proposalId, snapshotTs);
    }

    /// @inheritdoc ITokenCourt
    /// @dev Weight is `getPastVotes` at `c.snapshotTs` (`executedAt - 1`),
    ///      already age-weighted by `StakedWood` and never re-weighted here.
    ///      Reading from before the drain is the flash-loan defence: WOOD
    ///      bought or staked afterwards has no weight at all.
    /// @dev GROWTH-GATED MIN. The snapshot alone let WOOD staked one second
    ///      before a drain vote at `ageFloorBps` of raw. So when the caller's
    ///      RAW stake grew over `FLOOR_LOOKBACK` (strict `>`) AND an electorate
    ///      existed at the lookback, the ballot is `min(weightNow, weightThen)`;
    ///      otherwise it is `weightNow` unclamped.
    ///
    ///      Gate on RAW, clamp on WEIGHT. Age growth without raw growth is pure
    ///      aging, legitimate by construction; gating on weight growth would
    ///      fire on every merely-aging position and re-tax the honest cohort. A
    ///      fresh address has `rawThen == 0`, hence `weightThen == 0`, and is
    ///      refused outright. The bootstrap fallback keys on the TOTAL lookback
    ///      electorate, never on the caller's own `rawThen`, which is the
    ///      attack's own signature.
    /// @dev Residuals left open: capital parked at or before `lookbackTs` votes
    ///      unclamped (the price of not taxing the steady cohort), and
    ///      touch-stake — unstake mid-window, re-stake at drain time — gates
    ///      false, discounted only by the re-stake's own re-anchor. Closing
    ///      either needs a windowed minimum over the checkpoint trace
    ///      (gas-unbounded) or new state.
    /// @dev Neither the accused nor the challenger may vote: both have a direct
    ///      payout riding on the verdict. Without those bars, approvers who
    ///      were already large holders before the drain could clear the floor
    ///      alone and judge their own case, and a challenger could self-fund a
    ///      conviction that pays it the accused's bond.
    /// @dev OPEN LIMITATION: the bar is on the approving ADDRESS, not the party
    ///      behind it. Permissionless staking lets one actor approve from one
    ///      address and vote from others, and naming more approvers only ever
    ///      lowers the floor those siblings must clear, never raises it.
    /// @dev Tallies accumulate AGED weight while the floor's base is RAW stake.
    ///      Deliberate, not a mismatch: aging only shrinks weight relative to
    ///      raw, so turnout can never exceed what the floor's base summed.
    /// @dev Present holdings are a gate, never a weight — active guardian at
    ///      the instant of casting, nothing about before or after.
    ///      `requestUnstakeGuardian`, not the claim, is where the leak opens:
    ///      it re-anchors `stakedAt` and pushes a zero checkpoint. A fully
    ///      exited holder can re-stake `minGuardianStake` and pass the gate
    ///      again, voting the historic checkpoint discounted to `ageFloorBps` —
    ///      a residual bounded by that cost, not eliminated. Re-weighting on
    ///      present holdings would reintroduce the post-hoc accumulation the
    ///      snapshot exists to close, so this stays binary.
    function vote(uint256 caseId, bool guilty) external {
        ITokenCourt.Case storage c = _cases[caseId];
        if (c.phase != ITokenCourt.Phase.Voting) revert WrongPhase();
        if (block.timestamp >= c.referredAt + c.voteWindowAtReferral) revert WindowClosed();
        if (voteOf[caseId][msg.sender] != ITokenCourt.Ruling.None) revert AlreadyVoted();
        if (isAccused[caseId][msg.sender]) revert AccusedCannotVote();
        // The challenger may not vote on its own filing: a `Guilty` verdict
        // returns its bond net of `settleBurnBps` AND pays it the prosecutor fee
        // out of the forfeited proposer bond, and the floor's
        // `total - accusedWeight` shape makes a unilateral conviction easier the
        // more approvers the challenge names. Pinned in `refer`.
        //
        // THE POOL IS NO LONGER PART OF THAT PAYOUT. Since finding #10 a
        // completed pool is BURNED on conviction and an incomplete one is
        // returned to its funders — nothing routes it to the challenger. The bar
        // stands on the prosecutor fee and the bond return, which are payout
        // enough.
        if (msg.sender == c.challenger) revert ChallengerCannotVote();
        // AND NEITHER MAY THE PROPOSER, whose whole bond the verdict destroys or
        // returns. Pinned in `refer` from the bond record; zero means no bond
        // was locked, hence no payout and no bar — and zero can never match a
        // caller, since `address(0)` cannot originate a call.
        if (msg.sender == c.proposer) revert ProposerCannotVote();
        // AND NEITHER MAY THE SIDE A `NotGuilty` VERDICT PAYS. The bars above
        // cover the beneficiaries of a `Guilty` ruling (the accused avoid the
        // slash, the challenger keeps its bond and takes the prosecutor fee, the
        // proposer's bond is destroyed) but left the beneficiary of the OPPOSITE
        // ruling unbarred. `dispute` is open
        // to anyone by design, and `_fail`'s payout is pro-rata to
        // CONTRIBUTION with no accused-membership filter — so a guardian who
        // never approved the proposal (hence `isAccused` false) can fund the
        // entire counter-bond alone, vote its own acquittal, and claim
        // `contributed + forfeitPayoutWood` — a net `+0.8x` of its stake at
        // the shipped `forfeitBurnBps`, taken from the honest challenger's
        // forfeited bond. It only has to MATCH the guilty tally, since
        // `finalize` acquits on a tie, and its ballot also counts toward
        // `turnout`, converting an unpaid `Inconclusive` into a paid
        // `NotGuilty`. Read the game pinned on the case (`c.game`), never the
        // live `challengeGame` pointer, for the same reason `finalize` does.
        // RAW STATICCALL — same doctrine as `ExposureLedger._feedPriceX8` and
        // `SyndicateVault._openProposalPid`. A typed call into a game that does
        // not answer this selector reverts in THIS frame with no data, turning
        // a missing selector into an undecodable failure of ALL voting rather
        // than a stated one. Decoding explicitly makes the failure branch a
        // decision, and the decision is CLOSED: a game that cannot tell us
        // whether the caller funded the counter-bond cannot clear them to vote
        // on it either.
        (bool okCb, bytes memory cbRet) =
            c.game.staticcall(abi.encodeCall(IChallengeGame.counterBondContributionOf, (c.challengeId, msg.sender)));
        if (!okCb || cbRet.length != 32 || abi.decode(cbRet, (uint256)) != 0) {
            revert CounterBondContributorCannotVote();
        }

        IStakedWood swood = IStakedWood(stakedWood);
        uint256 weight = swood.getPastVotes(msg.sender, c.snapshotTs);
        // Growth-gated min (see @dev above). Gate on RAW growth, strict `>`,
        // first in the `&&` so the lookback-total read short-circuits away for
        // every non-growth voter.
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
    /// @dev Verdict table. `turnout == 0 || turnout < floor` -> `Inconclusive`,
    ///      a non-event that unwinds both sides rather than an acquittal, since
    ///      a thin or absent vote answers nothing about guilt.
    ///      `guiltyVotes > notGuiltyVotes` -> `Guilty`, a strict majority.
    ///      Otherwise, ties included -> `NotGuilty`, because `Guilty` triggers
    ///      a full slash and an even vote is the worst possible basis for
    ///      destroying stake. Every branch assigns explicitly — the zero value
    ///      of `Verdict` is `Inconclusive`, not `NotGuilty`.
    /// @dev State is closed before the external `rule` call, which is wrapped
    ///      in try/catch: between the window closing and `finalize`, the
    ///      challenge can go terminal on its own clock. With zero custody, a
    ///      verdict that never lands is bookkeeping, not stranded funds.
    /// @dev The catch is selector-filtered, not bare. A bare catch is a
    ///      verdict-burning primitive: `rule`'s callee-side gas floor can be
    ///      forced to revert by an under-gassed `finalize` while the parent
    ///      still completes, permanently dropping a `Guilty` verdict for the
    ///      price of choosing a gas limit. Only `WrongStatus` means there is
    ///      nothing left to rule; everything else — `InsufficientSlashGas` and
    ///      `NotCourt` chief among them — is transient and bubbles, so the case
    ///      is left intact for an honest caller to retry.
    /// @dev Permissionless: the window, the tally and the verdict are all fixed
    ///      by state and the clock before this call runs.
    /// @dev OPEN LIMITATION: last-mover advantage is unmitigated. Votes are
    ///      public, the deadline is hard, and a tie acquits — so the acquitting
    ///      side need only MATCH the guilty tally in the final block. The
    ///      mitigation short of commit-reveal is a vote extension, deliberately
    ///      not implemented.
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

        // Terminal before the external call: a swallowed `WrongStatus` below
        // is bookkeeping, not stranded funds. Everything else bubbles and
        // reverts these writes too.
        c.verdict = verdict;
        c.finalizedAt = block.timestamp;
        c.phase = ITokenCourt.Phase.Resolved;
        emit CaseFinalized(caseId, verdict, guiltyVotes, notGuiltyVotes, floor);

        try IChallengeGame(c.game).rule(c.challengeId, verdict) {}
        catch (bytes memory reason) {
            // Swallow only `WrongStatus` — the one revert that genuinely means
            // there is nothing left to rule. `NotCourt` does not: it means the
            // game was re-pointed while the challenge is still rulable, and
            // swallowing it would close the case with the verdict undelivered,
            // which re-wiring cannot fix because `refer` reverts
            // `AlreadyReferred`. It is transient, so it bubbles.
            bytes4 sel = reason.length >= 4 ? bytes4(reason) : bytes4(0);
            if (sel != IChallengeGame.WrongStatus.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
            emit ChallengeAlreadyTerminal(caseId, c.challengeId);
        }
    }

    /// @dev The floor is `participationFloorBps` of
    ///      `min(flooredEarlierReduced, reduced)`, where
    ///      `reduced = max(0, total - accusedWeight)` at `snapshotTs` and
    ///      `earlierReduced = max(0, earlier - accusedWeightAtLookback)` at
    ///      `snapshotTs - FLOOR_LOOKBACK`. EVERY subtraction is same-instant:
    ///      each total is reduced by the accused weight measured at its OWN
    ///      instant, never cross-instant, and both sums use the same raw
    ///      own-stake basis `getPastTotalVotes` uses. Mixing instants broke
    ///      this twice — once by collapsing the floor to zero in a growing
    ///      protocol, once by letting a fresh never-approving stake choose
    ///      which term the min selects — and both taught the same rule.
    /// @dev Both zero-clamps are defence in depth: the accused set is a subset
    ///      of what `getPastTotalVotes` sums at the same instant, so each
    ///      subtraction is structurally non-negative under one consistently
    ///      wired `StakedWood`. They exist for a `setStakedWood` re-point
    ///      landing between two reads. Monotonicity holds but not via staking:
    ///      an accused approver staking more raises `total` and `accusedWeight`
    ///      by the same amount, so the base is unchanged.
    /// @dev WHY THE MIN OVER A LOOKBACK. The snapshot defends the NUMERATOR;
    ///      the denominator has the opposite exposure. A single `snapshotTs`
    ///      read is RAISED by anyone staked before `executedAt` from a
    ///      never-approving address — and the attacker knows when `executedAt`
    ///      is, because it is their own drain. Staking large from an address
    ///      that never approves puts the base beyond any achievable turnout,
    ///      forcing `Inconclusive` with no votes cast and nothing slashable.
    ///      The min can only ever LOWER the base, which is the safe direction:
    ///      nothing observable only at `snapshotTs` may raise the floor.
    ///      Reading the lookback term ALONE would not do either — an attacker
    ///      could stake before the lookback and unstake after it, and the floor
    ///      would rise whenever the electorate legitimately shrank.
    /// @dev WHY A NONZERO LOOKBACK TERM STILL NEEDS A FLOOR. The exact-zero
    ///      fallback catches only a structural zero. The accused can dominate
    ///      the lookback electorate almost entirely, leaving a dust residual
    ///      from one unrelated guardian; that residual wins the min and
    ///      `* participationFloorBps / BPS_DENOMINATOR` rounds it to literal
    ///      zero, letting a single pre-positioned voter decide the case. So a
    ///      nonzero `earlierReduced` is first raised to `MIN_LOOKBACK_BASE_BPS`
    ///      of `earlier`. The clamp's basis MUST be a lookback-instant
    ///      quantity: clamping against `reduced` reopens the attack in bounded
    ///      form, since a fraction of an attacker-inflated number is still
    ///      attacker-inflated. The clamp stays INSIDE the min, so `reduced == 0`
    ///      still forces a zero base over a provably empty electorate.
    /// @dev WHY 30 DAYS: it is the maturation horizon the numerator already
    ///      uses (`StakedWood._ageFactorBps`, deployed at 30 days), and it is
    ///      comfortably longer than a full proposal lifecycle, so the capital
    ///      must be down before the proposal is even filed. Hardcoded rather
    ///      than read live — a live read would hand another contract's owner a
    ///      lever over this court's lookback.
    /// @dev THE ZERO FALLBACK. When no electorate existed at the lookback
    ///      (`earlier == 0`, which includes `snapshotTs < FLOOR_LOOKBACK`) the
    ///      base falls back to `reduced` rather than to zero: a zero base would
    ///      disable the anti-capture floor for the protocol's first
    ///      `FLOOR_LOOKBACK`, and a wrongful `Guilty` destroys an honest
    ///      guardian's whole stake — strictly worse than the forced
    ///      `Inconclusive` the fallback leaves possible. The same branch
    ///      harmlessly covers the accused having BEEN the entire lookback
    ///      electorate.
    /// @dev `participationFloorBps` and `stakedWood` are read LIVE, not pinned
    ///      per-case — deliberately unlike `snapshotTs` and
    ///      `voteWindowAtReferral`. They are read once, at `finalize`, after
    ///      voting has closed, so no cast ballot can be altered retroactively.
    ///      The residual hazard: raising the floor before a pending `finalize`
    ///      can push a case that would have cleared into `Inconclusive`, which
    ///      burns a slice of the challenger's bond. It cannot manufacture a
    ///      conviction or an acquittal, and the owner is trusted here for the
    ///      same reason it is trusted with the wiring setters.
    function _participationFloor(uint256 snapshotTs, uint256 accusedWeight, uint256 accusedWeightAtLookback)
        internal
        view
        returns (uint256)
    {
        IStakedWood swood = IStakedWood(stakedWood);
        uint256 total = swood.getPastTotalVotes(snapshotTs);
        // Clamped, never underflowed: a proposal executing in the chain's
        // first `FLOOR_LOOKBACK` reads the trace at 0, which is empty.
        uint256 lookbackTs = snapshotTs > FLOOR_LOOKBACK ? snapshotTs - FLOOR_LOOKBACK : 0;
        uint256 earlier = swood.getPastTotalVotes(lookbackTs);
        // Same-instant subtraction, then the lookback min — order matters, and
        // it applies identically on both sides. Each accused weight is
        // subtracted from the total taken at its OWN instant, so every operand
        // answers the same question, how much of THIS instant's electorate is
        // unaccused, before the min ever compares them.
        //
        // PASHOV REVIEW FINDING #1, EXAMINED AND NOT ACTED ON (tracked in
        // #200). The observation is correct: `min` is monotone increasing in
        // BOTH operands, so when `reduced` binds, idle never-approving stake
        // planted before `executedAt` raises it and lifts the floor, while
        // `vote`'s growth gate denies that same stake a ballot. But the ceiling
        // on that lift is `flooredEarlierReduced`, which IS the intended
        // anti-capture bar — what an attacker buys is the removal of a LIVENESS
        // CONCESSION, not a bar beyond the design's intent.
        //
        // Both candidate fixes were implemented and measured against this
        // file's fixtures, and both are worse than the defect. Dropping the min
        // pins the floor permanently at the value the attacker was reaching
        // for. Capping `total` at `earlier` before subtracting `accusedWeight`
        // collapses the floor to ZERO whenever the electorate grew past the
        // lookback (`test_finalize_floorSurvivesElectorateGrowthPastTheLookback`:
        // earlier 60k, total 560k, accused 300k -> 6k becomes 0), and a zero
        // floor means any nonzero turnout convicts. The mutant
        // `base = (earlier != 0 && earlier < total) ? earlier : reduced` is
        // already pinned as wrong by the regression test below.
        //
        // A correct fix needs a votable-weight denominator — the aggregate of
        // per-voter `min(now, then)` — which is not computable on-chain from
        // the aggregate checkpoints available here.
        uint256 reduced = total > accusedWeight ? total - accusedWeight : 0;
        uint256 earlierReduced = earlier > accusedWeightAtLookback ? earlier - accusedWeightAtLookback : 0;
        // The smaller of the two unaccused electorates, except when there is no
        // earlier electorate to compare against (`earlierReduced == 0`), in
        // which case the same-instant reduction stands unclamped. That zero is
        // structural — `accusedWeightAtLookback <= earlier` always — so it is
        // not reachable by planting dust stake.
        //
        // A nonzero `earlierReduced` is floored at `MIN_LOOKBACK_BASE_BPS` of
        // `earlier` before it competes, so a dust residual cannot collapse the
        // floor. Do NOT clamp against `reduced`: it is a `snapshotTs` reading
        // and therefore attacker-inflatable. Both operands of the max are
        // lookback readings; `reduced` enters only as the min's cap, where it
        // can lower the base but never raise it.
        uint256 base;
        if (earlierReduced == 0) {
            base = reduced;
        } else {
            uint256 minBase = earlier * MIN_LOOKBACK_BASE_BPS / BPS_DENOMINATOR;
            uint256 flooredEarlierReduced = earlierReduced > minBase ? earlierReduced : minBase;
            base = flooredEarlierReduced < reduced ? flooredEarlierReduced : reduced;
        }
        return participationFloorBps * base / BPS_DENOMINATOR;
    }

    /// @dev THE PREDICATE IS THE LOCK, read via `pledgedOf`. The ledger holds
    ///      one WOOD lock per (proposal, guardian), written only by
    ///      `recordApproval` and erased only by `releaseApproval` (which a filed
    ///      challenge blocks with `CoverageFrozen`) or `retireApproval` (refused
    ///      while frozen or pinned). There is no longer a separately-movable
    ///      booking: the old `settleCoverage` could rewrite one in both
    ///      directions while a challenge was live, which put the accused set
    ///      inside a stranger's reach — a guardian convicted on a concurrent
    ///      challenge could be booked down to zero by anyone, drop out of this
    ///      loop, and walk past `vote`'s `AccusedCannotVote` bar with a ballot
    ///      still weighing the full pre-slash amount. That mechanism is deleted;
    ///      the accused set is now derived from a figure only the accused's own
    ///      pre-filing vote change could ever have moved.
    /// @dev A released approver is still excluded: `releaseApproval` clears the
    ///      lock and swap-and-pops the guardian out of `_approversOf`. The
    ///      zero-check below is the belt to that brace.
    /// @dev The bar and the slash read the SAME number: `slashBpsFor` rates
    ///      every listed guardian off this same lock, so everyone a conviction
    ///      can take stake from is barred here and nobody barred here is
    ///      un-slashable.
    /// @dev The ledger arrives as a PARAMETER, already resolved by `refer`, so
    ///      the address the accused set is derived from and the address the
    ///      case advertises are one value by construction. It comes from the
    ///      game, not the challenger-supplied `governor` — see
    ///      `IChallengeGameLedger`. The residual re-point window is
    ///      file-to-refer and belongs to `ChallengeGame`, which vets an
    ///      incoming ledger but does not consult live challenges.
    /// @dev Weight is summed at `snapshotTs` and, separately, at the lookback
    ///      instant, over the SAME accused set in one loop — the two instants
    ///      `_participationFloor` reduces its own reads against. RAW
    ///      `getPastStake`, not aged `getPastVotes`, for both: the floor
    ///      subtracts each from a `getPastTotalVotes` read, which sums raw own
    ///      stake. The raw basis also denies the accused a lever on its own
    ///      threshold — an aged basis would let an approver call
    ///      `requestUnstakeGuardian` between the drain and `refer` to shrink
    ///      the subtrahend, raise the floor, and force `Inconclusive`.
    /// @dev The loop is bounded at `MAX_APPROVERS_PER_PROPOSAL = 100`, each
    ///      iteration two `getPastStake` staticcalls. No gas stipend fronts it:
    ///      the auto-referral path runs inside `ChallengeGame.dispute`'s
    ///      try/catch, and a reverting `dispute` would deny the accused their
    ///      defence outright — unrecoverable — whereas a skipped referral is
    ///      not, since `refer` is permissionless.
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
        // against — computed once so both sums come from one loop.
        uint256 lookbackTs = snapshotTs > FLOOR_LOOKBACK ? snapshotTs - FLOOR_LOOKBACK : 0;
        uint256 weight;
        uint256 weightAtLookback;
        uint256 count;
        for (uint256 i; i < approvers.length; ++i) {
            // The pledge, not the live booking: a release before the filing
            // backs nothing, but a settlement pass writing a booking down to
            // zero is not a release.
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
