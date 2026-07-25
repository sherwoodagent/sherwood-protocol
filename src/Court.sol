// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICourt} from "./interfaces/ICourt.sol";
import {IChallengeGame} from "./interfaces/IChallengeGame.sol";
import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {IStakedWood} from "./interfaces/IStakedWood.sol";

/**
 * @title Court
 * @notice Adjudication of disputed challenges (spec 2026-07-22 §3.5, Plan E).
 *         Plan D left a disputed challenge terminal-with-timeout, which means a
 *         genuinely guilty approver can dispute and run out the clock. The
 *         court closes that hole: a bonded panel rules, that ruling is
 *         appealable to a full WOOD vote, and the outcome drives
 *         `ChallengeGame.rule`.
 *
 * @dev    THIS REVISION IS THE ROSTER, THE MEMBER BONDS AND BOTH LAYERS (Plan E
 *         Tasks 2-4). The bad-faith track (Task 5) builds on it. `ICourt`
 *         already declares its errors, so that task adds functions rather than
 *         churning the ABI.
 *
 * @dev    NEITHER HALF IS SAFE ALONE. §3.5: a token vote is incompetent for
 *         forensic questions and capturable at ~$15M mcap; a standalone panel
 *         is bribable with no check above it. The layers cover each other's
 *         failure mode, so this contract MUST NOT be wired into
 *         `ChallengeGame.setCourt` until the panel, the appeal and the
 *         bad-faith track are all live. Task 7 makes that a deploy pre-flight.
 *
 * @dev    Plain `Ownable2Step`, NOT upgradeable — the house shape for the
 *         economic-security contracts (cf. `CompensationEscrow`,
 *         `ChallengeGame`). Storage layout is therefore unconstrained and no
 *         golden pins it.
 *
 * @dev    §4 INVARIANT: `wood.balanceOf(this) == bondedWood + forfeitedWood`.
 *         `bondedWood` is every WOOD position somebody can still claim — posted
 *         panel bonds plus the bonds of appeals still open — and
 *         `forfeitedWood` is what the protocol now owns, from appeal bonds that
 *         missed the participation floor. Task 5 adds bad-faith bonds to the
 *         first and slashed panel bonds to the second. The equality is exact
 *         except for WOOD somebody donated here by mistake, which no path ever
 *         spends.
 */
contract Court is Ownable2Step, ICourt {
    using SafeERC20 for IERC20;

    /// @notice Upper bound on seated members. `setPanel` loops over the old and
    ///         new rosters and de-duplicates in O(n²); the bound keeps that
    ///         gas-safe. §3.5 contemplates a panel of ~5, so this is generous.
    uint256 public constant MAX_PANEL_SIZE = 21;

    /// @notice Ceiling on `panelWindow`.
    /// @dev    LOAD-BEARING AGAINST THE CHALLENGE CLOCK, not a style choice.
    ///         `ChallengeGame.resolve` fails a disputed challenge to the accused
    ///         once `disputeTimeout` (30d by default, 180d max) elapses from
    ///         `filedAt`, and the court's whole process — panel window, appeal
    ///         window, appeal vote — has to finish inside what is left of that
    ///         after the referral. A panel window that could eat the entire
    ///         timeout would let layer 1 run out the challenge's clock and
    ///         acquit by default, which is exactly the hole Plan E exists to
    ///         close. Task 7's deploy pre-flight is where the three windows are
    ///         checked to fit together against the live `disputeTimeout`.
    uint256 public constant MAX_PANEL_WINDOW = 14 days;

    /// @notice Ceiling on `badFaithWindow`. It does NOT run against the
    ///         challenge clock — the bad-faith track is about the panelist's
    ///         bond, long after the challenge itself is terminal — so the only
    ///         thing it bounds is how long a member's bond can be escrowed
    ///         after it rules.
    uint256 public constant MAX_BAD_FAITH_WINDOW = 90 days;

    /// @notice Ceiling on `appealWindow` — how long a panel ruling stays open
    ///         to appeal.
    /// @dev    SAME CLOCK AS `MAX_PANEL_WINDOW`, same reason. The court's three
    ///         windows run back to back inside the challenge's `disputeTimeout`,
    ///         and their ceilings are chosen so the worst case
    ///         (`MAX_PANEL_WINDOW + MAX_APPEAL_WINDOW + MAX_APPEAL_VOTE_WINDOW`
    ///         = 14 + 7 + 7 = 28 days) still fits inside `ChallengeGame`'s
    ///         30-day default timeout with room for the referral itself.
    ///         `test_windowCeilings_fitInsideDefaultDisputeTimeout` pins the
    ///         arithmetic so raising one ceiling cannot quietly push the total
    ///         past the clock and hand the accused an acquittal by default.
    uint256 public constant MAX_APPEAL_WINDOW = 7 days;

    /// @notice Ceiling on `appealVoteWindow` — how long layer 2's vote runs.
    uint256 public constant MAX_APPEAL_VOTE_WINDOW = 7 days;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    IERC20 public immutable wood;

    /// @notice The seated roster, in the order `setPanel` received it. Kept
    ///         alongside `isPanelist` because replacing the panel needs to
    ///         enumerate the members it is unseating, and because Task 7's
    ///         deploy pre-flight has to check every seat is bonded.
    address[] internal _panel;

    /// @inheritdoc ICourt
    mapping(address member => bool) public isPanelist;

    /// @inheritdoc ICourt
    uint256 public panelBondWood;

    /// @inheritdoc ICourt
    mapping(address member => uint256) public panelBondOf;

    /// @inheritdoc ICourt
    /// @dev Monotonically non-decreasing per member, written only through
    ///      `_lockPanelBond`. A deadline rather than an open-ruling COUNTER on
    ///      purpose: a bad-faith vote that is never opened has nothing to
    ///      decrement it, so a counter would strand the bond forever, whereas a
    ///      deadline simply expires.
    mapping(address member => uint256) public panelBondLockedUntil;

    /// @inheritdoc ICourt
    /// @dev Counts EVERY posted panel bond, seated or not: an unseated member
    ///      whose bond is still locked against the bad-faith track is still
    ///      WOOD this contract holds and must still balance.
    uint256 public bondedWood;

    /// @inheritdoc ICourt
    /// @dev Grows only in `finalizeAppeal`'s below-floor branch. Never overlaps
    ///      `bondedWood`: a bond moves from one to the other in the same
    ///      statement, so the §4 equality holds across the transition.
    uint256 public forfeitedWood;

    // ─────────────────────── Adjudication state (Task 3) ───────────────────────

    /// @inheritdoc ICourt
    /// @dev Typed as `address` rather than `IChallengeGame` so the generated
    ///      getter matches the interface, and cast at the two call sites.
    address public challengeGame;

    /// @inheritdoc ICourt
    /// @dev 7 days: long enough that a panel of humans spread across time zones
    ///      can read an evidence bundle and confer, short enough to leave room
    ///      inside `ChallengeGame.disputeTimeout` for the appeal that follows.
    uint256 public panelWindow = 7 days;

    /// @inheritdoc ICourt
    uint256 public badFaithWindow = 14 days;

    /// @inheritdoc ICourt
    uint256 public caseCount;

    mapping(uint256 caseId => Case) internal _cases;

    /// @inheritdoc ICourt
    mapping(uint256 challengeId => uint256 caseId) public caseOfChallenge;

    /// @inheritdoc ICourt
    mapping(uint256 caseId => mapping(address member => Ruling)) public panelVoteOf;

    /// @dev Appended by `panelRule`, read when the case resolves so every member
    ///      that ruled has its bond re-locked to `finalizedAt + badFaithWindow`.
    ///      Bounded by `MAX_PANEL_SIZE`.
    mapping(uint256 caseId => address[]) internal _panelVoters;

    // ─────────────────── Layer 2 state: the appeal (Task 4) ───────────────────

    /// @inheritdoc ICourt
    /// @dev Typed as `address` so the generated getter matches the interface.
    address public stakedWood;

    /// @inheritdoc ICourt
    /// @dev 3 days: an appeal is a decision to escalate, not the vote itself, so
    ///      it needs only long enough for the electorate to notice a ruling.
    uint256 public appealWindow = 3 days;

    /// @inheritdoc ICourt
    /// @dev 5 days: a full token vote, in the range governance votes normally
    ///      run, and short enough that panel + appeal + vote stays well inside
    ///      the challenge's `disputeTimeout`.
    uint256 public appealVoteWindow = 5 days;

    /// @inheritdoc ICourt
    uint256 public appealBondWood;

    /// @inheritdoc ICourt
    /// @dev 10% of `getPastTotalVotes` at the snapshot. Named in D6 as the
    ///      anti-capture parameter: §3.5 puts the token layer's failure mode at
    ///      "single-digit turnout, capturable at ~$15M mcap", and this is the
    ///      number that says an appeal below that turnout decides nothing rather
    ///      than deciding everything cheaply.
    uint256 public participationFloorBps = 1_000;

    /// @inheritdoc ICourt
    mapping(uint256 caseId => mapping(address voter => Ruling)) public appealVoteOf;

    /// @param initialOwner   The governance multisig that executes the off-chain
    ///                       panel election (D1).
    /// @param wood_          The WOOD token every bond here is denominated in.
    /// @param panelBondWood_ The per-member bond. Must be non-zero: a zero bond
    ///                       is a panel with no skin in the game, which is the
    ///                       entire binding incentive on panel behaviour.
    constructor(address initialOwner, address wood_, uint256 panelBondWood_) Ownable(initialOwner) {
        if (wood_ == address(0)) revert ZeroAddress();
        if (panelBondWood_ == 0) revert InvalidParameter();
        wood = IERC20(wood_);
        panelBondWood = panelBondWood_;
        emit PanelBondWoodSet(0, panelBondWood_);

        // The appeal bond starts at the panel bond so it is NEVER ZERO at any
        // point in the contract's life. A zero appeal bond would make appeals
        // free, and the below-floor forfeit — the only thing that prices a
        // failed quorum (D6) — would cost the appellant nothing. Governance
        // tunes it with `setAppealBondWood`, which also refuses zero.
        appealBondWood = panelBondWood_;
        emit AppealBondWoodSet(0, panelBondWood_);
    }

    // ─────────────────────────── Roster (D1) ───────────────────────────

    /// @inheritdoc ICourt
    /// @dev THE UNSEAT GUARD IS LOAD-BEARING. A member is refused unseating
    ///      while `_hasOpenRuling` holds, because Task 5's bad-faith track
    ///      slashes `panelBondOf[member]` and `withdrawPanelBond` opens the
    ///      moment a member leaves the roster. Without the guard, the owner (or
    ///      a member that lobbied the owner) could rotate a panelist out the
    ///      instant it made a corrupt ruling, its bond would become withdrawable
    ///      before anyone could vote on it, and the bond would stop binding
    ///      anything. It is a DELAY, not a life sentence: the lock expires with
    ///      the bad-faith window.
    function setPanel(address[] calldata members) external onlyOwner {
        uint256 newSize = members.length;
        if (newSize > MAX_PANEL_SIZE) revert InvalidParameter();

        // Validate before mutating: no zero address, no duplicates. A duplicate
        // would inflate `panelSize`, which Task 3's majority and
        // "every seat has voted" arithmetic reads.
        for (uint256 i; i < newSize; ++i) {
            if (members[i] == address(0)) revert ZeroAddress();
            for (uint256 j = i + 1; j < newSize; ++j) {
                if (members[i] == members[j]) revert InvalidParameter();
            }
        }

        uint256 oldSize = _panel.length;
        for (uint256 i; i < oldSize; ++i) {
            address member = _panel[i];
            if (_contains(members, member)) continue; // retained: seat, bond and lock untouched
            if (_hasOpenRuling(member)) revert PanelistHasOpenRuling();
            isPanelist[member] = false;
            emit PanelistUnseated(member);
        }

        delete _panel;
        for (uint256 i; i < newSize; ++i) {
            address member = members[i];
            if (!isPanelist[member]) {
                isPanelist[member] = true;
                emit PanelistSeated(member);
            }
            _panel.push(member);
        }

        emit PanelSet(oldSize, newSize);
    }

    /// @inheritdoc ICourt
    function panel() external view returns (address[] memory) {
        return _panel;
    }

    /// @inheritdoc ICourt
    function panelSize() external view returns (uint256) {
        return _panel.length;
    }

    // ─────────────────────────── Member bonds ───────────────────────────

    /// @inheritdoc ICourt
    /// @dev Pulls the SHORTFALL, not the full requirement, so a member that
    ///      already posted under a lower `panelBondWood` tops up rather than
    ///      double-paying. Effects before the interaction: `panelBondOf` and
    ///      `bondedWood` are written before the transfer, so a hooked WOOD
    ///      cannot re-enter and post twice against one balance.
    function postPanelBond() external {
        if (!isPanelist[msg.sender]) revert NotPanelist();
        uint256 posted = panelBondOf[msg.sender];
        uint256 required = panelBondWood;
        if (posted >= required) revert PanelBondAlreadyPosted();

        uint256 amount = required - posted;
        panelBondOf[msg.sender] = required;
        bondedWood += amount;
        wood.safeTransferFrom(msg.sender, address(this), amount);
        emit PanelBondPosted(msg.sender, amount);
    }

    /// @inheritdoc ICourt
    /// @dev TWO GUARDS, BOTH LOAD-BEARING:
    ///      1. `StillSeated` — a sitting panelist may not pull its bond, or it
    ///         would rule with nothing at stake.
    ///      2. `PanelistHasOpenRuling` — an unseated member may not pull its
    ///         bond while a bad-faith window is open against any of its
    ///         rulings, or the ruling it just made would be unpunishable.
    ///      Returns what was POSTED, not the current requirement: if the owner
    ///      lowered `panelBondWood` after the member bonded, the excess is the
    ///      member's and leaving it stranded would break the §4 equality.
    function withdrawPanelBond() external returns (uint256 amount) {
        if (isPanelist[msg.sender]) revert StillSeated();
        if (_hasOpenRuling(msg.sender)) revert PanelistHasOpenRuling();
        amount = panelBondOf[msg.sender];
        if (amount == 0) revert PanelBondNotPosted();

        panelBondOf[msg.sender] = 0;
        bondedWood -= amount;
        wood.safeTransfer(msg.sender, amount);
        emit PanelBondWithdrawn(msg.sender, amount);
    }

    /// @inheritdoc ICourt
    /// @dev Measured against the LIVE requirement, never "posted something
    ///      once": raising `panelBondWood` un-readies every member below the
    ///      new bar until it tops up, which is the point of raising it.
    function isReadyToRule(address member) public view returns (bool) {
        return isPanelist[member] && panelBondOf[member] >= panelBondWood;
    }

    // ──────────────────── Layer 1: the panel rules (§3.5) ────────────────────

    /// @inheritdoc ICourt
    /// @dev THE SNAPSHOT IS COMPUTED HERE, ONCE, AND STORED (decision D2). It is
    ///      `executedAt - 1` — the block before the challenged proposal
    ///      executed — which is the SAME instant §3.8's compensation claims use
    ///      and the same one Plan D hands `slashToEscrow` on the settle path.
    ///      One rule, three consumers. Storing it rather than re-deriving it in
    ///      each vote is what makes the electorate that judges guilt identical
    ///      to the set compensated out of the resulting slash, and it means the
    ///      merits appeal and the bad-faith vote cannot disagree about who is
    ///      entitled to vote — not even if the governor's proposal record moved
    ///      underneath them.
    /// @dev NOTHING HERE EXTENDS THE CHALLENGE'S OWN CLOCK. `ChallengeGame`
    ///      still fails a disputed challenge to the accused at
    ///      `filedAt + disputeTimeout`, so a referral filed very late leaves the
    ///      court too little time to reach a verdict and the fail-safe acquits.
    ///      That is deliberate — the court must not be able to pin a guardian's
    ///      frozen coverage indefinitely by opening a case — and it is why the
    ///      window ceilings above are sized against the timeout.
    function refer(uint256 challengeId) external returns (uint256 caseId) {
        address game = challengeGame;
        if (game == address(0)) revert ZeroAddress();
        if (caseOfChallenge[challengeId] != 0) revert AlreadyReferred();

        // Claim the challenge BEFORE reading anything external. The reads below
        // call out to `ch.governor` — an address the CHALLENGER supplied to
        // `ChallengeGame.file` and may therefore control. Today they are both
        // `view`, so the compiler emits STATICCALL and re-entry is impossible at
        // the EVM level; this ordering is what keeps that true if either
        // interface ever loses its `view`, because a governor re-entering with
        // the same id then hits `AlreadyReferred` rather than opening a second
        // case over one accusation — two panels, two snapshots, one challenge.
        // Both writes roll back with the transaction if a check below fails.
        caseId = ++caseCount;
        caseOfChallenge[challengeId] = caseId;

        IChallengeGame.Challenge memory ch = IChallengeGame(game).challengeOf(challengeId);
        // Only a contested challenge is escalated: a `Filed` one is still inside
        // its own auto-slash clock (silence is already the verdict there), and a
        // terminal one has nothing left to decide.
        if (ch.status != IChallengeGame.Status.Disputed) revert ChallengeNotDisputed();

        uint256 executedAt = ISyndicateGovernor(ch.governor).getProposal(ch.proposalId).executedAt;
        // Unreachable through a real filing — `ChallengeGame.file` rejects an
        // unexecuted proposal — but fail closed rather than underflow into a
        // snapshot at `type(uint256).max`, an instant nobody has voting power at.
        if (executedAt == 0) revert InvalidParameter();
        uint256 snapshotTs = executedAt - 1;

        Case storage c = _cases[caseId];
        c.challengeId = challengeId;
        c.snapshotTs = snapshotTs;
        c.referredAt = block.timestamp;
        c.phase = Phase.Panel;

        emit CaseReferred(caseId, challengeId, ch.governor, ch.proposalId, snapshotTs);
    }

    /// @inheritdoc ICourt
    /// @dev THE BOND LOCK IS THE POINT, not bookkeeping. Without it a panelist
    ///      could rule, be rotated off the roster and `withdrawPanelBond` before
    ///      anyone could open a bad-faith vote against that ruling — the F6
    ///      track (Task 5) would have nothing to slash and the only binding
    ///      incentive on panel behaviour would be decorative. The lock runs to
    ///      `referredAt + panelWindow + badFaithWindow`: the latest instant
    ///      layer 1 can close, plus a full bad-faith window.
    ///
    ///      THAT IS A FLOOR, NOT THE FINAL DEADLINE, because Task 5's window
    ///      opens when the CASE finalizes — later than the panel phase whenever
    ///      an appeal runs. `_resolve` therefore re-locks every member in
    ///      `_panelVoters[caseId]` to `finalizedAt + badFaithWindow` on BOTH
    ///      finalize paths; `_lockPanelBond` only ever extends, so the two
    ///      locks layer safely. Without that second lock a panelist could
    ///      escape the bad-faith slash simply by sitting out a long appeal.
    /// @dev ACCEPTED CONSEQUENCE: because unseating a locked member reverts, a
    ///      panelist can delay its own rotation off the roster by ruling. The
    ///      escape hatch is `setPanelBondWood` — raising the requirement makes
    ///      an under-bonded member un-ready to rule immediately (see
    ///      `isReadyToRule`) without waiting for its lock to expire.
    function panelRule(uint256 caseId, bool guilty) external {
        Case storage c = _cases[caseId];
        if (c.phase != Phase.Panel) revert WrongPhase();
        uint256 deadline = c.referredAt + panelWindow;
        if (block.timestamp >= deadline) revert WindowClosed();

        _requireReadyToRule(msg.sender);
        if (panelVoteOf[caseId][msg.sender] != Ruling.None) revert AlreadyRuled();

        panelVoteOf[caseId][msg.sender] = guilty ? Ruling.Guilty : Ruling.NotGuilty;
        _panelVoters[caseId].push(msg.sender);
        if (guilty) {
            c.panelGuiltyVotes += 1;
        } else {
            c.panelNotGuiltyVotes += 1;
        }

        _lockPanelBond(msg.sender, deadline + badFaithWindow);
        emit PanelVoteCast(caseId, msg.sender, guilty);
    }

    /// @inheritdoc ICourt
    /// @dev PERMISSIONLESS, and the caller chooses nothing: the verdict is a
    ///      function of the votes already cast and the clock.
    /// @dev A MAJORITY OF CAST VOTES CONVICTS; EVERYTHING ELSE ACQUITS. Both
    ///      non-majority cases are REAL PROPERTIES, deliberately chosen, not
    ///      artefacts of the arithmetic:
    ///
    ///      1. A PANEL THAT DOES NOT RULE WITHIN `panelWindow` YIELDS
    ///         `NotGuilty`. §3.5 hands this layer a 100% slash at
    ///         `maxSlashBps`; a panel that said nothing has not established the
    ///         ground truth that authorises it, so the court fails safe toward
    ///         not slashing — the same direction Plan D's D5 fails when no court
    ///         answers at all. The cost is stated rather than hidden: an
    ///         INACTIVE PANEL ACQUITS, so panel liveness is an operational
    ///         requirement, and the check on it is the appeal above (Task 4),
    ///         which can still convict where layer 1 was silent.
    ///      2. A TIE YIELDS `NotGuilty`, for the same reason: a panel split down
    ///         the middle has not established ground truth either. `>` rather
    ///         than `>=` is the whole implementation of that rule.
    /// @dev EARLY CLOSE ONCE EVERY SEAT HAS VOTED — there is nothing left to
    ///      wait for, and burning the rest of the window would only eat into the
    ///      challenge's `disputeTimeout`. Compared with `>=` because the roster
    ///      can shrink mid-case, which would otherwise leave votes cast by
    ///      since-unseated members exceeding `panelSize` and wedge the case in
    ///      `Panel` until the window elapsed. A roster emptied mid-case makes a
    ///      case finalizable at once, as `NotGuilty` — fail-safe again.
    function finalizePanel(uint256 caseId) external {
        Case storage c = _cases[caseId];
        if (c.phase != Phase.Panel) revert WrongPhase();

        uint256 guiltyVotes = c.panelGuiltyVotes;
        uint256 notGuiltyVotes = c.panelNotGuiltyVotes;
        if (block.timestamp < c.referredAt + panelWindow && guiltyVotes + notGuiltyVotes < _panel.length) {
            revert WindowOpen();
        }

        Ruling ruling = guiltyVotes > notGuiltyVotes ? Ruling.Guilty : Ruling.NotGuilty;
        c.panelRuling = ruling;
        c.panelFinalizedAt = block.timestamp;
        c.phase = Phase.AppealWindow;

        emit PanelFinalized(caseId, ruling, guiltyVotes, notGuiltyVotes);
    }

    // ─────────────── Layer 2: the token-vote appeal (§3.5) ───────────────

    /// @inheritdoc ICourt
    /// @dev PERMISSIONLESS, like `refer`. §3.5's second layer exists because a
    ///      five-person panel is bribable; gating who may invoke the check on
    ///      the panel would hand the same five people a say in whether they are
    ///      checked.
    /// @dev REQUIRES `stakedWood` WIRED, and refuses the appeal rather than the
    ///      later vote. A case that entered `Appeal` with no electorate to read
    ///      would have no way to finalize and would sit there until the
    ///      challenge's own `disputeTimeout` acquitted the accused — the exact
    ///      hole Plan E exists to close. Failing at the door leaves the ruling
    ///      unappealed instead, which `finalizeUnappealed` can still resolve.
    function appeal(uint256 caseId) external {
        Case storage c = _cases[caseId];
        if (c.phase != Phase.AppealWindow) revert WrongPhase();
        if (block.timestamp >= c.panelFinalizedAt + appealWindow) revert WindowClosed();
        if (stakedWood == address(0)) revert ZeroAddress();

        uint256 bond = appealBondWood;
        c.appellant = msg.sender;
        c.appealBond = bond;
        c.appealedAt = block.timestamp;
        c.phase = Phase.Appeal;
        bondedWood += bond;

        wood.safeTransferFrom(msg.sender, address(this), bond);
        emit AppealFiled(caseId, msg.sender, bond, block.timestamp + appealVoteWindow);
    }

    /// @inheritdoc ICourt
    /// @dev DO NOT RE-WEIGHT THE RESULT (D3). `getPastVotes` is documented by
    ///      `IStakedWood` as "AGE-WEIGHTED own staked + delegated-inbound capped
    ///      at `delegatedWeightCapX ×` aged own", which is precisely the
    ///      pre-accumulation defence §3.5 asks for. A second age curve here
    ///      would duplicate the staking contract's and inevitably diverge from
    ///      it.
    /// @dev THE ZERO-WEIGHT REVERT IS THE FLASH-LOAN DEFENCE, and it is a
    ///      consequence of the snapshot rather than a check of its own. Weight
    ///      is read at `c.snapshotTs` — `executedAt - 1`, the instant BEFORE the
    ///      challenged proposal executed — so WOOD bought or staked after the
    ///      drain, by the exploiter or by anyone who saw it happen, has no
    ///      weight at all. There is no borrow, no flash loan and no post-hoc
    ///      accumulation that reaches back past a stored timestamp.
    function voteAppeal(uint256 caseId, bool guilty) external {
        Case storage c = _cases[caseId];
        if (c.phase != Phase.Appeal) revert WrongPhase();
        if (block.timestamp >= c.appealedAt + appealVoteWindow) revert WindowClosed();
        if (appealVoteOf[caseId][msg.sender] != Ruling.None) revert AlreadyVoted();

        uint256 weight = IStakedWood(stakedWood).getPastVotes(msg.sender, c.snapshotTs);
        if (weight == 0) revert NoVotingPower();

        appealVoteOf[caseId][msg.sender] = guilty ? Ruling.Guilty : Ruling.NotGuilty;
        if (guilty) {
            c.appealGuiltyVotes += weight;
        } else {
            c.appealNotGuiltyVotes += weight;
        }

        emit AppealVoteCast(caseId, msg.sender, guilty, weight);
    }

    /// @inheritdoc ICourt
    /// @dev THE BELOW-FLOOR BRANCH IS THE ANTI-CAPTURE PROPERTY (D6), and it is
    ///      NOT "the appeal upheld the panel". An appeal that fails to raise a
    ///      quorum is a NON-EVENT: the votes that were cast are discarded even
    ///      when they went the other way, the panel's ruling stands untouched,
    ///      and the appellant's bond forfeits for failing to raise an
    ///      electorate. That is what removes the "swing a single-digit-turnout
    ///      appeal cheaply at a ~$15M mcap" path §3.5 names as the token layer's
    ///      failure mode. It gets its own event so no indexer can confuse the
    ///      two, and the bond forfeits precisely because the appellant chose to
    ///      escalate and then did not deliver the turnout that would have made
    ///      the escalation mean something.
    /// @dev A ZERO-TURNOUT APPEAL ALSO LEAVES THE PANEL STANDING, even in the
    ///      degenerate case where the floor itself computes to zero because the
    ///      snapshot's total vote weight is zero or dust. A vote nobody cast has
    ///      not overturned anything, and without this the arithmetic would flip
    ///      a `Guilty` panel ruling to `NotGuilty` on an empty tally.
    /// @dev ABOVE THE FLOOR, A TIE ACQUITS — the same fail-safe `finalizePanel`
    ///      applies for the same reason: an electorate split down the middle has
    ///      not established the ground truth §3.5 requires before a 100% slash.
    /// @dev THE APPEAL BOND IS NOT A FEE ON LOSING. Above the floor it returns
    ///      whichever way the vote went, including a vote that upheld the panel:
    ///      the appellant did the thing the mechanism wanted — it brought the
    ///      question to the electorate — and pricing a good-faith appeal that
    ///      loses would deter exactly the check §3.5 put above the panel.
    function finalizeAppeal(uint256 caseId) external {
        Case storage c = _cases[caseId];
        if (c.phase != Phase.Appeal) revert WrongPhase();
        if (block.timestamp < c.appealedAt + appealVoteWindow) revert WindowOpen();

        uint256 guiltyVotes = c.appealGuiltyVotes;
        uint256 notGuiltyVotes = c.appealNotGuiltyVotes;
        uint256 turnout = guiltyVotes + notGuiltyVotes;
        uint256 floor =
            participationFloorBps * IStakedWood(stakedWood).getPastTotalVotes(c.snapshotTs) / BPS_DENOMINATOR;

        uint256 bond = c.appealBond;
        c.appealBond = 0;
        bondedWood -= bond;

        Ruling ruling;
        bool refund;
        if (turnout == 0 || turnout < floor) {
            ruling = c.panelRuling;
            forfeitedWood += bond;
            emit AppealBelowFloor(caseId, turnout, floor, ruling, bond);
        } else {
            ruling = guiltyVotes > notGuiltyVotes ? Ruling.Guilty : Ruling.NotGuilty;
            refund = true;
            emit AppealFinalized(caseId, ruling, guiltyVotes, notGuiltyVotes, floor);
        }

        // Every state write above and inside `_resolve` lands before either
        // external call, and `_resolve` leaves the case `Resolved`, so neither
        // the challenge game nor the appellant can re-enter this function.
        _resolve(caseId, c, ruling);

        if (refund) {
            address appellant = c.appellant;
            wood.safeTransfer(appellant, bond);
            emit AppealBondReturned(caseId, appellant, bond);
        }
    }

    /// @inheritdoc ICourt
    /// @dev The quiet path, and the common one: nobody appealed, so layer 1's
    ///      ruling is the court's. Permissionless, and the caller chooses
    ///      nothing — the verdict is `c.panelRuling` and the clock decides when.
    function finalizeUnappealed(uint256 caseId) external {
        Case storage c = _cases[caseId];
        if (c.phase != Phase.AppealWindow) revert WrongPhase();
        if (block.timestamp < c.panelFinalizedAt + appealWindow) revert WindowOpen();
        _resolve(caseId, c, c.panelRuling);
    }

    /// @inheritdoc ICourt
    function panelVoters(uint256 caseId) external view returns (address[] memory) {
        return _panelVoters[caseId];
    }

    /// @inheritdoc ICourt
    function caseOf(uint256 caseId) external view returns (Case memory) {
        return _cases[caseId];
    }

    /// @dev THE ONE PLACE A CASE BECOMES TERMINAL. Shared by both finalize
    ///      paths so the three things that must happen on every branch — write
    ///      the verdict, RE-LOCK THE RULING PANELISTS' BONDS, hand the bit to
    ///      `ChallengeGame.rule` — cannot be done on one path and forgotten on
    ///      the other.
    /// @dev THE RE-LOCK IS F6's DEFENCE, NOT BOOKKEEPING. `panelRule` could only
    ///      lock to `referredAt + panelWindow + badFaithWindow`, because the
    ///      instant the CASE finalizes did not exist yet. Task 5's bad-faith
    ///      window opens HERE, which is later whenever an appeal ran, so without
    ///      this extension a panelist could make a corrupt ruling, wait out a
    ///      long appeal, withdraw its bond the moment the panel-phase lock
    ///      expired and leave the bad-faith track with nothing to slash. The
    ///      entire binding incentive on panel behaviour would be decorative.
    /// @dev The verdict is a SINGLE BIT by the time it leaves here (D7): §3.5
    ///      treats a guilty finding as ground truth and Plan D's `_settle`
    ///      slashes at `maxSlashBps` with no severity ramp, so there is nothing
    ///      else for the court to say.
    function _resolve(uint256 caseId, Case storage c, Ruling ruling) internal {
        c.finalRuling = ruling;
        c.finalizedAt = block.timestamp;
        c.phase = Phase.Resolved;

        uint256 until = block.timestamp + badFaithWindow;
        address[] storage voters = _panelVoters[caseId];
        uint256 n = voters.length;
        for (uint256 i; i < n; ++i) {
            _lockPanelBond(voters[i], until);
        }

        emit CaseResolved(caseId, c.challengeId, ruling);
        IChallengeGame(challengeGame).rule(c.challengeId, ruling == Ruling.Guilty);
    }

    // ─────────────────────── Hooks for Tasks 4-5 ───────────────────────

    /// @dev The single choke point `panelRule` calls before recording a vote.
    ///      Split from `isReadyToRule` only to report which of the two
    ///      preconditions failed.
    function _requireReadyToRule(address member) internal view {
        if (!isPanelist[member]) revert NotPanelist();
        if (panelBondOf[member] < panelBondWood) revert PanelBondNotPosted();
    }

    /// @dev Whether `member`'s bond is still needed by the bad-faith track.
    ///      `panelRule` is what makes this live: a member that records a ruling
    ///      is locked to `referredAt + panelWindow + badFaithWindow`, so the
    ///      roster and withdraw guards above genuinely bite from the moment it
    ///      votes. TASK 4 extends the lock to the case's actual finalization
    ///      plus `badFaithWindow`, and TASK 5 extends it again for as long as a
    ///      bad-faith vote against that ruling stays open.
    function _hasOpenRuling(address member) internal view returns (bool) {
        return block.timestamp < panelBondLockedUntil[member];
    }

    /// @dev Extends `member`'s bond lock to `until`. NEVER shortens it: two
    ///      open rulings against one member must not let the earlier deadline
    ///      release the bond the later one still needs.
    function _lockPanelBond(address member, uint256 until) internal {
        if (until > panelBondLockedUntil[member]) {
            panelBondLockedUntil[member] = until;
            emit PanelBondLocked(member, until);
        }
    }

    // ─────────────────────────── Owner setters ───────────────────────────

    /// @inheritdoc ICourt
    /// @dev Governs future posts and future readiness only; it never moves WOOD
    ///      already posted, so `bondedWood` is untouched here. Raising it leaves
    ///      seated members un-ready (see `isReadyToRule`) until they top up;
    ///      lowering it leaves them over-bonded until they withdraw.
    function setPanelBondWood(uint256 newBond) external onlyOwner {
        if (newBond == 0) revert InvalidParameter();
        emit PanelBondWoodSet(panelBondWood, newBond);
        panelBondWood = newBond;
    }

    /// @inheritdoc ICourt
    /// @dev NO ZERO ESCAPE HERE, unlike `ChallengeGame.setCourt`. The off-switch
    ///      lives on the game's side — unwiring the court there returns the game
    ///      to D5's fail-safe timeout — whereas a court pointed at nothing could
    ///      only refuse to open cases, which is a worse way to say the same
    ///      thing.
    function setChallengeGame(address newGame) external onlyOwner {
        if (newGame == address(0)) revert ZeroAddress();
        emit ChallengeGameSet(challengeGame, newGame);
        challengeGame = newGame;
    }

    /// @inheritdoc ICourt
    /// @dev Bounded `(0, MAX_PANEL_WINDOW]`: a zero window would close layer 1
    ///      before any panelist could vote, making every case an automatic
    ///      acquittal, and the ceiling keeps the panel phase from eating the
    ///      challenge's `disputeTimeout` (see the constant).
    /// @dev Applies to LIVE cases too, since the deadline is derived from
    ///      `referredAt` at read time rather than stored. That is the honest
    ///      shape for a governance parameter — a change takes effect everywhere
    ///      at once — but it means shortening the window can close an open panel
    ///      phase immediately, which acquits. Task 7's pre-flight is where the
    ///      windows are set; changing them with cases open is an operational
    ///      decision, not something a setter invariant can make safe.
    function setPanelWindow(uint256 newWindow) external onlyOwner {
        if (newWindow == 0 || newWindow > MAX_PANEL_WINDOW) revert InvalidParameter();
        emit PanelWindowSet(panelWindow, newWindow);
        panelWindow = newWindow;
    }

    /// @inheritdoc ICourt
    /// @dev Bounded `(0, MAX_BAD_FAITH_WINDOW]`. A ZERO WINDOW IS REFUSED
    ///      HERE, not only at Task 7's deploy pre-flight: it would mean the F6
    ///      track can never open, and a panel whose rulings can never be
    ///      challenged for bad faith is a bribable panel holding authority over
    ///      100% slashes.
    function setBadFaithWindow(uint256 newWindow) external onlyOwner {
        if (newWindow == 0 || newWindow > MAX_BAD_FAITH_WINDOW) revert InvalidParameter();
        emit BadFaithWindowSet(badFaithWindow, newWindow);
        badFaithWindow = newWindow;
    }

    /// @inheritdoc ICourt
    /// @dev No zero escape, for the same reason as `setChallengeGame`: a court
    ///      with no electorate to read cannot run layer 2, and §3.5 is explicit
    ///      that neither layer is safe alone.
    function setStakedWood(address newStakedWood) external onlyOwner {
        if (newStakedWood == address(0)) revert ZeroAddress();
        emit StakedWoodSet(stakedWood, newStakedWood);
        stakedWood = newStakedWood;
    }

    /// @inheritdoc ICourt
    /// @dev Bounded `(0, MAX_APPEAL_WINDOW]`. A zero window would close the
    ///      appeal before anyone could file one, making the panel final and
    ///      leaving the bribable half of §3.5 unchecked.
    function setAppealWindow(uint256 newWindow) external onlyOwner {
        if (newWindow == 0 || newWindow > MAX_APPEAL_WINDOW) revert InvalidParameter();
        emit AppealWindowSet(appealWindow, newWindow);
        appealWindow = newWindow;
    }

    /// @inheritdoc ICourt
    /// @dev Bounded `(0, MAX_APPEAL_VOTE_WINDOW]`. A zero window would let an
    ///      appeal be filed and finalized in one block on whatever votes the
    ///      filer could line up in the same transaction.
    function setAppealVoteWindow(uint256 newWindow) external onlyOwner {
        if (newWindow == 0 || newWindow > MAX_APPEAL_VOTE_WINDOW) revert InvalidParameter();
        emit AppealVoteWindowSet(appealVoteWindow, newWindow);
        appealVoteWindow = newWindow;
    }

    /// @inheritdoc ICourt
    /// @dev Zero refused: it would make appeals free and delete the only price
    ///      on failing to raise a quorum. Governs FUTURE appeals only — an open
    ///      appeal is owed the `c.appealBond` it actually posted.
    function setAppealBondWood(uint256 newBond) external onlyOwner {
        if (newBond == 0) revert InvalidParameter();
        emit AppealBondWoodSet(appealBondWood, newBond);
        appealBondWood = newBond;
    }

    /// @inheritdoc ICourt
    /// @dev Bounded `(0, BPS_DENOMINATOR]`. ZERO IS REFUSED AT THE SETTER, not
    ///      only at Task 7's deploy pre-flight: a zero floor silently deletes
    ///      D6, and every appeal — including one swung by a handful of tokens
    ///      bought for the purpose — would override the panel.
    /// @dev The ceiling is the honest one rather than a comfortable one. A floor
    ///      at 100% of `getPastTotalVotes` is unreachable in practice and makes
    ///      the panel final; that is a governance decision this setter reports
    ///      through its event rather than one it can prevent.
    function setParticipationFloorBps(uint256 newBps) external onlyOwner {
        if (newBps == 0 || newBps > BPS_DENOMINATOR) revert InvalidParameter();
        emit ParticipationFloorBpsSet(participationFloorBps, newBps);
        participationFloorBps = newBps;
    }

    /// @inheritdoc ICourt
    /// @dev Only ever moves `forfeitedWood`, never `bondedWood`, so no open
    ///      panel bond or live appeal can be swept out from under its owner —
    ///      the §4 equality is what makes that guarantee checkable.
    function sweepForfeited(address to) external onlyOwner returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = forfeitedWood;
        if (amount == 0) revert InvalidParameter();

        forfeitedWood = 0;
        wood.safeTransfer(to, amount);
        emit ForfeitedWoodSwept(to, amount);
    }

    // ─────────────────────────── Internals ───────────────────────────

    function _contains(address[] calldata list, address member) private pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == member) return true;
        }
        return false;
    }
}
