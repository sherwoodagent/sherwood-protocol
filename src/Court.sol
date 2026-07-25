// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICourt} from "./interfaces/ICourt.sol";
import {IChallengeGame} from "./interfaces/IChallengeGame.sol";
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";
import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {IStakedWood} from "./interfaces/IStakedWood.sol";

/// @notice The one thing the court needs from the challenge game that
///         `IChallengeGame` does not declare: WHICH LEDGER THE GAME TRUSTS.
/// @dev    READ FROM THE GAME, NEVER FROM THE GOVERNOR, and the distinction is
///         load-bearing. `ISyndicateGovernor` also exposes an `exposureLedger`,
///         but `ch.governor` is an address the CHALLENGER handed
///         `ChallengeGame.file` and may control — a hostile governor could
///         return a ledger reporting no approvers at all, which would empty the
///         accused set and delete the exclusion entirely. The game's
///         `exposureLedger` is owner-set on the game itself and is the very
///         ledger `ChallengeGame._accused` reads when it builds the slash list,
///         so taking the address from there is what keeps "barred from voting"
///         and "slashed on conviction" ONE set rather than two that merely look
///         alike.
interface IChallengeGameLedger {
    function exposureLedger() external view returns (address);
}

/**
 * @title Court
 * @notice Adjudication of disputed challenges (spec 2026-07-22 §3.5, Plan E).
 *         Plan D left a disputed challenge terminal-with-timeout, which means a
 *         genuinely guilty approver can dispute and run out the clock. The
 *         court closes that hole: a bonded panel rules, that ruling is
 *         appealable to a full WOOD vote, and the outcome drives
 *         `ChallengeGame.rule`.
 *
 * @dev    THIS REVISION IS THE WHOLE MECHANISM (Plan E Tasks 2-5): the roster
 *         and member bonds, layer 1's panel, layer 2's token-vote appeal, and
 *         the bad-faith track that is the only thing able to slash a panel bond.
 *
 * @dev    THE BAD-FAITH TRACK IS A SEPARATE VOTE FROM THE MERITS APPEAL (D4,
 *         finding F6), and that separation is the security core of this
 *         contract. If bad faith were decided by the merits appeal, an attacker
 *         who controls the cheap appeal layer would collect BOTH prizes at once:
 *         a corrupt ruling made safe, and the honest panelists who voted against
 *         it slashed for it. The independence runs in both directions — being
 *         overturned on the merits never slashes a panelist, and winning the
 *         merits appeal never immunizes one.
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
 *         `bondedWood` is every WOOD POSITION SOMEBODY POSTED and can still get
 *         back — panel bonds, and the bonds of appeals and bad-faith votes still
 *         open — and `forfeitedWood` is what the protocol now owns: appeal bonds
 *         that missed the participation floor and panel bonds slashed for bad
 *         faith. TWO TERMS, NOT THREE: every transfer between the buckets moves
 *         the same amount out of one and into the other in a single statement,
 *         so the equality holds at every intermediate step and not merely at
 *         rest. The equality is exact except for WOOD somebody donated here by
 *         mistake, which no path ever spends.
 *
 * @dev    `reservedRewards` IS A SUBSET OF `forfeitedWood`, NOT A THIRD TERM.
 *         `forfeitedWood >= reservedRewards` holds always, so the two-term
 *         equality above is untouched by it. Panel rewards are paid out of the
 *         protocol-owned pot, so an accrued-but-unclaimed reward is still
 *         forfeited WOOD — it is merely forfeited WOOD already committed to a
 *         named payee. Tracking it as a subset rather than moving it into
 *         `bondedWood` keeps `bondedWood` meaning exactly one thing ("somebody
 *         posted this, and it answers to a bond rule"). What the subset buys is
 *         `burnForfeited`: the burn may only ever take
 *         `forfeitedWood - reservedRewards`, so a resolved case's rewards cannot
 *         be destroyed out from under the panel that earned them.
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

    /// @notice Where `burnForfeited` sends the pot — permanently out of anyone's
    ///         reach, including the owner's.
    /// @dev    A TRANSFER TO A DEAD ADDRESS, NOT A TRUE SUPPLY REDUCTION. WOOD is
    ///         a plain `IERC20` with no `burn` and no post-deploy mint, so the
    ///         court cannot lower `totalSupply`; the nearest available thing is a
    ///         send to an address whose private key nobody has. `totalSupply`
    ///         therefore does not move, and holders should read circulating
    ///         supply net of this balance. `StakedWood` burns slashed WOOD the
    ///         same way and to the same address, so the two contracts' burnt
    ///         WOOD lands in one auditable place.
    /// @dev    `address(0)` is NOT usable here: OpenZeppelin's `ERC20._update`
    ///         reverts `ERC20InvalidReceiver` on a transfer to the zero address,
    ///         so `safeTransfer(address(0), ...)` would make the burn revert
    ///         rather than burn.
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

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
    ///      deadline simply expires. `openBadFaithVotes` is the counterpart for
    ///      proceedings that WERE opened, where the reverse holds — see its
    ///      declaration for why the two guards are different shapes.
    mapping(address member => uint256) public panelBondLockedUntil;

    /// @inheritdoc ICourt
    /// @dev Counts EVERY posted panel bond, seated or not: an unseated member
    ///      whose bond is still locked against the bad-faith track is still
    ///      WOOD this contract holds and must still balance.
    uint256 public bondedWood;

    /// @inheritdoc ICourt
    /// @dev Grows in exactly two places — `finalizeAppeal`'s below-floor branch
    ///      and `finalizeBadFaith`'s slash — and shrinks in exactly two:
    ///      `burnForfeited` and `claimPanelReward`. Never overlaps `bondedWood`:
    ///      value moves from one to the other in the same statement, so the §4
    ///      equality holds across every transition.
    /// @dev CONTAINS `reservedRewards`. The part of this number equal to
    ///      `reservedRewards` is spoken for by resolved cases and only
    ///      `claimPanelReward` may spend it; the remainder is the unreserved
    ///      surplus and only `burnForfeited` may spend that.
    /// @dev ONE SINK, AND DELIBERATELY NOT `CompensationEscrow`. A slashed panel
    ///      bond is not the value that was drained, and `openCase` fixes a case's
    ///      `proceeds` at open time precisely to keep per-case funds isolated (a
    ///      critical Plan C fix) — crediting an unrelated slash into a victim
    ///      case would inflate its proceeds and pay claimants out of money that
    ///      was never theirs.
    uint256 public forfeitedWood;

    /// @inheritdoc ICourt
    /// @dev A SUBSET OF `forfeitedWood`, never a term beside it. Grows only in
    ///      `_accruePanelRewards`, which reserves against the UNRESERVED surplus
    ///      and so can never push this past `forfeitedWood`; shrinks only in
    ///      `claimPanelReward`, which decrements it and `forfeitedWood` by the
    ///      same amount in the same statement. `forfeitedWood >= reservedRewards`
    ///      therefore holds at every intermediate step.
    /// @dev WHY RESERVE AT ALL: the reward is all-or-nothing, so a burn landing
    ///      between a case's resolution and its panelists' claims would leave the
    ///      credits standing with nothing behind them. That is not merely a
    ///      bookkeeping defect — an unpaid panel is an absent panel, and a panel
    ///      that does not rule inside `panelWindow` acquits by default. Funding
    ///      the reward is a LIVENESS property of layer 1, so the liability is set
    ///      aside the instant it accrues rather than hoped for at claim time.
    uint256 public reservedRewards;

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

    /// @inheritdoc ICourt
    /// @dev WRITTEN ONCE, IN `refer`, AND NEVER AGAIN — the same discipline
    ///      `snapshotTs` follows (D2), and for the same reason: two votes on one
    ///      case must not be able to disagree about who is barred. Deriving
    ///      membership at vote time from the live ledger would let a commitment
    ///      released mid-case re-enfranchise an approver halfway through the
    ///      appeal it is the defendant in.
    mapping(uint256 caseId => mapping(address approver => bool)) public isAccused;

    /// @dev The same set as an array, for `accusedOf` and for indexers. Bounded
    ///      by the ledger's approver list, which `ChallengeGame` already walks
    ///      in full on every settle — so nothing here is reachable at a size the
    ///      slash path could not already reach.
    mapping(uint256 caseId => address[]) internal _accused;

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

    // ───────────── The bad-faith track: F6's defence (Task 5) ─────────────

    /// @inheritdoc ICourt
    uint256 public badFaithBondWood;

    /// @inheritdoc ICourt
    /// @dev Starts at zero — rewards are opt-in, because a court deployed with
    ///      an empty forfeited pot has nothing to pay them from.
    uint256 public panelRewardWood;

    mapping(uint256 caseId => mapping(address panelist => BadFaithVote)) internal _badFaith;

    /// @inheritdoc ICourt
    mapping(uint256 caseId => mapping(address panelist => mapping(address voter => Ruling))) public badFaithVoteOf;

    /// @inheritdoc ICourt
    /// @dev The second half of the bond lock, alongside `panelBondLockedUntil`.
    ///      See the interface for why this one is a counter where that one is a
    ///      deadline.
    mapping(address member => uint256) public openBadFaithVotes;

    /// @inheritdoc ICourt
    mapping(address member => uint256) public panelRewardOf;

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

        // Same reasoning for the bad-faith bond, in the other direction: it is
        // never zero so opening a proceeding is never entirely free, and
        // `setBadFaithBondWood` refuses zero for the same reason. It is not a
        // price on being wrong — it returns on every branch — only a floor under
        // the cost of opening one.
        badFaithBondWood = panelBondWood_;
        emit BadFaithBondWoodSet(0, panelBondWood_);
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

        // THE ACCUSED SET IS FIXED HERE, under the same rule as the snapshot
        // directly above it. Both votes this case will run are checks ON the
        // panel that judges the accused, so the accused are barred from both,
        // and the weight barred is subtracted from the participation floor's
        // base — see `_participationFloor`.
        _recordAccused(caseId, c, game, ch.governor, ch.proposalId, snapshotTs);
    }

    /// @dev MIRRORS `ChallengeGame._accused` EXACTLY, and deliberately does not
    ///      invent a second definition: the ledger's covering approvers,
    ///      filtered to those whose committed share is still non-zero. The
    ///      ledger reports a RELEASED commitment as zero rather than dropping
    ///      the entry, and a guardian that released before the filing backed
    ///      nothing on this proposal — so it is not slashed for it, and by the
    ///      same token it is not barred from voting on it. The set that loses
    ///      its stake on a conviction and the set that may not vote on that
    ///      conviction are one list read from one place.
    /// @dev THE LEDGER COMES FROM THE GAME, NOT FROM `governor`. See
    ///      `IChallengeGameLedger` for why substituting the challenger-supplied
    ///      governor's ledger would hand the accused an empty accused set.
    /// @dev WEIGHT IS SUMMED AT `snapshotTs`, the case's stored instant, so the
    ///      number subtracted from the floor is measured on exactly the same
    ///      electorate as the votes it is compared against. It is computed here
    ///      and only here; `voteAppeal`, `finalizeAppeal`, `voteBadFaith` and
    ///      `finalizeBadFaith` all read the stored value.
    /// @dev A DOUBLE-LISTED APPROVER WOULD DOUBLE-COUNT ITS WEIGHT, so the
    ///      `isAccused` flag is checked before accumulating. The ledger does not
    ///      produce duplicates today; the guard costs one warm SLOAD and makes
    ///      the floor's denominator independent of that.
    function _recordAccused(
        uint256 caseId,
        Case storage c,
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
            if (isAccused[caseId][approver]) continue;

            isAccused[caseId][approver] = true;
            _accused[caseId].push(approver);
            count += 1;
            // A court with no electorate wired cannot weigh anyone. `appeal` and
            // `openBadFaith` both refuse to open with `stakedWood` unset, so a
            // case referred in that state can never reach a vote and the weight
            // it would have subtracted is never read.
            if (swood != address(0)) weight += IStakedWood(swood).getPastVotes(approver, snapshotTs);
        }

        c.accusedWeight = weight;
        emit AccusedSetRecorded(caseId, count, weight);
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
    /// @dev THE ACCUSED MAY NOT VOTE, and this is the check the snapshot alone
    ///      could never make. The snapshot bars whoever bought in AFTER the
    ///      drain; it says nothing about the approvers who were already large
    ///      holders BEFORE it — and those are exactly the defendants, because a
    ///      guardian has to stake WOOD to back coverage at all. Left in, they
    ///      are routinely enough on their own to clear the participation floor
    ///      and carry the vote. §3.5 puts this layer above the panel to CHECK a
    ///      possibly-corrupt panel; a defendant that can outvote its own jury
    ///      inverts it, so a correct conviction is overturned by the party it
    ///      convicted.
    /// @dev THE BAR IS PAID FOR IN THE FLOOR'S DENOMINATOR, NOT CHARGED TO THE
    ///      HONEST VOTERS WHO REMAIN. Removing weight from the numerator while
    ///      still measuring against the whole electorate would raise the bar
    ///      turnout has to clear, more appeals would land below the floor, and
    ///      below the floor THE PANEL'S RULING STANDS — trading "the accused
    ///      self-acquit" for "a bribed panel is harder to overturn", which is
    ///      the other half of the failure §3.5 stacks two layers against. See
    ///      `_participationFloor`.
    function voteAppeal(uint256 caseId, bool guilty) external {
        Case storage c = _cases[caseId];
        if (c.phase != Phase.Appeal) revert WrongPhase();
        if (block.timestamp >= c.appealedAt + appealVoteWindow) revert WindowClosed();
        if (appealVoteOf[caseId][msg.sender] != Ruling.None) revert AlreadyVoted();
        if (isAccused[caseId][msg.sender]) revert AccusedCannotVote();

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
        uint256 floor = _participationFloor(c.snapshotTs, c.accusedWeight);

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

    // ────────────── The bad-faith track: F6's defence (D4) ──────────────

    /// @inheritdoc ICourt
    /// @dev THE TARGET SET IS `_panelVoters[caseId]`, checked here through
    ///      `panelVoteOf`. It is stored per case rather than read off the live
    ///      roster because a member can be rotated off once its lock expires,
    ///      and the track must still be able to answer for what it did while it
    ///      sat. For the same reason nothing here requires the target to still
    ///      be seated.
    /// @dev THE OPEN COUNTER IS WHAT KEEPS THE BOND IN REACH. Incrementing it
    ///      re-locks the bond for as long as this proceeding runs, on top of
    ///      whatever `panelBondLockedUntil` already says. Without it a panelist
    ///      could withdraw in the same block the deadline lock expired, front-
    ///      running the `finalizeBadFaith` that was about to slash it — the
    ///      deadline alone leaves exactly that race, because a vote opened near
    ///      the end of `badFaithWindow` outlives it.
    /// @dev REQUIRES `stakedWood` WIRED, refused at the door for the same reason
    ///      `appeal` refuses it: a proceeding opened with no electorate to read
    ///      could never be finalized, and its bond and the panelist's lock would
    ///      both be stranded permanently.
    function openBadFaith(uint256 caseId, address panelist) external {
        Case storage c = _cases[caseId];
        // The window opens at the CASE's resolution, not at the panel phase:
        // until the court has actually spoken there is no ruling to answer for,
        // and an appeal can still change what the ruling meant.
        if (c.phase != Phase.Resolved) revert WrongPhase();
        if (block.timestamp >= c.finalizedAt + badFaithWindow) revert WindowClosed();
        if (panelVoteOf[caseId][panelist] == Ruling.None) revert PanelistDidNotRule();
        if (stakedWood == address(0)) revert ZeroAddress();

        BadFaithVote storage bf = _badFaith[caseId][panelist];
        if (bf.openedAt != 0) revert BadFaithAlreadyOpened();

        uint256 bond = badFaithBondWood;
        bf.opener = msg.sender;
        bf.bond = bond;
        bf.openedAt = block.timestamp;
        bondedWood += bond;
        openBadFaithVotes[panelist] += 1;

        wood.safeTransferFrom(msg.sender, address(this), bond);
        emit BadFaithOpened(caseId, panelist, msg.sender, bond, block.timestamp + appealVoteWindow);
    }

    /// @inheritdoc ICourt
    /// @dev THE QUESTION IS CONDUCT, NOT THE MERITS (D4). A voter may believe the
    ///      panel got the answer wrong and still vote `false` here; that is the
    ///      normal case, and it is why the merits appeal exists separately. What
    ///      this vote decides is whether the ruling was made in bad faith, which
    ///      is the only thing §3.5 lets anyone take a panelist's bond for.
    /// @dev THE ELECTORATE IS THE CASE'S, READ FROM STORAGE. `c.snapshotTs` was
    ///      fixed in `refer` at `executedAt - 1` (D2) and is never recomputed, so
    ///      this vote and the merits appeal are decided by exactly the same
    ///      holders at exactly the same instant — nobody who bought in after the
    ///      drain can vote to protect the panelist that acquitted them, and no
    ///      later reorganisation of the governor's records can move the roll.
    ///      `getPastVotes` has ALREADY applied the age curve (D3); do not
    ///      re-weight.
    /// @dev THE ACCUSED ARE BARRED HERE AS WELL AS IN THE MERITS APPEAL, and
    ///      that was decided rather than inherited. The question is genuinely a
    ///      different one — a PANELIST's conduct, not the approver's guilt — and
    ///      the accused have a real interest in an honest panel. What decides it
    ///      is their position relative to THIS defendant: a convicted approver
    ///      losing 100% of its stake is the party with the largest motive in the
    ///      system to take the bond of the panelist who convicted it, and by
    ///      construction (guardians stake WOOD to back coverage) usually the
    ///      weight to do it. Retaliation is not a merits question but its effect
    ///      is: a panel that knows conviction puts its bond at the mercy of the
    ///      convicted acquits, so leaving the accused in this electorate lets
    ///      them bias every verdict — their own included, ex ante — without
    ///      casting a single merits vote. It costs the track nothing it needs:
    ///      `openBadFaith` stays permissionless, so an accused that genuinely
    ///      spotted a corrupt panelist can still put the question; it simply may
    ///      not answer it. And it keeps this function's own first claim true —
    ///      the two votes really are decided by one electorate under one rule.
    function voteBadFaith(uint256 caseId, address panelist, bool badFaith) external {
        BadFaithVote storage bf = _badFaith[caseId][panelist];
        if (bf.openedAt == 0 || bf.resolved) revert BadFaithNotOpen();
        if (block.timestamp >= bf.openedAt + appealVoteWindow) revert WindowClosed();
        if (badFaithVoteOf[caseId][panelist][msg.sender] != Ruling.None) revert AlreadyVoted();
        if (isAccused[caseId][msg.sender]) revert AccusedCannotVote();

        uint256 weight = IStakedWood(stakedWood).getPastVotes(msg.sender, _cases[caseId].snapshotTs);
        if (weight == 0) revert NoVotingPower();

        badFaithVoteOf[caseId][panelist][msg.sender] = badFaith ? Ruling.Guilty : Ruling.NotGuilty;
        if (badFaith) {
            bf.badFaithVotes += weight;
        } else {
            bf.goodFaithVotes += weight;
        }

        emit BadFaithVoteCast(caseId, panelist, msg.sender, badFaith, weight);
    }

    /// @inheritdoc ICourt
    /// @dev SAME PARTICIPATION FLOOR AS THE APPEAL, and for the same anti-capture
    ///      reason (D6): a handful of tokens bought for the purpose must not be
    ///      able to take an honest panelist's bond any more than they can
    ///      overturn a ruling. Below the floor the proceeding decides nothing and
    ///      the panelist is left whole — that branch is a NON-EVENT, not an
    ///      acquittal, and it is why `ParticipationFloorNotMet` is not raised
    ///      here: failing to reach the floor is an outcome, not an error.
    /// @dev THE SLASH IS THE POSTED BOND, NOT THE CURRENT REQUIREMENT, mirroring
    ///      `withdrawPanelBond`: whatever the member actually has at stake is
    ///      what answers for the ruling, whichever way `panelBondWood` moved
    ///      since. A member already slashed by another case simply has nothing
    ///      left to take, which is a no-op rather than a revert — the proceeding
    ///      still concludes and the opener still gets its bond back.
    /// @dev SLASHED BONDS LAND IN `forfeitedWood`, THE EXISTING SINK, and never
    ///      in `CompensationEscrow`'s per-case claims. A corrupt panelist's bond
    ///      is not the value that was drained: `openCase` fixes a case's
    ///      `proceeds` at open time precisely to keep per-case funds isolated (a
    ///      critical Plan C fix), so crediting an unrelated slash into a victim
    ///      case would inflate its proceeds and pay claimants out of money that
    ///      was never theirs. One sink, and its only exits are the panel reward
    ///      and the permissionless `burnForfeited` — nobody, the owner included,
    ///      can direct a slashed bond anywhere.
    /// @dev THE PANELIST KEEPS ITS SEAT AND ITS ACCRUED REWARD; it loses its
    ///      bond, which drops it below `panelBondWood` and so out of
    ///      `isReadyToRule` until it posts again. Removing it from the roster is
    ///      the owner's call (D1) — the contract does not silently re-run the
    ///      election.
    function finalizeBadFaith(uint256 caseId, address panelist) external {
        BadFaithVote storage bf = _badFaith[caseId][panelist];
        if (bf.openedAt == 0 || bf.resolved) revert BadFaithNotOpen();
        if (block.timestamp < bf.openedAt + appealVoteWindow) revert WindowOpen();

        uint256 badFaithVotes = bf.badFaithVotes;
        uint256 goodFaithVotes = bf.goodFaithVotes;
        uint256 turnout = badFaithVotes + goodFaithVotes;
        Case storage c = _cases[caseId];
        uint256 floor = _participationFloor(c.snapshotTs, c.accusedWeight);

        // Terminal before either transfer, and the open counter is released
        // here: a re-entrant call finds `resolved` set and hits BadFaithNotOpen.
        bf.resolved = true;
        openBadFaithVotes[panelist] -= 1;

        uint256 bond = bf.bond;
        bf.bond = 0;
        bondedWood -= bond;

        // A tie leaves the bond whole, the same fail-safe direction every other
        // verdict in this contract takes: an electorate split down the middle
        // has not established that the ruling was corrupt.
        bool slash = turnout != 0 && turnout >= floor && badFaithVotes > goodFaithVotes;
        if (slash) {
            bf.slashed = true;
            uint256 slashed = panelBondOf[panelist];
            if (slashed != 0) {
                panelBondOf[panelist] = 0;
                bondedWood -= slashed;
                forfeitedWood += slashed;
            }
            emit PanelBondSlashed(caseId, panelist, slashed);
        }

        address opener = bf.opener;
        emit BadFaithFinalized(caseId, panelist, slash, badFaithVotes, goodFaithVotes, floor);
        wood.safeTransfer(opener, bond);
        emit BadFaithBondReturned(caseId, panelist, opener, bond);
    }

    /// @dev THE ONE PLACE EITHER FLOOR IS COMPUTED, shared by `finalizeAppeal`
    ///      and `finalizeBadFaith` so the two votes a case runs cannot end up
    ///      measured against different denominators.
    /// @dev THE BASE IS THE ELECTORATE THAT MAY ACTUALLY VOTE. `voteAppeal` and
    ///      `voteBadFaith` bar the accused, so `accusedWeight` is stake that
    ///      CANNOT appear in the turnout no matter how the vote goes. Leaving it
    ///      in the denominator would price honest turnout against votes the
    ///      contract itself refuses to accept: the same honest participation
    ///      that cleared the floor before the exclusion would now miss it, and
    ///      missing it means THE PANEL'S RULING STANDS. That is not a neutral
    ///      failure — it converts the exclusion from "the accused cannot
    ///      self-acquit" into "a bribed panel is harder to overturn", which is
    ///      the very outcome layer 2 exists to prevent. Subtracting leaves the
    ///      remaining electorate facing the same PROPORTIONAL bar it faced
    ///      before, which is the whole intent of D6's parameter.
    /// @dev THE UNDERFLOW GUARD FALLS BACK TO THE UNREDUCED TOTAL, and that
    ///      choice is deliberate — it is NOT a clamp to zero. The two numbers
    ///      come from different scales: `getPastTotalVotes` is the RAW own-stake
    ///      total (sWOOD keeps totals raw as a conservative denominator), while
    ///      `getPastVotes` adds k-capped DELEGATED inbound on top of aged own
    ///      stake. Per-account weights can therefore sum past the total, so an
    ///      accused guardian carrying enough delegation can genuinely push
    ///      `accusedWeight` above it while a large honest electorate still
    ///      exists. Clamping the base to zero there would set the floor to zero
    ///      and let ONE non-accused voter holding dust overturn any panel
    ///      ruling — deleting D6 exactly when an accused party has the means to
    ///      arrange it, which makes it an attack rather than an edge case.
    ///      Reverting is worse still: `refer` would fail, no case could open,
    ///      and `ChallengeGame`'s `disputeTimeout` would acquit the accused by
    ///      default — the hole Plan E exists to close. So when the subtraction
    ///      is incoherent the court keeps the denominator it always had: a
    ///      floor that is conservative, reachable by the honest electorate that
    ///      demonstrably still exists, and answerable to no party's arithmetic.
    function _participationFloor(uint256 snapshotTs, uint256 accusedWeight) internal view returns (uint256) {
        uint256 total = IStakedWood(stakedWood).getPastTotalVotes(snapshotTs);
        uint256 base = total >= accusedWeight ? total - accusedWeight : total;
        return participationFloorBps * base / BPS_DENOMINATOR;
    }

    /// @inheritdoc ICourt
    function accusedOf(uint256 caseId) external view returns (address[] memory) {
        return _accused[caseId];
    }

    /// @inheritdoc ICourt
    function badFaithOf(uint256 caseId, address panelist) external view returns (BadFaithVote memory) {
        return _badFaith[caseId][panelist];
    }

    /// @inheritdoc ICourt
    /// @dev PAID OUT OF THE RESERVE `_resolve` SET ASIDE, so the money is
    ///      provably still here: `reservedRewards` is the sum of every
    ///      outstanding `panelRewardOf`, and `burnForfeited` cannot reach it. The
    ///      claim draws both numbers down by the same amount in the same
    ///      statement, so `forfeitedWood >= reservedRewards` and the §4 equality
    ///      both hold across it.
    function claimPanelReward() external returns (uint256 amount) {
        amount = panelRewardOf[msg.sender];
        if (amount == 0) revert NothingToClaim();

        panelRewardOf[msg.sender] = 0;
        reservedRewards -= amount;
        forfeitedWood -= amount;
        wood.safeTransfer(msg.sender, amount);
        emit PanelRewardClaimed(msg.sender, amount);
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
        _accruePanelRewards(caseId, voters, n);

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

    /// @dev THE REWARD IS FLAT (D5): every member that ruled is credited the
    ///      SAME `panelRewardWood`, whichever way it voted and whichever way the
    ///      case came out. §3.5 asks for this explicitly, and the reason is
    ///      narrow — a reward that paid more for agreeing with the eventual
    ///      verdict would pay panelists to predict the token vote instead of
    ///      reading the evidence, which is the same beauty-contest failure D4
    ///      removes from the slashing side. There is deliberately no argument
    ///      here that could make it depend on `ruling`.
    /// @dev PAID FROM `forfeitedWood` — the protocol-owned pot fed by below-floor
    ///      appeal bonds and by bad-faith slashes. Bad conduct funds the honest
    ///      panel's sitting fee, and no new WOOD sink is invented for it.
    /// @dev THE LIABILITY IS RESERVED AT THE INSTANT IT ACCRUES, not looked for
    ///      at claim time. `required` moves into `reservedRewards`, which
    ///      `burnForfeited` subtracts before it takes anything, so no burn — and
    ///      there is no longer any owner sweep either — can leave these credits
    ///      unbacked. The WOOD does not leave `forfeitedWood`; it is only marked
    ///      as spoken for, which is why this is a subset and not a third bucket.
    /// @dev FUNDING IS MEASURED AGAINST THE UNRESERVED SURPLUS. `available` is
    ///      `forfeitedWood - reservedRewards`, never the raw pot: the reserved
    ///      part belongs to earlier cases' panelists, and counting it here would
    ///      let case N+1 credit rewards backed by case N's money and leave
    ///      whichever panel claimed second unable to withdraw.
    /// @dev ALL OR NOTHING. If the surplus cannot cover every ruling member, none
    ///      is paid and `PanelRewardUnfunded` says so. Paying down the pot in
    ///      vote order would make the reward depend on WHEN a member ruled — a
    ///      race to vote first, which is a bias on panel behaviour of exactly the
    ///      kind D5 exists to remove — and it would put the court's accounting in
    ///      the position of underpaying a member it had already credited.
    function _accruePanelRewards(uint256 caseId, address[] storage voters, uint256 n) internal {
        uint256 reward = panelRewardWood;
        if (reward == 0 || n == 0) return;

        uint256 required = reward * n;
        uint256 available = forfeitedWood - reservedRewards;
        if (available < required) {
            emit PanelRewardUnfunded(caseId, required, available);
            return;
        }

        // The pot itself does not move — `required` is merely fenced off inside
        // it — so the §4 equality is untouched and `forfeitedWood` still bounds
        // `reservedRewards` (the check above is exactly that bound).
        reservedRewards += required;
        for (uint256 i; i < n; ++i) {
            address member = voters[i];
            panelRewardOf[member] += reward;
            emit PanelRewardAccrued(caseId, member, reward);
        }
    }

    /// @dev Whether `member`'s bond is still needed by the bad-faith track.
    ///      `panelRule` is what makes this live: a member that records a ruling
    ///      is locked to `referredAt + panelWindow + badFaithWindow`, so the
    ///      roster and withdraw guards above genuinely bite from the moment it
    ///      votes. `_resolve` extends the lock to the case's actual finalization
    ///      plus `badFaithWindow`, and an OPEN BAD-FAITH VOTE holds it open for
    ///      as long as that vote runs, however far past the deadline that is.
    /// @dev THE SECOND CLAUSE IS NOT REDUNDANT WITH THE FIRST. A proceeding
    ///      opened in the last moments of `badFaithWindow` runs a further
    ///      `appealVoteWindow` past the deadline lock, and governance can
    ///      lengthen `badFaithWindow` after a case resolved without moving the
    ///      already-stored lock. Either way the deadline can expire with a live
    ///      vote still running, and without this clause the panelist could
    ///      withdraw the bond that vote is about.
    function _hasOpenRuling(address member) internal view returns (bool) {
        return block.timestamp < panelBondLockedUntil[member] || openBadFaithVotes[member] != 0;
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
    /// @dev Zero refused, like the appeal bond: opening a bad-faith proceeding
    ///      escrows a panelist's bond for a full vote window, and a free way to
    ///      do that is a free way to grief an honest panel. Governs FUTURE
    ///      proceedings only — an open one is owed the bond it actually posted.
    function setBadFaithBondWood(uint256 newBond) external onlyOwner {
        if (newBond == 0) revert InvalidParameter();
        emit BadFaithBondWoodSet(badFaithBondWood, newBond);
        badFaithBondWood = newBond;
    }

    /// @inheritdoc ICourt
    /// @dev ZERO IS LEGAL HERE, unlike every other amount on this contract: it
    ///      turns rewards off, which is the state the court is deployed in. The
    ///      thing this setter cannot express is a reward that varies with the
    ///      verdict (D5) — there is no argument for one.
    /// @dev Governs FUTURE resolutions only. A member is credited at the instant
    ///      its case resolves, and what it was credited is already claimable.
    function setPanelRewardWood(uint256 newReward) external onlyOwner {
        emit PanelRewardWoodSet(panelRewardWood, newReward);
        panelRewardWood = newReward;
    }

    /// @inheritdoc ICourt
    /// @dev NO OWNER, NO DESTINATION, ON PURPOSE — this REPLACED an
    ///      `onlyOwner sweepForfeited(address to)` with an arbitrary recipient.
    ///      `forfeitedWood` is fed by failed appeals and by slashed panel bonds,
    ///      so an owner able to direct it was an owner who PROFITED FROM THE
    ///      COURT'S FAILURES: a standing incentive to see appeals miss the floor
    ///      and panelists slashed. Not an exploit, just an incentive pointing the
    ///      wrong way, and the cheapest fix is to leave nobody to point it at.
    /// @dev WHY BURN RATHER THAN ANYWHERE ELSE. Every other destination — a
    ///      treasury, the protocol backstop, the owner — needs a party trusted to
    ///      hold the pot, and that party then benefits when the court fails.
    ///      Burning is the only destination with NO BENEFICIARY, which is what
    ///      makes the panel's and the appellant's incentives clean: nobody
    ///      anywhere is made better off by a forfeit. The value is not lost to
    ///      WOOD holders either — removing it from circulation accrues pro rata
    ///      to everyone who still holds, which is as close to "returned to the
    ///      protocol" as a destination with no custodian can get.
    /// @dev PERMISSIONLESS IS LOAD-BEARING, NOT CONVENIENCE. Gating the burn on
    ///      the owner would let it sit on the pot indefinitely, which is the same
    ///      discretion this function exists to delete, only exercised by
    ///      inaction. Anyone may call it, so the surplus is always one
    ///      transaction from gone and nobody's forbearance is worth anything.
    ///      There is nothing to grief with: the caller chooses no amount and no
    ///      destination, and burning early only burns money the protocol already
    ///      owned outright.
    /// @dev TAKES THE UNRESERVED SURPLUS ONLY. `reservedRewards` is subtracted
    ///      first, so rewards a resolved case already accrued survive any number
    ///      of burns; and it reads `forfeitedWood` alone, never `bondedWood`, so
    ///      NO LIVE BOND IS EVER BURNABLE — not a posted panel bond, not an open
    ///      appeal's, not an open bad-faith proceeding's. The §4 equality is what
    ///      makes that guarantee checkable rather than merely asserted.
    /// @dev Reverts on an empty surplus rather than no-opping, matching how this
    ///      contract treats every other empty operation (`claimPanelReward`
    ///      reverts `NothingToClaim`). A no-op burn would emit a
    ///      `ForfeitedWoodBurned(caller, 0)` that indexers would have to filter.
    function burnForfeited() external returns (uint256 amount) {
        amount = forfeitedWood - reservedRewards;
        if (amount == 0) revert NothingToBurn();

        forfeitedWood -= amount;
        wood.safeTransfer(BURN_ADDRESS, amount);
        emit ForfeitedWoodBurned(msg.sender, amount);
    }

    // ─────────────────────────── Internals ───────────────────────────

    function _contains(address[] calldata list, address member) private pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == member) return true;
        }
        return false;
    }
}
