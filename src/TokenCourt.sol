// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ITokenCourt} from "./interfaces/ITokenCourt.sol";
import {IChallengeGame} from "./interfaces/IChallengeGame.sol";
import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
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
contract TokenCourt is Ownable2Step {
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

    // Local copies until Task 7 adds the ITokenCourt parent (then delete these).
    /// @notice A wiring setter was handed the zero address.
    error ZeroAddress();
    /// @notice A bounded setter was handed a value outside its allowed range.
    error InvalidParameter();
    /// @notice `refer` called on a challenge that already has a case
    ///         (`caseOfChallenge != 0`) — one case per challenge, enforced at
    ///         the door rather than left to a downstream overwrite.
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
    /// @notice The wired `ChallengeGame` changed (or was set for the first
    ///         time, `oldGame == address(0)`).
    event ChallengeGameSet(address indexed oldGame, address indexed newGame);
    /// @notice The wired `StakedWood` electorate source changed (or was set
    ///         for the first time, `oldStakedWood == address(0)`).
    event StakedWoodSet(address indexed oldStakedWood, address indexed newStakedWood);
    /// @notice The default vote window changed. Governs future referrals
    ///         only — every case already `Voting` keeps the window it was
    ///         referred under.
    event VoteWindowSet(uint256 oldWindow, uint256 newWindow);
    /// @notice The participation floor changed. Governs future finalizations
    ///         only.
    event ParticipationFloorBpsSet(uint256 oldBps, uint256 newBps);
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

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Full state of one case.
    function caseOf(uint256 caseId) external view returns (ITokenCourt.Case memory) {
        return _cases[caseId];
    }

    /// @notice The accused set recorded for a case, in the order it was
    ///         recorded.
    function accusedOf(uint256 caseId) external view returns (address[] memory) {
        return _accused[caseId];
    }

    /// @notice Wire (or re-wire) the challenge game this court adjudicates
    ///         for. The zero address is refused — an unwired court can
    ///         `refer` nothing.
    function setChallengeGame(address newGame) external onlyOwner {
        if (newGame == address(0)) revert ZeroAddress();
        emit ChallengeGameSet(challengeGame, newGame);
        challengeGame = newGame;
    }

    /// @notice Wire (or re-wire) the electorate source. The zero address is
    ///         refused — an unwired court has no vote weight to read.
    function setStakedWood(address newStakedWood) external onlyOwner {
        if (newStakedWood == address(0)) revert ZeroAddress();
        emit StakedWoodSet(stakedWood, newStakedWood);
        stakedWood = newStakedWood;
    }

    /// @notice Set the vote window newly referred cases receive. Bounded to
    ///         `(0, MAX_VOTE_WINDOW]`; zero would open a case that could
    ///         never be voted on. Governs future referrals only — a case
    ///         already `Voting` keeps its pinned `voteWindowAtReferral`.
    function setVoteWindow(uint256 newWindow) external onlyOwner {
        if (newWindow == 0 || newWindow > MAX_VOTE_WINDOW) revert InvalidParameter();
        emit VoteWindowSet(voteWindow, newWindow);
        voteWindow = newWindow;
    }

    /// @notice Set the anti-capture participation floor. Bounded to
    ///         `(0, 10_000]`; zero would let any nonzero turnout, however
    ///         thin, reach a verdict on the merits.
    function setParticipationFloorBps(uint256 newBps) external onlyOwner {
        if (newBps == 0 || newBps > BPS_DENOMINATOR) revert InvalidParameter();
        emit ParticipationFloorBpsSet(participationFloorBps, newBps);
        participationFloorBps = newBps;
    }

    /// @notice Open a case for a disputed challenge. Permissionless and free
    ///         — the entry point both the game's auto-referral and any
    ///         manual fallback call.
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
    /// @dev    STATE IS CLAIMED BEFORE ANY EXTERNAL READ. The reads below call
    ///         out to `ch.governor` — an address the CHALLENGER supplied to
    ///         `ChallengeGame.file` and may therefore control. Both
    ///         `challengeOf` and `getProposal` are `view` today, so the
    ///         compiler emits STATICCALL and re-entry is impossible at the EVM
    ///         level; claiming `caseOfChallenge[challengeId]` first is what
    ///         keeps that true even if either interface ever loses its `view`
    ///         — a hostile governor re-entering with the same id then hits
    ///         `AlreadyReferred` rather than opening a second case over one
    ///         accusation.
    /// @return caseId The new case's id.
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

        uint256 executedAt = ISyndicateGovernor(ch.governor).getProposal(ch.proposalId).executedAt;
        // Unreachable through a real filing — `ChallengeGame.file` rejects an
        // unexecuted proposal — but fail closed rather than underflow into a
        // snapshot at `type(uint256).max`, an instant nobody has voting power
        // at.
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
    ///       warm SLOAD and makes the floor's denominator independent of that.
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
