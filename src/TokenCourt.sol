// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ITokenCourt} from "./interfaces/ITokenCourt.sol";

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
}
