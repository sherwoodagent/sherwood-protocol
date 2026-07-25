// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICourt
/// @notice The two-layer adjudicator for disputed challenges (spec 2026-07-22
///         §3.5, Plan E). Layer 1 is a governance-elected panel, each member
///         holding a slashable bond; layer 2 is a full WOOD vote weighted by
///         `StakedWood.getPastVotes` at the block before the challenged
///         proposal executed. A SEPARATE vote — never the merits appeal —
///         decides whether a ruling was made in bad faith and slashes the
///         panelist's bond (decision D4).
///
/// @dev    PANEL SELECTION IS TRUSTED; PANEL BEHAVIOUR IS BONDED (decision D1).
///         §3.5 says panel members are "elected by WOOD governance", but
///         on-chain elections are a governance subsystem in their own right and
///         are out of scope. The roster is owner-set, where the owner is the
///         governance multisig executing the off-chain election result. The
///         check on a captured roster is the bad-faith track plus the sovereign
///         appeal — not the seating call.
///
/// @dev    SURFACE STAGING. This interface is built across Plan E's tasks:
///         Task 2 (this file's first revision) declares the whole error and
///         enum surface plus the roster/bond functions; Tasks 3-5 add `refer` /
///         `panelRule` / `finalizePanel`, `appeal` / `voteAppeal` /
///         `finalizeAppeal` / `finalizeUnappealed`, and `openBadFaith` /
///         `voteBadFaith` / `finalizeBadFaith`. Errors declared here that no
///         function reverts with yet belong to those later tasks — they are
///         pinned now so the ABI does not churn under consumers.
interface ICourt {
    /// @notice A verdict on a case. `None` MUST be the zero value so an unset
    ///         ruling is never read as `Guilty` — a default-Guilty enum would
    ///         make an untouched storage slot a conviction.
    /// @dev    Tasks 3-6 branch on this; the member names and ordering are
    ///         fixed here and must not be reordered.
    enum Ruling {
        None,
        Guilty,
        NotGuilty
    }

    /// @notice Where a case sits in the two-layer process. `None` MUST be the
    ///         zero value so an unreferred case is never mistaken for a live
    ///         one — every phase-gated entrypoint compares against a specific
    ///         member, so an untouched slot matches nothing.
    /// @dev    `Panel` → layer 1 is taking votes. `AppealWindow` → the panel has
    ///         ruled and Task 4's `appeal` may still be filed. `Appeal` → the
    ///         token vote of layer 2 is open. `Resolved` → the verdict has been
    ///         handed to `ChallengeGame.rule`. Task 3 implements
    ///         `None → Panel → AppealWindow`; Tasks 4-5 own the rest, and the
    ///         ordering is pinned here so neither can silently reinterpret it.
    enum Phase {
        None,
        Panel,
        AppealWindow,
        Appeal,
        Resolved
    }

    /// @notice One adjudication, opened by `refer` against one disputed
    ///         challenge.
    /// @param challengeId       The `ChallengeGame` challenge under adjudication.
    /// @param snapshotTs        THE ELECTORATE, FIXED ONCE (decision D2):
    ///        `executedAt - 1` of the challenged proposal, computed in `refer`
    ///        and never re-derived. Both later votes — the merits appeal and the
    ///        bad-faith vote — read this one value, so they cannot disagree
    ///        about who votes; and it is the same instant Plan C's
    ///        `slashToEscrow` uses for compensation claims, which makes the
    ///        electorate that judges guilt identical to the set compensated out
    ///        of the resulting slash.
    /// @param referredAt        When the panel window started.
    /// @param panelFinalizedAt  When `finalizePanel` wrote `panelRuling`; zero
    ///        while layer 1 is still open. Task 4 measures `appealWindow` from it.
    /// @param panelGuiltyVotes  Seats that voted guilty — a HEAD COUNT, not
    ///        stake: layer 1 is a panel of people, layer 2 is the token vote.
    /// @param appellant         Who filed the appeal, or the zero address if
    ///        the ruling was never appealed. The bond returns here when the
    ///        appeal clears the participation floor, and NOT when it misses it.
    /// @param appealedAt        When layer 2's vote opened; `appealVoteWindow`
    ///        is measured from it.
    /// @param appealBond        The WOOD posted with the appeal, captured at
    ///        filing time so a later `setAppealBondWood` cannot change what an
    ///        open appeal is owed. Zeroed once returned or forfeited.
    /// @param appealGuiltyVotes STAKE, not a head count — the sum of
    ///        `getPastVotes(voter, snapshotTs)` over guilty voters. Layer 2 is
    ///        the token vote, so it weighs WOOD where layer 1 counted seats.
    /// @param finalRuling       What the court actually handed
    ///        `ChallengeGame.rule`. Equal to `panelRuling` when the ruling went
    ///        unappealed OR when an appeal missed the floor (D6); the majority
    ///        of cast votes otherwise.
    /// @param finalizedAt       When the CASE resolved. Task 5's bad-faith
    ///        window opens here — later than the panel phase whenever an appeal
    ///        ran, which is why the panel bond lock is extended from this
    ///        instant and not from `referredAt`.
    struct Case {
        uint256 challengeId;
        uint256 snapshotTs;
        uint256 referredAt;
        uint256 panelFinalizedAt;
        uint256 panelGuiltyVotes;
        uint256 panelNotGuiltyVotes;
        Phase phase;
        Ruling panelRuling;
        address appellant;
        uint256 appealedAt;
        uint256 appealBond;
        uint256 appealGuiltyVotes;
        uint256 appealNotGuiltyVotes;
        Ruling finalRuling;
        uint256 finalizedAt;
    }

    /// @notice One bad-faith proceeding: a vote about ONE panelist's ruling on
    ///         ONE case, and never about the merits (decision D4).
    /// @param opener        Who opened it and posted `bond`. The bond returns to
    ///        this address on EVERY branch — see `openBadFaith` for why the
    ///        bad-faith track prices escalation differently from the appeal.
    /// @param bond          The WOOD posted, captured at open time so a later
    ///        `setBadFaithBondWood` cannot change what an open vote is owed.
    /// @param openedAt      When the vote opened; `appealVoteWindow` runs from it.
    /// @param badFaithVotes STAKE that says the ruling was made in bad faith,
    ///        weighted by `getPastVotes` at the CASE's stored `snapshotTs` — the
    ///        same electorate the merits appeal used, so neither vote can be run
    ///        against a different set of holders.
    /// @param resolved      Set by `finalizeBadFaith`. One proceeding per
    ///        (case, panelist) pair, ever, so this is also the terminal flag.
    /// @param slashed       Whether that finalization slashed the panel bond.
    struct BadFaithVote {
        address opener;
        uint256 bond;
        uint256 openedAt;
        uint256 badFaithVotes;
        uint256 goodFaithVotes;
        bool resolved;
        bool slashed;
    }

    // ── Errors ──
    // Roster and bonds (Task 2).
    error NotPanelist();
    error PanelBondNotPosted();
    error PanelBondAlreadyPosted();
    /// @notice The member still has a ruling whose bad-faith window can open or
    ///         is open. Blocks BOTH unseating it and returning its bond — if
    ///         either were allowed the bond would escape the bad-faith track
    ///         and the only binding incentive on panel behaviour with it.
    error PanelistHasOpenRuling();
    /// @notice A seated panelist tried to withdraw its bond. A sitting member
    ///         with nothing at stake is not a bonded panel.
    error StillSeated();

    // Adjudication (Tasks 3-5).
    error AlreadyRuled();
    error WrongPhase();
    /// @notice `refer` on a challenge that is not `Disputed`. A `Filed` one is
    ///         still inside its own auto-slash clock and nobody has contested
    ///         it; a terminal one has nothing left to decide.
    /// @dev    Distinct from `WrongPhase`, which is about THIS contract's case
    ///         phases: this one reports the challenge game's status.
    error ChallengeNotDisputed();
    /// @notice A second `refer` against a challenge that already has a case.
    ///         Two cases over one accusation would run two panels at two
    ///         snapshots toward two verdicts, and only one of them could reach
    ///         `ChallengeGame.rule`.
    error AlreadyReferred();
    error WindowClosed();
    error WindowOpen();
    error ParticipationFloorNotMet();
    error AlreadyVoted();
    error NoVotingPower();

    // The bad-faith track (Task 5, F6).
    /// @notice A bad-faith vote was opened against a member that did not rule on
    ///         that case. The track answers for RULINGS, so the target set is
    ///         `panelVoters(caseId)` and nothing else — not the live roster, and
    ///         not a member that abstained.
    error PanelistDidNotRule();
    /// @notice One bad-faith proceeding per (case, panelist) pair, ever. Without
    ///         this an attacker could re-open a vote it lost, and — because an
    ///         open vote escrows the bond — could pin an honest panelist's bond
    ///         indefinitely by opening a fresh one each time the last resolved.
    error BadFaithAlreadyOpened();
    /// @notice No bad-faith vote is open for that (case, panelist) pair, either
    ///         because none was opened or because it already resolved.
    error BadFaithNotOpen();
    error NothingToClaim();
    /// @notice `burnForfeited` found no unreserved surplus — either the pot is
    ///         empty or every last unit of it is reserved for accrued panel
    ///         rewards. Reverting rather than no-opping matches
    ///         `NothingToClaim`'s treatment of the same situation.
    error NothingToBurn();

    // Shared.
    error ZeroAddress();
    error InvalidParameter();

    // ── Events ──
    /// @param oldSize Seats before the call.
    /// @param newSize Seats after it. Task 3's majority arithmetic reads this
    ///        count, which is why `setPanel` rejects duplicate members.
    event PanelSet(uint256 oldSize, uint256 newSize);
    event PanelistSeated(address indexed member);
    event PanelistUnseated(address indexed member);
    event PanelBondWoodSet(uint256 oldAmount, uint256 newAmount);
    event PanelBondPosted(address indexed member, uint256 amount);
    event PanelBondWithdrawn(address indexed member, uint256 amount);
    /// @notice The member's bond is escrowed at least until `lockedUntil`.
    /// @dev    Emitted by Tasks 3-5 whenever a ruling is recorded or a
    ///         bad-faith vote is opened against one.
    event PanelBondLocked(address indexed member, uint256 lockedUntil);

    // Adjudication, layer 1 (Task 3).
    /// @param snapshotTs The voting-power instant this case is fixed to for
    ///        every later vote (D2) — `executedAt - 1` of the challenged
    ///        proposal. Emitted so an indexer can reconstruct the electorate
    ///        from the log alone.
    event CaseReferred(
        uint256 indexed caseId,
        uint256 indexed challengeId,
        address indexed governor,
        uint256 proposalId,
        uint256 snapshotTs
    );
    event PanelVoteCast(uint256 indexed caseId, address indexed member, bool guilty);
    /// @dev Carries the tally as well as the verdict, because a `NotGuilty` at
    ///      `0-0` (nobody ruled) and one at `2-2` (a tie) are different facts
    ///      about the panel even though they are the same outcome.
    event PanelFinalized(uint256 indexed caseId, Ruling ruling, uint256 guiltyVotes, uint256 notGuiltyVotes);
    event ChallengeGameSet(address indexed oldGame, address indexed newGame);
    event PanelWindowSet(uint256 oldWindow, uint256 newWindow);
    event BadFaithWindowSet(uint256 oldWindow, uint256 newWindow);

    // Adjudication, layer 2 (Task 4).
    /// @param voteDeadline When `voteAppeal` closes and `finalizeAppeal` opens.
    event AppealFiled(uint256 indexed caseId, address indexed appellant, uint256 bond, uint256 voteDeadline);
    /// @param weight `getPastVotes(voter, snapshotTs)` — ALREADY age-weighted by
    ///        sWOOD (D3). The court does not re-weight it.
    event AppealVoteCast(uint256 indexed caseId, address indexed voter, bool guilty, uint256 weight);
    /// @notice THE ANTI-CAPTURE EVENT (D6). Turnout missed the participation
    ///         floor, so the appeal was a NON-EVENT: the panel's ruling stands
    ///         untouched and the appellant's bond forfeits for failing to raise
    ///         a quorum. Deliberately NOT `AppealFinalized` with a ruling that
    ///         happens to match — an indexer must be able to tell "the vote
    ///         decided nothing" from "the vote upheld the panel".
    event AppealBelowFloor(
        uint256 indexed caseId, uint256 turnout, uint256 floor, Ruling standingRuling, uint256 bondForfeited
    );
    /// @notice Turnout cleared the floor and the majority of cast votes decided
    ///         the case, overriding the panel where they disagree.
    event AppealFinalized(
        uint256 indexed caseId, Ruling ruling, uint256 guiltyVotes, uint256 notGuiltyVotes, uint256 floor
    );
    /// @notice The case is terminal and the verdict has been handed to
    ///         `ChallengeGame.rule`. Emitted on every path out of the court —
    ///         unappealed, below-floor and decided-on-appeal alike.
    event CaseResolved(uint256 indexed caseId, uint256 indexed challengeId, Ruling ruling);
    event AppealBondReturned(uint256 indexed caseId, address indexed appellant, uint256 amount);
    event StakedWoodSet(address indexed oldStakedWood, address indexed newStakedWood);
    event AppealWindowSet(uint256 oldWindow, uint256 newWindow);
    event AppealVoteWindowSet(uint256 oldWindow, uint256 newWindow);
    event AppealBondWoodSet(uint256 oldAmount, uint256 newAmount);
    event ParticipationFloorBpsSet(uint256 oldBps, uint256 newBps);
    /// @notice The unreserved forfeited surplus was sent to a dead address.
    /// @dev    `caller` is indexed for completeness only — it earns nothing and
    ///         chooses nothing. The burn is permissionless precisely so that no
    ///         address in this log line has any discretion over the amount or the
    ///         destination.
    event ForfeitedWoodBurned(address indexed caller, uint256 amount);

    // The bad-faith track (Task 5, F6).
    /// @param voteDeadline When `voteBadFaith` closes and `finalizeBadFaith`
    ///        opens. The proceeding is separate from the merits appeal (D4) but
    ///        reuses `appealVoteWindow` for its length — one knob, and the two
    ///        votes are the same kind of thing: a stake-weighted vote of the
    ///        case's stored electorate.
    event BadFaithOpened(
        uint256 indexed caseId, address indexed panelist, address indexed opener, uint256 bond, uint256 voteDeadline
    );
    /// @param badFaith True = "this ruling was made in bad faith". NOT a vote on
    ///        the merits: the electorate may believe the ruling was wrong and
    ///        still vote false here, and that distinction is the whole of D4.
    event BadFaithVoteCast(
        uint256 indexed caseId, address indexed panelist, address indexed voter, bool badFaith, uint256 weight
    );
    /// @notice THE F6 EVENT. Carries the tally and the floor as well as the
    ///         outcome, because "the electorate cleared the floor and said good
    ///         faith" and "not enough of it turned out to decide" are different
    ///         facts about a panelist that both leave its bond whole.
    event BadFaithFinalized(
        uint256 indexed caseId,
        address indexed panelist,
        bool slashed,
        uint256 badFaithVotes,
        uint256 goodFaithVotes,
        uint256 floor
    );
    /// @notice The panelist's bond moved from `bondedWood` to `forfeitedWood`.
    ///         Emitted separately from `BadFaithFinalized` so the slash is a
    ///         first-class log line and not a boolean inside a tally.
    event PanelBondSlashed(uint256 indexed caseId, address indexed panelist, uint256 amount);
    event BadFaithBondReturned(
        uint256 indexed caseId, address indexed panelist, address indexed opener, uint256 amount
    );
    event BadFaithBondWoodSet(uint256 oldAmount, uint256 newAmount);
    event PanelRewardWoodSet(uint256 oldAmount, uint256 newAmount);
    /// @notice A FLAT reward, credited to every member that ruled on the case
    ///         (D5). The amount does not depend on how the member voted, nor on
    ///         which way the case came out.
    event PanelRewardAccrued(uint256 indexed caseId, address indexed member, uint256 amount);
    event PanelRewardClaimed(address indexed member, uint256 amount);
    /// @notice The case resolved with rewards configured but the protocol-owned
    ///         pot too thin to pay EVERY ruling member, so it paid NONE of them.
    ///         All-or-nothing is deliberate: paying the pot down in vote order
    ///         would make the reward depend on when a member ruled, which is a
    ///         bias on panel behaviour of exactly the kind D5 exists to remove.
    /// @param available The UNRESERVED surplus, `forfeitedWood -
    ///        reservedRewards`, not the raw pot. WOOD already reserved for an
    ///        earlier case's panelists is not available to this one.
    event PanelRewardUnfunded(uint256 indexed caseId, uint256 required, uint256 available);

    // ── Roster (D1) ──
    /// @notice Replace the seated panel with `members`.
    /// @dev    Owner-only: the owner is the governance multisig executing the
    ///         off-chain election (D1). Members present in both the old and new
    ///         lists keep their seat, bond and lock untouched. Reverts
    ///         `PanelistHasOpenRuling` rather than unseating a member whose
    ///         bond the bad-faith track may still need.
    /// @dev    An EMPTY list is legal and decommissions the court. Refusing to
    ///         wire a court with no seated, bonded panel into `ChallengeGame`
    ///         is a deploy-time pre-flight, not a setter invariant.
    function setPanel(address[] calldata members) external;

    /// @notice The seated roster, in the order it was set.
    function panel() external view returns (address[] memory);
    function panelSize() external view returns (uint256);
    function isPanelist(address member) external view returns (bool);

    // ── Member bonds ──
    /// @notice Post (or top up to) the current `panelBondWood`. Pulls only the
    ///         shortfall, so a member is never charged twice for the same seat.
    function postPanelBond() external;

    /// @notice Return a member's posted bond. Only once it has been unseated
    ///         AND no bad-faith window is open against any of its rulings.
    /// @return amount The WOOD returned — what was POSTED, which after a
    ///         lowered requirement can exceed the current `panelBondWood`.
    function withdrawPanelBond() external returns (uint256 amount);

    /// @notice The bond each seated member must post before it can rule.
    function panelBondWood() external view returns (uint256);
    /// @notice WOOD `member` currently has posted, seated or not.
    function panelBondOf(address member) external view returns (uint256);
    /// @notice Timestamp until which `member`'s bond is escrowed against the
    ///         bad-faith track. Zero means free.
    function panelBondLockedUntil(address member) external view returns (uint256);

    /// @notice Whether `member` is seated AND fully bonded — the precondition
    ///         Task 3's `panelRule` enforces. An unbonded panelist is never
    ///         ready to rule.
    function isReadyToRule(address member) external view returns (bool);

    // ── Layer 1: the panel rules (Task 3) ──
    /// @notice Escalate a `Disputed` challenge to the court, opening a case.
    /// @dev    PERMISSIONLESS. The caller chooses nothing: the challenge it
    ///         names must already be `Disputed`, and everything the case is
    ///         fixed to — the electorate snapshot, the panel deadline — is
    ///         derived from state the caller does not control. Leaving it open
    ///         removes the last place a privileged party could sit on an
    ///         escalation, which matters because the challenge's own
    ///         `disputeTimeout` acquits by default while nobody refers it.
    /// @return caseId The new case. Case ids are the court's own; they are NOT
    ///         challenge ids, and not the `caseId` sWOOD mints for a
    ///         compensation case either.
    function refer(uint256 challengeId) external returns (uint256 caseId);

    /// @notice Record a seated, fully bonded panelist's verdict on a case.
    /// @dev    Locks the caller's panel bond (see `panelBondLockedUntil`) — a
    ///         panelist that has ruled cannot take its stake out of the
    ///         bad-faith track's reach.
    function panelRule(uint256 caseId, bool guilty) external;

    /// @notice Close layer 1 and write `panelRuling`, once the panel window has
    ///         elapsed or every seated member has voted.
    /// @dev    A MAJORITY OF CAST VOTES CONVICTS; ANYTHING ELSE ACQUITS. A tie
    ///         and a silent panel both yield `NotGuilty` — see `Court` for why
    ///         that is a property and not an accident.
    function finalizePanel(uint256 caseId) external;

    // ── Layer 2: the token-vote appeal (Task 4) ──
    /// @notice Appeal a panel ruling to the full WOOD electorate, posting
    ///         `appealBondWood`. Permissionless and open for `appealWindow`
    ///         after `finalizePanel`.
    /// @dev    THE BOND IS NOT A FEE ON BEING WRONG. It forfeits on exactly one
    ///         condition — turnout below the participation floor — and returns
    ///         whichever way a quorate vote goes, including one that upholds the
    ///         panel. Appealing a ruling you lose costs nothing; failing to
    ///         raise an electorate costs the bond.
    function appeal(uint256 caseId) external;

    /// @notice Cast a stake-weighted vote on the merits.
    /// @dev    Weight is `stakedWood.getPastVotes(msg.sender, case.snapshotTs)`,
    ///         which is ALREADY age-weighted (D3) — the court does not re-weight
    ///         it, because a second age curve would diverge from sWOOD's. Zero
    ///         weight reverts `NoVotingPower`, which is what excludes anyone who
    ///         accumulated WOOD after the exploit: the flash-loan and
    ///         post-drain-buyer defence is the snapshot, not a separate check.
    function voteAppeal(uint256 caseId, bool guilty) external;

    /// @notice Close layer 2 and hand the verdict to `ChallengeGame.rule`.
    /// @dev    TWO BRANCHES, AND THEY ARE NOT THE SAME OUTCOME REACHED TWO WAYS.
    ///         Below the participation floor the PANEL RULING STANDS (D6) — the
    ///         appeal decided nothing, so the cast votes are discarded even when
    ///         they went the other way, and the bond forfeits. At or above it,
    ///         the majority of cast votes decides and overrides the panel.
    function finalizeAppeal(uint256 caseId) external;

    /// @notice Make an unappealed panel ruling final once `appealWindow` has
    ///         elapsed with no appeal, handing it to `ChallengeGame.rule`.
    function finalizeUnappealed(uint256 caseId) external;

    /// @notice How `voter` voted on `caseId`'s appeal; `Ruling.None` means it
    ///         has not.
    function appealVoteOf(uint256 caseId, address voter) external view returns (Ruling);

    // ── The bad-faith track (Task 5, F6) ──
    /// @notice Open a vote on whether `panelist` ruled on `caseId` in BAD FAITH,
    ///         posting `badFaithBondWood`. Permissionless, and open for
    ///         `badFaithWindow` after the case resolved.
    /// @dev    THIS IS THE ONLY THING THAT CAN SLASH A PANEL BOND, AND IT IS NOT
    ///         THE MERITS APPEAL (decision D4, finding F6). The first draft of
    ///         §3.5 slashed the panel bond on a merits overturn, which hands an
    ///         attacker who controls the cheap appeal layer BOTH halves of the
    ///         prize: a corrupt ruling made safe AND the honest panelists who
    ///         voted against it punished. It also gives every panelist a
    ///         beauty-contest incentive to predict the token vote rather than
    ///         read the evidence. So the two tracks are independent in BOTH
    ///         directions — being overturned on the merits never slashes, and
    ///         winning the merits appeal never immunizes.
    /// @dev    THE BOND RETURNS ON EVERY BRANCH, unlike the appeal's, which
    ///         forfeits below the floor. The asymmetry is deliberate: a
    ///         below-floor APPEAL asked the electorate to override the panel and
    ///         failed to raise one, whereas the bad-faith track is the only
    ///         check that exists on a bribable panel, and pricing a failed
    ///         accusation would deter exactly the check F6 asks for. Spam is
    ///         bounded instead by `BadFaithAlreadyOpened` plus the finite
    ///         `badFaithWindow`.
    function openBadFaith(uint256 caseId, address panelist) external;

    /// @notice Vote on whether the ruling was made in bad faith.
    /// @dev    SAME ELECTORATE, SAME STORED SNAPSHOT, SAME PARTICIPATION FLOOR as
    ///         the merits appeal — read from `case.snapshotTs`, never recomputed,
    ///         so the two votes cannot be run against different holders.
    function voteBadFaith(uint256 caseId, address panelist, bool badFaith) external;

    /// @notice Close the proceeding: slash `panelist`'s bond if the floor was
    ///         cleared and the majority said bad faith, and return the opener's
    ///         bond either way.
    /// @dev    SLASHED BONDS GO TO `forfeitedWood`, NOT TO THE COMPENSATION
    ///         ESCROW'S PER-CASE CLAIMS. A corrupt panelist's bond is not the
    ///         drained value: `CompensationEscrow.openCase` fixes a case's
    ///         `proceeds` at open time precisely so per-case funds stay isolated
    ///         (a critical Plan C fix), and crediting an unrelated slash into a
    ///         victim case would inflate its proceeds and pay claimants out of
    ///         money that was never theirs. One sink, and one with no custodian:
    ///         its only exits are the flat panel reward and the permissionless
    ///         `burnForfeited`.
    function finalizeBadFaith(uint256 caseId, address panelist) external;

    /// @notice The bad-faith proceeding against `panelist`'s ruling on `caseId`.
    ///         `openedAt == 0` means none was ever opened.
    function badFaithOf(uint256 caseId, address panelist) external view returns (BadFaithVote memory);

    /// @notice How `voter` voted in that proceeding; `Ruling.Guilty` means "bad
    ///         faith", `Ruling.NotGuilty` "good faith", `None` "has not voted".
    function badFaithVoteOf(uint256 caseId, address panelist, address voter) external view returns (Ruling);

    /// @notice How many bad-faith proceedings against `member` are still open.
    /// @dev    A COUNTER HERE, where `panelBondLockedUntil` is a deadline, and
    ///         the difference is load-bearing. A ruling's bad-faith window may
    ///         simply never be used, so a counter incremented at ruling time
    ///         would strand the bond forever — hence the deadline there. An
    ///         OPENED proceeding, by contrast, can always be closed by anyone
    ///         once its vote window elapses, including by the panelist itself,
    ///         so a counter cannot strand anything and it removes the race a
    ///         pure deadline would leave: a panelist front-running
    ///         `finalizeBadFaith` to withdraw the instant its lock expired.
    function openBadFaithVotes(address member) external view returns (uint256);

    /// @notice The WOOD an opener posts. Returned on every branch.
    function badFaithBondWood() external view returns (uint256);

    /// @notice The FLAT per-ruling reward (D5). Zero disables rewards.
    /// @dev    Flat is the point: §3.5 requires the panelist's pay to be
    ///         independent of which way it rules, or the reward itself becomes
    ///         an incentive to track the expected verdict rather than the
    ///         evidence.
    function panelRewardWood() external view returns (uint256);

    /// @notice Reward credited to `member` and not yet claimed. Counted inside
    ///         `forfeitedWood` and reserved by `reservedRewards`, because it is
    ///         protocol-owned WOOD promised to a payee rather than a bond
    ///         anybody posted.
    function panelRewardOf(address member) external view returns (uint256);

    /// @notice Withdraw accrued panel rewards.
    function claimPanelReward() external returns (uint256 amount);

    /// @notice The members that recorded a ruling on `caseId`, in vote order.
    ///         The set whose bonds the case's resolution locks, and the set
    ///         Task 5's bad-faith track can be opened against.
    /// @dev    Stored per case rather than derived from the live roster: a
    ///         member can be rotated off the panel once its lock expires, and a
    ///         roster scan would then lose the fact that it ruled.
    function panelVoters(uint256 caseId) external view returns (address[] memory);

    function caseOf(uint256 caseId) external view returns (Case memory);
    function caseCount() external view returns (uint256);
    /// @notice The case opened against `challengeId`, or zero if none. Case ids
    ///         start at one so zero is unambiguously "not referred".
    function caseOfChallenge(uint256 challengeId) external view returns (uint256);
    /// @notice How `member` voted on `caseId`; `Ruling.None` means it has not.
    function panelVoteOf(uint256 caseId, address member) external view returns (Ruling);

    /// @notice The challenge game this court adjudicates for. Owner-set after
    ///         construction, mirroring `ChallengeGame.setStakedWood`: the two
    ///         contracts reference each other, so one of the two links must be
    ///         wired after both exist.
    function challengeGame() external view returns (address);
    /// @notice How long layer 1 has to rule, measured from `referredAt`.
    function panelWindow() external view returns (uint256);
    /// @notice How long a ruling stays open to a bad-faith challenge (Task 5).
    ///         Read by Task 3 only to escrow a ruling panelist's bond for at
    ///         least that long.
    function badFaithWindow() external view returns (uint256);

    /// @notice The staking contract layer 2's electorate is read from. Its
    ///         `getPastVotes` is the age-weighted primitive §3.5 asks for (D3).
    function stakedWood() external view returns (address);
    /// @notice How long a panel ruling stays appealable, from `panelFinalizedAt`.
    function appealWindow() external view returns (uint256);
    /// @notice How long layer 2's vote stays open, from `appealedAt`.
    function appealVoteWindow() external view returns (uint256);
    /// @notice The WOOD an appellant posts. Forfeits only on a below-floor
    ///         turnout.
    function appealBondWood() external view returns (uint256);
    /// @notice Minimum turnout, in bps of `getPastTotalVotes(snapshotTs)`, for
    ///         an appeal to decide anything (D6). Below it the panel ruling
    ///         stands. Never zero — a zero floor silently deletes the
    ///         anti-capture property that stops a single-digit-turnout appeal
    ///         from being swung cheaply at a ~$15M mcap.
    function participationFloorBps() external view returns (uint256);

    /// @notice WOOD the court holds on behalf of open positions (spec §4): the
    ///         posted panel bonds plus the bonds of appeals and bad-faith
    ///         proceedings still open. The invariant is
    ///         `wood.balanceOf(court) == bondedWood + forfeitedWood`.
    /// @dev    POSTED POSITIONS ONLY. Accrued-but-unclaimed panel rewards are
    ///         NOT counted here — they were never posted by anyone, they are
    ///         protocol-owned WOOD promised to a payee, so they live inside
    ///         `forfeitedWood` and are tracked by `reservedRewards`.
    function bondedWood() external view returns (uint256);

    /// @notice WOOD the court owns outright: appeal bonds forfeited for missing
    ///         the participation floor, and panel bonds slashed for bad faith.
    /// @dev    NO CUSTODIAN AND NO OWNER PATH. It leaves by exactly two routes —
    ///         the flat panel reward, and `burnForfeited`, which anyone may call
    ///         and which sends the unreserved surplus to a dead address. There is
    ///         deliberately no way for governance to direct it anywhere, because
    ///         a party able to receive forfeits is a party that profits when the
    ///         court fails.
    /// @dev    CONTAINS `reservedRewards`: `forfeitedWood >= reservedRewards`
    ///         always, and the difference is the burnable surplus.
    function forfeitedWood() external view returns (uint256);

    /// @notice The part of `forfeitedWood` already committed to accrued panel
    ///         rewards — equal to the sum of every outstanding `panelRewardOf`.
    /// @dev    A SUBSET OF `forfeitedWood`, NOT A THIRD BALANCE, so the §4
    ///         two-term equality is unaffected by it. Reserved at resolution so
    ///         that `burnForfeited` cannot destroy a panel's pay after the panel
    ///         has earned it — which matters beyond bookkeeping, because an
    ///         unpaid panel is an absent panel and a panel that does not rule
    ///         inside `panelWindow` acquits by default.
    function reservedRewards() external view returns (uint256);

    // ── Owner setters ──
    function setPanelBondWood(uint256 newBond) external;
    function setChallengeGame(address newGame) external;
    function setPanelWindow(uint256 newWindow) external;
    function setBadFaithWindow(uint256 newWindow) external;
    function setStakedWood(address newStakedWood) external;
    function setAppealWindow(uint256 newWindow) external;
    function setAppealVoteWindow(uint256 newWindow) external;
    function setAppealBondWood(uint256 newBond) external;
    function setParticipationFloorBps(uint256 newBps) external;
    function setBadFaithBondWood(uint256 newBond) external;
    /// @notice Set the flat per-ruling panel reward. Zero is legal and turns
    ///         rewards off; the only shape this setter refuses is a non-flat one,
    ///         which it does by having no per-verdict argument to give.
    function setPanelRewardWood(uint256 newReward) external;
    // ── Permissionless ──
    /// @notice Burn the unreserved forfeited surplus —
    ///         `forfeitedWood - reservedRewards` — by sending it to a dead
    ///         address. Reverts `NothingToBurn` when that is zero.
    /// @dev    NOT AN OWNER FUNCTION, AND NOT LISTED WITH THEM. It replaced an
    ///         `onlyOwner sweepForfeited(address to)` whose arbitrary recipient
    ///         let whoever ran the court collect every failed appeal bond and
    ///         every slashed panel bond — a standing incentive to see bonds
    ///         forfeited. Burning removes the beneficiary rather than changing
    ///         who it is; permissionless removes the ability to sit on the pot
    ///         instead, which would be the same discretion exercised by
    ///         inaction.
    /// @dev    Never reads or writes `bondedWood`, so no live bond — panel,
    ///         appeal or bad-faith — is ever burnable.
    function burnForfeited() external returns (uint256 amount);
}
