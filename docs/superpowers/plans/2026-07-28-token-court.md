# TokenCourt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two-layer Court (panel + appeal + bad-faith track) with a single-layer, custody-free WOOD-token vote per disputed challenge, per `docs/superpowers/specs/2026-07-28-token-court-design.md`.

**Architecture:** New `TokenCourt.sol` (plain `Ownable2Step`, holds no WOOD) runs one vote per referred dispute at the pre-crime snapshot (`executedAt - 1`) and hands `ChallengeGame.rule` a three-valued `Verdict` (`Guilty`/`NotGuilty`/`Inconclusive`). The game gains `_refundAll` (inconclusive unwind via #50's pull machinery), auto-referral on dispute completion, and a filings-only pause. Everything panel-related is deleted.

**Tech Stack:** Solidity 0.8.28, Foundry (forge 1.7.1 local; fmt with CI-matching forge), OpenZeppelin (Ownable2Step), existing StakedWood checkpoints (`getPastVotes` aged / `getPastTotalVotes` raw / `getPastStake` raw).

**Conventions that bite (from repo guardrails):**
- `vm.prank` is consumed by calls in ARGUMENT position — hoist reads into locals before pranked calls.
- Use `vm.getBlockTimestamp()` in tests, never a cached `block.timestamp` across `vm.warp`.
- `vm.warp` only forward.
- Natspec style: every guard states its adversary; cross-reference spec sections (house style — mirror `ChallengeGame.sol`).

---

### Task 0: Branch setup

**Files:** none (git only)

- [ ] **Step 0.1: Merge PR #50 into `e`** (dependency: `_refundAll` uses its pull machinery)

```bash
cd /Users/anajuliabittencourt/code/sherwood-plan-e
gh pr merge 50 --repo sherwoodagent/sherwood-protocol --merge
git fetch origin && git merge --ff-only origin/feat/guardian-econ-security-e
```
Expected: #50 merged; local `e` fast-forwards; `git log --oneline -3` shows the merge commit containing `017a690`.

- [ ] **Step 0.2: Create the work branch + worktree**

```bash
cd /Users/anajuliabittencourt/code/sherwood-protocol
git worktree add /Users/anajuliabittencourt/code/sherwood-token-court -b feat/token-court origin/feat/guardian-econ-security-e
cd /Users/anajuliabittencourt/code/sherwood-token-court && forge build && forge test --no-match-path 'test/fork/**' -q | tail -3
```
Expected: build OK; same pass/fail baseline as `e` (only fork tests fail without `--fork-url`).

All later paths are relative to `/Users/anajuliabittencourt/code/sherwood-token-court`.

---

### Task 1: Delete the panel court

**Files:**
- Delete: `src/Court.sol`, `src/interfaces/ICourt.sol`, `test/Court.t.sol`, `test/CourtEndToEnd.t.sol`, `test/deploy/DeployPlanEPreflight.t.sol`, `script/DeployPlanE.s.sol`

- [ ] **Step 1.1: Delete**

```bash
git rm src/Court.sol src/interfaces/ICourt.sol test/Court.t.sol test/CourtEndToEnd.t.sol test/deploy/DeployPlanEPreflight.t.sol script/DeployPlanE.s.sol
```

- [ ] **Step 1.2: Sweep dangling references**

```bash
grep -rn "ICourt\|Court\b" src script test --include='*.sol' | grep -v "TokenCourt\|// " | head
```
Expected: only `ChallengeGame.sol` hits for its `court` address variable / `setCourt` / `NotCourt` (those stay). If `ChallengeEndToEnd.t.sol` imports `ICourt`, replace that arc's court interaction with a direct `vm.prank(courtAddr); game.rule(...)` (it already stubs the court as an EOA — check before editing).

- [ ] **Step 1.3: Build + test green, commit**

```bash
forge build && forge test --no-match-path 'test/fork/**' -q | tail -3
git add -A && git commit -m "refactor(court): remove panel court, appeal bonds, bad-faith track (spec 2026-07-28 §2)"
```
Expected: pass count drops by exactly the deleted suites; zero new failures.

---

### Task 2: Three-valued verdict in the game (`Verdict`, `Status.Inconclusive`, `rule`, `_refundAll`)

**Files:**
- Modify: `src/interfaces/IChallengeGame.sol` (Status enum ~line 36, `rule` ~line 334, `ChallengeRuled` event ~line 239, new event/error block)
- Modify: `src/ChallengeGame.sol` (`rule` ~line 739, new `_refundAll` after `_fail` ~line 1090, `claimableContribution` ~line 1150, `claimContribution` ~line 1174)
- Test: `test/ChallengeGame.t.sol`

- [ ] **Step 2.1: Write the failing tests** (append to the rule-path section of `test/ChallengeGame.t.sol`; the file's existing helpers `_disputed()`-style fixtures, `guardianA/B`, `challenger`, `courtAddr` are reused — read the file's helper block first and match names exactly)

```solidity
    function test_rule_inconclusive_refundsBothSidesWhole() public {
        uint256 id = _disputed(); // helper: filed + pool completed -> Status.Disputed
        uint256 challengerBefore = wood.balanceOf(challenger);
        uint256 bondedBefore = game.bondedWood();

        vm.prank(courtAddr);
        game.rule(id, IChallengeGame.Verdict.Inconclusive);

        IChallengeGame.Challenge memory c = game.challengeOf(id);
        assertEq(uint256(c.status), uint256(IChallengeGame.Status.Inconclusive), "terminal status");
        // Challenger bond back WHOLE - no settleBurn slice: nothing was adjudicated.
        assertEq(wood.balanceOf(challenger) - challengerBefore, c.bondWood, "challenger whole");
        // Pool booked as pull-claims, not pushed.
        assertEq(game.unclaimedWood(), c.counterBondWood, "pool booked");
        assertEq(game.bondedWood(), bondedBefore - c.bondWood - c.counterBondWood, "bonded released");
        // Freeze released: the proposal's coverage is live again.
        assertEq(game.liveChallengeCountOf(address(governor), PROPOSAL_ID), 0, "freeze released");
    }

    function test_rule_inconclusive_contributorsClaimExactlyTheirStake() public {
        uint256 id = _disputed();
        uint256 stake = game.counterBondContributionOf(id, guardianA);
        vm.prank(courtAddr);
        game.rule(id, IChallengeGame.Verdict.Inconclusive);

        assertEq(game.claimableContribution(id, guardianA), stake, "stake back, no winnings");
        uint256 before = wood.balanceOf(guardianA);
        vm.prank(guardianA);
        game.claimContribution(id);
        assertEq(wood.balanceOf(guardianA) - before, stake, "claimed");
    }

    function test_rule_verdictMapping() public {
        // Guilty -> Settled, NotGuilty -> Failed (existing paths, new signature).
        uint256 g = _disputed();
        vm.prank(courtAddr);
        game.rule(g, IChallengeGame.Verdict.Guilty);
        assertEq(uint256(game.challengeOf(g).status), uint256(IChallengeGame.Status.Settled));

        uint256 n = _disputedSecondProposal(); // if no such helper exists, file+dispute a second proposal id inline
        vm.prank(courtAddr);
        game.rule(n, IChallengeGame.Verdict.NotGuilty);
        assertEq(uint256(game.challengeOf(n).status), uint256(IChallengeGame.Status.Failed));
    }

    function test_rule_inconclusive_allowsRefilingSameProposal() public {
        uint256 id = _disputed();
        vm.prank(courtAddr);
        game.rule(id, IChallengeGame.Verdict.Inconclusive);
        // A fresh filing on the SAME proposal must succeed - no _convicted mark.
        _fileAgainSameProposal(); // reuse the file() fixture with fresh challenger funds; expect no revert
    }
```

- [ ] **Step 2.2: Run to verify failure**

```bash
forge test --match-test 'test_rule_inconclusive|test_rule_verdictMapping' -q 2>&1 | tail -5
```
Expected: FAIL to **compile** — `Verdict` and `Status.Inconclusive` undefined. Compile failure is this step's red.

- [ ] **Step 2.3: Interface changes** (`src/interfaces/IChallengeGame.sol`)

Append to `Status` (append-only — existing members keep their integers, indexers unaffected):

```solidity
    enum Status {
        None,
        Filed,
        Disputed,
        Failed,
        Settled,
        Inconclusive
    }

    /// @notice The court's three-valued outcome for a disputed challenge
    ///         (spec 2026-07-28 §4). `Inconclusive` is a NON-VERDICT: the vote
    ///         missed its participation floor, so nothing was adjudicated and
    ///         both sides unwind whole.
    enum Verdict {
        Guilty,
        NotGuilty,
        Inconclusive
    }
```

Replace the `rule` declaration and `ChallengeRuled` event; add the new event:

```solidity
    event ChallengeRuled(uint256 indexed challengeId, Verdict verdict);
    /// @notice Inconclusive unwind: challenger bond returned whole, pool booked
    ///         for pull-claims, no conviction, no demotion (spec 2026-07-28 §4).
    event ChallengeInconclusive(uint256 indexed challengeId, uint256 bondWood, uint256 poolWood);

    function rule(uint256 challengeId, Verdict verdict) external;
```

- [ ] **Step 2.4: Game changes** (`src/ChallengeGame.sol`)

`rule` becomes a three-way dispatch (natspec: adapt the existing block — the "RULING BEATS THE TIMEOUT" and CEI paragraphs stand; "single verdict bit" becomes "single verdict enum"):

```solidity
    function rule(uint256 challengeId, Verdict verdict) external {
        if (msg.sender != court) revert NotCourt();
        Challenge storage c = _challenges[challengeId];
        if (c.status != Status.Disputed) revert WrongStatus();
        emit ChallengeRuled(challengeId, verdict);
        if (verdict == Verdict.Guilty) {
            _settle(challengeId, c);
        } else if (verdict == Verdict.NotGuilty) {
            _fail(challengeId, c);
        } else {
            _refundAll(challengeId, c);
        }
    }
```

New `_refundAll` directly after `_fail` (natspec must state: unwind not verdict; challenger whole because burning an unwound bond would price electorate apathy onto the challenger; pull machinery because open standing makes the contributor list unbounded; no `_convicted`/no demotion so the proposal is re-challengeable):

```solidity
    function _refundAll(uint256 challengeId, Challenge storage c) private {
        address governor = c.governor;
        uint256 proposalId = c.proposalId;
        uint256 bond = c.bondWood;
        uint256 pool = c.counterBondWood;
        address challenger = c.challenger;

        c.status = Status.Inconclusive;
        bondedWood -= (bond + pool);
        _releaseFreeze(_reviewKey(governor, proposalId), governor, proposalId);

        _bookRefund(challengeId, pool);
        wood.safeTransfer(challenger, bond);
        emit ChallengeInconclusive(challengeId, bond, pool);
    }
```

`claimableContribution`: add the branch (stake back, no winnings — mirror the part-funded `Settled` case):

```solidity
        if (c.status == Status.Inconclusive) {
            return contributed; // unwind: stake back, nothing was won or lost
        }
```

`claimContribution`: widen the terminal gate:

```solidity
        if (status != Status.Failed && status != Status.Settled && status != Status.Inconclusive) {
            revert ChallengeNotTerminal();
        }
```

- [ ] **Step 2.5: Migrate existing `rule(bool)` call sites**

```bash
grep -rln 'game.rule(' test | xargs sed -i '' \
  -e 's/game\.rule(\([^,]*\), true)/game.rule(\1, IChallengeGame.Verdict.Guilty)/g' \
  -e 's/game\.rule(\([^,]*\), false)/game.rule(\1, IChallengeGame.Verdict.NotGuilty)/g'
grep -rn 'game\.rule(' test --include='*.sol' | grep -v Verdict
```
Expected: second grep empty. Then spot-check `test/ChallengeEndToEnd.t.sol` visually — sed must not have touched prose in comments.

- [ ] **Step 2.6: Run tests, then full suite, commit**

```bash
forge test --match-test 'test_rule_inconclusive|test_rule_verdictMapping' -q | tail -3
forge test --no-match-path 'test/fork/**' -q | tail -3
git add -A && git commit -m "feat(game): three-valued Verdict with Inconclusive refund-all path (spec §4)"
```
Expected: new tests PASS; suite baseline otherwise unchanged.

---

### Task 3: Filings pause

**Files:**
- Modify: `src/interfaces/IChallengeGame.sol` (error + event + getters), `src/ChallengeGame.sol` (`file` guard + setter)
- Test: `test/ChallengeGame.t.sol`

- [ ] **Step 3.1: Failing tests**

```solidity
    function test_setFilingsPaused_gatesFileOnly() public {
        uint256 id = _disputed(); // in-flight challenge BEFORE the pause
        vm.prank(owner);
        game.setFilingsPaused(true);

        // New filings refused...
        vm.expectRevert(IChallengeGame.FilingsPaused.selector);
        _fileSecondProposal(); // reuse the standard file() fixture on a fresh proposal

        // ...but every in-flight right still runs: rule, claims.
        vm.prank(courtAddr);
        game.rule(id, IChallengeGame.Verdict.Inconclusive);
        vm.prank(guardianA);
        game.claimContribution(id);
    }

    function test_setFilingsPaused_onlyOwner() public {
        vm.prank(challenger);
        vm.expectRevert(); // Ownable unauthorized
        game.setFilingsPaused(true);
    }
```

- [ ] **Step 3.2: Run, expect compile failure** (`setFilingsPaused` undefined)

```bash
forge test --match-test test_setFilingsPaused -q 2>&1 | tail -3
```

- [ ] **Step 3.3: Implement**

Interface:

```solidity
    error FilingsPaused();
    event FilingsPausedSet(bool paused);
    /// @notice The ONLY human backstop in the adjudication stack (spec §4):
    ///         gates `file` alone. dispute/resolve/rule/claims always run, so
    ///         no in-flight challenge's rights depend on the owner.
    function filingsPaused() external view returns (bool);
    function setFilingsPaused(bool paused) external;
```

Game — state var beside the other owner params, guard as `file`'s FIRST check, setter beside the other owner setters:

```solidity
    bool public filingsPaused;

    // at the top of file():
        if (filingsPaused) revert FilingsPaused();

    function setFilingsPaused(bool paused) external onlyOwner {
        filingsPaused = paused;
        emit FilingsPausedSet(paused);
    }
```

- [ ] **Step 3.4: Run + commit**

```bash
forge test --match-test test_setFilingsPaused -q | tail -3 && forge test --no-match-path 'test/fork/**' -q | tail -3
git add -A && git commit -m "feat(game): owner pause on file() only - the whole human backstop (spec §4)"
```

---

### Task 4: `ITokenCourt` + contract skeleton (wiring, setters, views)

**Files:**
- Create: `src/interfaces/ITokenCourt.sol`, `src/TokenCourt.sol`
- Create: `test/TokenCourt.t.sol` (with local mocks)

**Compile strategy for Tasks 4–7:** the contract only satisfies `ITokenCourt` once `refer`/`vote`/`finalize` exist (Task 7). Until then, declare events/errors LOCALLY in `TokenCourt.sol` (duplicating the interface declarations verbatim) and do NOT put `ITokenCourt` on the contract's inheritance line. Task 7 adds the parent and deletes the local copies. This keeps every intermediate commit compiling without reverting stubs.

- [ ] **Step 4.1: Write the interface** (`src/interfaces/ITokenCourt.sol`) — complete:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IChallengeGame} from "./IChallengeGame.sol";

/// @title  ITokenCourt
/// @notice Single-layer WOOD-vote adjudication of disputed challenges
///         (spec 2026-07-28-token-court-design.md). Replaces the two-layer
///         panel court. HOLDS NO WOOD: no bonds, no custody, pure logic.
interface ITokenCourt {
    enum Phase {
        None,
        Voting,
        Resolved
    }

    enum Ruling {
        None,
        Guilty,
        NotGuilty
    }

    struct Case {
        uint256 challengeId;
        uint256 snapshotTs; // executedAt - 1, written once in refer (D2)
        uint256 referredAt;
        uint256 voteWindowAtReferral; // pinned: owner cannot move a live case's clock (F5)
        uint256 accusedWeight; // raw getPastStake sum at snapshotTs (F17 same-basis)
        uint256 guiltyVotes; // aged weight
        uint256 notGuiltyVotes; // aged weight
        Phase phase;
        IChallengeGame.Verdict verdict;
        uint256 finalizedAt;
    }

    error ZeroAddress();
    error InvalidParameter();
    error AlreadyReferred();
    error ChallengeNotDisputed();
    error InsufficientClock();
    error WrongPhase();
    error WindowOpen();
    error WindowClosed();
    error AlreadyVoted();
    error AccusedCannotVote();
    error NoVotingPower();

    event CaseReferred(
        uint256 indexed caseId,
        uint256 indexed challengeId,
        address indexed governor,
        uint256 proposalId,
        uint256 snapshotTs
    );
    event AccusedSetRecorded(uint256 indexed caseId, uint256 count, uint256 accusedWeight);
    event VoteCast(uint256 indexed caseId, address indexed voter, bool guilty, uint256 weight);
    event CaseFinalized(
        uint256 indexed caseId,
        IChallengeGame.Verdict verdict,
        uint256 guiltyVotes,
        uint256 notGuiltyVotes,
        uint256 floor
    );
    /// @notice `rule` reverted: the challenge went terminal (timeout during the
    ///         finalize buffer) before the verdict landed. The case still
    ///         closes; with zero custody this is bookkeeping, not fund loss.
    event ChallengeAlreadyTerminal(uint256 indexed caseId, uint256 indexed challengeId);
    event ChallengeGameSet(address indexed oldGame, address indexed newGame);
    event StakedWoodSet(address indexed oldStakedWood, address indexed newStakedWood);
    event VoteWindowSet(uint256 oldWindow, uint256 newWindow);
    event ParticipationFloorBpsSet(uint256 oldBps, uint256 newBps);

    function MAX_VOTE_WINDOW() external view returns (uint256);
    function FINALIZE_BUFFER() external view returns (uint256);
    function challengeGame() external view returns (address);
    function stakedWood() external view returns (address);
    function voteWindow() external view returns (uint256);
    function participationFloorBps() external view returns (uint256);
    function caseCount() external view returns (uint256);
    function caseOfChallenge(uint256 challengeId) external view returns (uint256);
    function caseOf(uint256 caseId) external view returns (Case memory);
    function voteOf(uint256 caseId, address voter) external view returns (Ruling);
    function isAccused(uint256 caseId, address account) external view returns (bool);
    function accusedOf(uint256 caseId) external view returns (address[] memory);

    function refer(uint256 challengeId) external returns (uint256 caseId);
    function vote(uint256 caseId, bool guilty) external;
    function finalize(uint256 caseId) external;

    function setChallengeGame(address newGame) external;
    function setStakedWood(address newStakedWood) external;
    function setVoteWindow(uint256 newWindow) external;
    function setParticipationFloorBps(uint256 newBps) external;
}
```

- [ ] **Step 4.2: Failing tests** — create `test/TokenCourt.t.sol` (complete file; grows in Tasks 5–7). Before writing the governor mock, read `src/interfaces/ISyndicateGovernor.sol` for `getProposal`'s exact return struct and copy its shape — the mock below marks the one field the court reads:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TokenCourt} from "../src/TokenCourt.sol";
import {ITokenCourt} from "../src/interfaces/ITokenCourt.sol";
import {IChallengeGame} from "../src/interfaces/IChallengeGame.sol";
import {MockStakedWood} from "./mocks/MockStakedWood.sol";

/// @dev Just enough game for the court: a settable challenge record, the
///      ledger pointer the court reads, and a `rule` recorder with a revert
///      toggle for the terminal-race test.
contract MockGameForCourt {
    mapping(uint256 => IChallengeGame.Challenge) internal _challenges;
    address public exposureLedger;
    bool public ruleReverts;
    uint256 public lastRuledChallenge;
    IChallengeGame.Verdict public lastVerdict;
    bool public ruled;

    function setExposureLedger(address l) external {
        exposureLedger = l;
    }

    function setRuleReverts(bool r) external {
        ruleReverts = r;
    }

    function setChallenge(
        uint256 id,
        address governor,
        uint256 proposalId,
        IChallengeGame.Status status,
        uint256 filedAt,
        uint256 disputeTimeoutAtFiling
    ) external {
        IChallengeGame.Challenge storage c = _challenges[id];
        c.governor = governor;
        c.proposalId = proposalId;
        c.status = status;
        c.filedAt = filedAt;
        c.disputeTimeoutAtFiling = disputeTimeoutAtFiling;
    }

    function challengeOf(uint256 id) external view returns (IChallengeGame.Challenge memory) {
        return _challenges[id];
    }

    function rule(uint256 challengeId, IChallengeGame.Verdict verdict) external {
        if (ruleReverts) revert IChallengeGame.WrongStatus();
        ruled = true;
        lastRuledChallenge = challengeId;
        lastVerdict = verdict;
    }
}

/// @dev Copy the exact getProposal return-struct shape from
///      ISyndicateGovernor.sol; only executedAt matters to the court. The
///      deleted test/Court.t.sol had a working MockGovernor - recover it with
///      `git show HEAD~1:test/Court.t.sol` and reuse its governor mock verbatim.
contract MockGovernorForCourt {
    // ... (recovered shape; setExecuted(proposalId, ts) setter + getProposal view)
}

contract MockLedgerForCourt {
    address[] internal _approvers;
    uint256[] internal _committed;

    function setApprovers(address[] memory a, uint256[] memory c) external {
        _approvers = a;
        _committed = c;
    }

    function approversOf(address, uint256) external view returns (address[] memory, uint256[] memory) {
        return (_approvers, _committed);
    }
}

contract TokenCourtTest is Test {
    TokenCourt internal court;
    MockGameForCourt internal game;
    MockGovernorForCourt internal governor;
    MockLedgerForCourt internal ledger;
    MockStakedWood internal swood;

    address internal owner = makeAddr("owner");
    address internal voterA = makeAddr("voterA");
    address internal voterB = makeAddr("voterB");
    address internal accusedG = makeAddr("accusedG");
    uint256 internal constant CHALLENGE_ID = 7;
    uint256 internal constant PROPOSAL_ID = 42;

    function setUp() public {
        court = new TokenCourt(owner);
        game = new MockGameForCourt();
        governor = new MockGovernorForCourt();
        ledger = new MockLedgerForCourt();
        swood = new MockStakedWood();
        game.setExposureLedger(address(ledger));
        vm.prank(owner);
        court.setChallengeGame(address(game));
        vm.prank(owner);
        court.setStakedWood(address(swood));
    }

    // ── Task 4: wiring + setters ──

    function test_constructor_defaults() public view {
        assertEq(court.voteWindow(), 5 days);
        assertEq(court.participationFloorBps(), 1_000);
        assertEq(court.FINALIZE_BUFFER(), 1 days);
        assertEq(court.MAX_VOTE_WINDOW(), 14 days);
    }

    function test_setters_boundsAndValues() public {
        vm.startPrank(owner);
        vm.expectRevert(ITokenCourt.InvalidParameter.selector);
        court.setVoteWindow(0);
        vm.expectRevert(ITokenCourt.InvalidParameter.selector);
        court.setVoteWindow(14 days + 1);
        vm.expectRevert(ITokenCourt.InvalidParameter.selector);
        court.setParticipationFloorBps(0);
        vm.expectRevert(ITokenCourt.InvalidParameter.selector);
        court.setParticipationFloorBps(10_001);
        vm.expectRevert(ITokenCourt.ZeroAddress.selector);
        court.setChallengeGame(address(0));
        vm.expectRevert(ITokenCourt.ZeroAddress.selector);
        court.setStakedWood(address(0));
        court.setVoteWindow(7 days);
        assertEq(court.voteWindow(), 7 days);
        vm.stopPrank();
    }

    function test_setters_onlyOwner() public {
        vm.prank(voterA);
        vm.expectRevert();
        court.setVoteWindow(7 days);
    }
}
```

- [ ] **Step 4.3: Run to verify compile failure** (`TokenCourt` missing)

```bash
forge test --match-contract TokenCourtTest -q 2>&1 | tail -3
```

- [ ] **Step 4.4: Implement the skeleton** (`src/TokenCourt.sol`) — complete through setters (per the Task-4 compile strategy: local event/error copies, no `ITokenCourt` parent yet):

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ITokenCourt} from "./interfaces/ITokenCourt.sol";
import {IChallengeGame} from "./interfaces/IChallengeGame.sol";
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";
import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {IStakedWood} from "./interfaces/IStakedWood.sol";

/// @notice The one thing the court needs from the game that `IChallengeGame`
///         does not declare: WHICH LEDGER THE GAME TRUSTS. Read from the game,
///         never from the challenger-supplied governor - a hostile governor
///         could report no approvers and delete the accused set. (Reasoning
///         ported unchanged from the deleted Court.sol.)
interface IChallengeGameLedger {
    function exposureLedger() external view returns (address);
}

contract TokenCourt is Ownable2Step {
    uint256 public constant MAX_VOTE_WINDOW = 14 days;
    /// @notice Grace period after the vote window for someone to call
    ///         `finalize` before the challenge's own timeout can fire.
    uint256 public constant FINALIZE_BUFFER = 1 days;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    address public challengeGame;
    address public stakedWood;
    uint256 public voteWindow = 5 days;
    uint256 public participationFloorBps = 1_000;

    uint256 public caseCount;
    mapping(uint256 caseId => ITokenCourt.Case) internal _cases;
    mapping(uint256 challengeId => uint256 caseId) public caseOfChallenge;
    mapping(uint256 caseId => mapping(address voter => ITokenCourt.Ruling)) public voteOf;
    mapping(uint256 caseId => mapping(address account => bool)) public isAccused;
    mapping(uint256 caseId => address[]) internal _accused;

    // Local copies until Task 7 adds the ITokenCourt parent (then delete these).
    error ZeroAddress();
    error InvalidParameter();
    event ChallengeGameSet(address indexed oldGame, address indexed newGame);
    event StakedWoodSet(address indexed oldStakedWood, address indexed newStakedWood);
    event VoteWindowSet(uint256 oldWindow, uint256 newWindow);
    event ParticipationFloorBpsSet(uint256 oldBps, uint256 newBps);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function caseOf(uint256 caseId) external view returns (ITokenCourt.Case memory) {
        return _cases[caseId];
    }

    function accusedOf(uint256 caseId) external view returns (address[] memory) {
        return _accused[caseId];
    }

    function setChallengeGame(address newGame) external onlyOwner {
        if (newGame == address(0)) revert ZeroAddress();
        emit ChallengeGameSet(challengeGame, newGame);
        challengeGame = newGame;
    }

    function setStakedWood(address newStakedWood) external onlyOwner {
        if (newStakedWood == address(0)) revert ZeroAddress();
        emit StakedWoodSet(stakedWood, newStakedWood);
        stakedWood = newStakedWood;
    }

    function setVoteWindow(uint256 newWindow) external onlyOwner {
        if (newWindow == 0 || newWindow > MAX_VOTE_WINDOW) revert InvalidParameter();
        emit VoteWindowSet(voteWindow, newWindow);
        voteWindow = newWindow;
    }

    function setParticipationFloorBps(uint256 newBps) external onlyOwner {
        if (newBps == 0 || newBps > BPS_DENOMINATOR) revert InvalidParameter();
        emit ParticipationFloorBpsSet(participationFloorBps, newBps);
        participationFloorBps = newBps;
    }
}
```

Note: while the local-copies strategy is active, tests referencing `ITokenCourt.ZeroAddress.selector` etc. still pass — identical error signatures hash to identical selectors regardless of where they are declared.

- [ ] **Step 4.5: Run + commit**

```bash
forge test --match-contract TokenCourtTest -q | tail -3
git add -A && git commit -m "feat(court): TokenCourt skeleton - wiring, bounded setters, zero custody (spec §3)"
```

---

### Task 5: `refer` — clock check + accused recording

**Files:**
- Modify: `src/TokenCourt.sol`, `test/TokenCourt.t.sol`

- [ ] **Step 5.1: Failing tests** (append; helper first). `MockStakedWood` already has `getPastStake` from F17 — verify its setter name with `grep -n "PastStake\|PastVotes\|PastTotalVotes" test/mocks/MockStakedWood.sol` and use the existing names:

```solidity
    /// @dev Disputed challenge with sane clocks: filed now, 30d timeout,
    ///      proposal executed 1d ago. CHALLENGE_ID becomes referable.
    function _disputedChallenge() internal {
        governor.setExecuted(PROPOSAL_ID, vm.getBlockTimestamp() - 1 days);
        game.setChallenge(
            CHALLENGE_ID, address(governor), PROPOSAL_ID, IChallengeGame.Status.Disputed, vm.getBlockTimestamp(), 30 days
        );
    }

    function test_refer_recordsSnapshotAndAccused() public {
        _disputedChallenge();
        address[] memory a = new address[](2);
        uint256[] memory c = new uint256[](2);
        a[0] = accusedG;
        c[0] = 100e18;
        a[1] = makeAddr("released");
        c[1] = 0; // released before filing: not accused
        ledger.setApprovers(a, c);
        uint256 snap = vm.getBlockTimestamp() - 1 days - 1;
        swood.setPastStake(accusedG, snap, 500e18);

        uint256 caseId = court.refer(CHALLENGE_ID);

        ITokenCourt.Case memory cs = court.caseOf(caseId);
        assertEq(cs.snapshotTs, snap, "executedAt - 1");
        assertEq(cs.voteWindowAtReferral, 5 days, "window pinned");
        assertEq(cs.accusedWeight, 500e18, "raw getPastStake sum");
        assertTrue(court.isAccused(caseId, accusedG));
        assertFalse(court.isAccused(caseId, a[1]), "released is not accused");
        assertEq(court.caseOfChallenge(CHALLENGE_ID), caseId);
    }

    function test_refer_guards() public {
        // Unwired court refuses (review E4 closed structurally).
        TokenCourt fresh = new TokenCourt(owner);
        vm.expectRevert(ITokenCourt.ZeroAddress.selector);
        fresh.refer(CHALLENGE_ID);

        // Not disputed.
        governor.setExecuted(PROPOSAL_ID, vm.getBlockTimestamp() - 1 days);
        game.setChallenge(
            CHALLENGE_ID, address(governor), PROPOSAL_ID, IChallengeGame.Status.Filed, vm.getBlockTimestamp(), 30 days
        );
        vm.expectRevert(ITokenCourt.ChallengeNotDisputed.selector);
        court.refer(CHALLENGE_ID);

        // Unexecuted proposal fails closed.
        game.setChallenge(
            CHALLENGE_ID, address(governor), PROPOSAL_ID, IChallengeGame.Status.Disputed, vm.getBlockTimestamp(), 30 days
        );
        governor.setExecuted(PROPOSAL_ID, 0);
        vm.expectRevert(ITokenCourt.InvalidParameter.selector);
        court.refer(CHALLENGE_ID);

        // Double referral.
        governor.setExecuted(PROPOSAL_ID, vm.getBlockTimestamp() - 1 days);
        court.refer(CHALLENGE_ID);
        vm.expectRevert(ITokenCourt.AlreadyReferred.selector);
        court.refer(CHALLENGE_ID);
    }

    function test_refer_clockCheckBoundary() public {
        // remaining == voteWindow + FINALIZE_BUFFER passes; one second less refuses.
        uint256 filedAt = vm.getBlockTimestamp();
        governor.setExecuted(PROPOSAL_ID, filedAt - 1 days);
        game.setChallenge(CHALLENGE_ID, address(governor), PROPOSAL_ID, IChallengeGame.Status.Disputed, filedAt, 30 days);

        uint256 exactLatest = filedAt + 30 days - (5 days + 1 days);
        vm.warp(exactLatest);
        uint256 caseId = court.refer(CHALLENGE_ID); // boundary passes
        assertEq(caseId, 1);

        game.setChallenge(
            CHALLENGE_ID + 1, address(governor), PROPOSAL_ID, IChallengeGame.Status.Disputed, filedAt, 30 days
        );
        vm.warp(exactLatest + 1);
        vm.expectRevert(ITokenCourt.InsufficientClock.selector);
        court.refer(CHALLENGE_ID + 1);
    }
```

- [ ] **Step 5.2: Run, expect compile failure** (`refer` missing)

- [ ] **Step 5.3: Implement `refer` + `_recordAccused`** (natspec: port the deleted Court.sol blocks for D2 snapshot discipline, claim-state-before-external-reads hostile-governor ordering, ledger-from-game, released-commitment exclusion, dedup guard — the reasoning is identical; state the clock check's purpose: a vote that could not finish before the challenge's timeout never opens, which turns review E1's race from live into structural). Add the Task-5 local declarations (`AlreadyReferred`, `ChallengeNotDisputed`, `InsufficientClock`, `CaseReferred`, `AccusedSetRecorded`) beside the Task-4 ones:

```solidity
    function refer(uint256 challengeId) external returns (uint256 caseId) {
        address game = challengeGame;
        address swood = stakedWood;
        if (game == address(0) || swood == address(0)) revert ZeroAddress();
        if (caseOfChallenge[challengeId] != 0) revert AlreadyReferred();

        // Claim state before any external read (hostile-governor ordering).
        caseId = ++caseCount;
        caseOfChallenge[challengeId] = caseId;

        IChallengeGame.Challenge memory ch = IChallengeGame(game).challengeOf(challengeId);
        if (ch.status != IChallengeGame.Status.Disputed) revert ChallengeNotDisputed();

        uint256 window = voteWindow;
        if (block.timestamp + window + FINALIZE_BUFFER > ch.filedAt + ch.disputeTimeoutAtFiling) {
            revert InsufficientClock();
        }

        uint256 executedAt = ISyndicateGovernor(ch.governor).getProposal(ch.proposalId).executedAt;
        if (executedAt == 0) revert InvalidParameter();
        uint256 snapshotTs = executedAt - 1;

        ITokenCourt.Case storage c = _cases[caseId];
        c.challengeId = challengeId;
        c.snapshotTs = snapshotTs;
        c.referredAt = block.timestamp;
        c.voteWindowAtReferral = window;
        c.phase = ITokenCourt.Phase.Voting;

        emit CaseReferred(caseId, challengeId, ch.governor, ch.proposalId, snapshotTs);
        _recordAccused(caseId, c, game, ch.governor, ch.proposalId, snapshotTs);
    }

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
            if (committedUsd[i] == 0) continue; // released before the filing
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
```

- [ ] **Step 5.4: Run + commit**

```bash
forge test --match-contract TokenCourtTest -q | tail -3
git add -A && git commit -m "feat(court): refer with clock check and accused recording (spec §3)"
```

---

### Task 6: `vote`

**Files:** `src/TokenCourt.sol`, `test/TokenCourt.t.sol`

- [ ] **Step 6.1: Failing tests**

```solidity
    function _referredCase() internal returns (uint256 caseId) {
        _disputedChallenge();
        address[] memory a = new address[](1);
        uint256[] memory cm = new uint256[](1);
        a[0] = accusedG;
        cm[0] = 100e18;
        ledger.setApprovers(a, cm);
        caseId = court.refer(CHALLENGE_ID);
        uint256 snap = court.caseOf(caseId).snapshotTs;
        swood.setPastVotes(voterA, snap, 300e18);
        swood.setPastVotes(voterB, snap, 200e18);
        swood.setPastTotalVotes(snap, 1_000e18);
    }

    function test_vote_tallies_agedWeight() public {
        uint256 id = _referredCase();
        vm.prank(voterA);
        court.vote(id, true);
        vm.prank(voterB);
        court.vote(id, false);
        ITokenCourt.Case memory c = court.caseOf(id);
        assertEq(c.guiltyVotes, 300e18);
        assertEq(c.notGuiltyVotes, 200e18);
        assertEq(uint256(court.voteOf(id, voterA)), uint256(ITokenCourt.Ruling.Guilty));
    }

    function test_vote_guards() public {
        uint256 id = _referredCase();

        vm.prank(voterA);
        court.vote(id, true);
        vm.prank(voterA);
        vm.expectRevert(ITokenCourt.AlreadyVoted.selector);
        court.vote(id, false);

        vm.prank(accusedG);
        vm.expectRevert(ITokenCourt.AccusedCannotVote.selector);
        court.vote(id, false);

        address dust = makeAddr("noWeight");
        vm.prank(dust);
        vm.expectRevert(ITokenCourt.NoVotingPower.selector);
        court.vote(id, true);

        vm.warp(vm.getBlockTimestamp() + 5 days);
        vm.prank(voterB);
        vm.expectRevert(ITokenCourt.WindowClosed.selector);
        court.vote(id, false);
    }
```

- [ ] **Step 6.2: Run, expect compile failure**

- [ ] **Step 6.3: Implement** (natspec: D3 no re-weighting — `getPastVotes` already ages; the snapshot bars post-drain stake, the accused bar covers pre-positioned defendants — port the deleted `voteAppeal` reasoning; a defendant that can outvote its jury inverts the layer). Local declarations: `WrongPhase`, `WindowClosed`, `AlreadyVoted`, `AccusedCannotVote`, `NoVotingPower`, `VoteCast`:

```solidity
    function vote(uint256 caseId, bool guilty) external {
        ITokenCourt.Case storage c = _cases[caseId];
        if (c.phase != ITokenCourt.Phase.Voting) revert WrongPhase();
        if (block.timestamp >= c.referredAt + c.voteWindowAtReferral) revert WindowClosed();
        if (voteOf[caseId][msg.sender] != ITokenCourt.Ruling.None) revert AlreadyVoted();
        if (isAccused[caseId][msg.sender]) revert AccusedCannotVote();

        uint256 weight = IStakedWood(stakedWood).getPastVotes(msg.sender, c.snapshotTs);
        if (weight == 0) revert NoVotingPower();

        voteOf[caseId][msg.sender] = guilty ? ITokenCourt.Ruling.Guilty : ITokenCourt.Ruling.NotGuilty;
        if (guilty) c.guiltyVotes += weight;
        else c.notGuiltyVotes += weight;
        emit VoteCast(caseId, msg.sender, guilty, weight);
    }
```

- [ ] **Step 6.4: Run + commit**

```bash
forge test --match-contract TokenCourtTest -q | tail -3
git add -A && git commit -m "feat(court): snapshot-weighted open voting, accused barred (spec §3)"
```

---

### Task 7: `finalize` — floor, verdict, terminal-race try/catch; wire the interface

**Files:** `src/TokenCourt.sol`, `test/TokenCourt.t.sol`

- [ ] **Step 7.1: Failing tests**

```solidity
    function test_finalize_verdictMatrix_guiltyMajority() public {
        // floor = 10% of (1000e18 total - 0 accused stake) = 100e18.
        uint256 id = _referredCase();
        vm.prank(voterA);
        court.vote(id, true); // 300e18 guilty
        vm.prank(voterB);
        court.vote(id, false); // 200e18 not guilty -> turnout 500e18 >= floor
        vm.warp(vm.getBlockTimestamp() + 5 days);
        court.finalize(id);
        ITokenCourt.Case memory c = court.caseOf(id);
        assertEq(uint256(c.verdict), uint256(IChallengeGame.Verdict.Guilty));
        assertEq(uint256(c.phase), uint256(ITokenCourt.Phase.Resolved));
        assertEq(uint256(game.lastVerdict()), uint256(IChallengeGame.Verdict.Guilty));
        assertEq(game.lastRuledChallenge(), CHALLENGE_ID);
    }

    function test_finalize_tieAcquits() public {
        uint256 id = _referredCase();
        uint256 snap = court.caseOf(id).snapshotTs;
        swood.setPastVotes(voterB, snap, 300e18); // equalize
        vm.prank(voterA);
        court.vote(id, true);
        vm.prank(voterB);
        court.vote(id, false);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        court.finalize(id);
        assertEq(uint256(court.caseOf(id).verdict), uint256(IChallengeGame.Verdict.NotGuilty), "tie -> fail-safe");
    }

    function test_finalize_belowFloorInconclusive_andZeroTurnout() public {
        uint256 id = _referredCase();
        uint256 snap = court.caseOf(id).snapshotTs;
        address dust = makeAddr("dustVoter");
        swood.setPastVotes(dust, snap, 1e18); // 1e18 << 100e18 floor
        vm.prank(dust);
        court.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        court.finalize(id);
        assertEq(uint256(court.caseOf(id).verdict), uint256(IChallengeGame.Verdict.Inconclusive));

        // Zero turnout on a second case.
        game.setChallenge(
            CHALLENGE_ID + 1, address(governor), PROPOSAL_ID, IChallengeGame.Status.Disputed, vm.getBlockTimestamp(), 30 days
        );
        uint256 id2 = court.refer(CHALLENGE_ID + 1);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        court.finalize(id2);
        assertEq(uint256(court.caseOf(id2).verdict), uint256(IChallengeGame.Verdict.Inconclusive));
    }

    function test_finalize_accusedWeightLowersFloor() public {
        _disputedChallenge();
        address[] memory a = new address[](1);
        uint256[] memory cm = new uint256[](1);
        a[0] = accusedG;
        cm[0] = 100e18;
        ledger.setApprovers(a, cm);
        uint256 snap = vm.getBlockTimestamp() - 1 days - 1;
        swood.setPastStake(accusedG, snap, 600e18); // raw accused stake
        swood.setPastTotalVotes(snap, 1_000e18);
        swood.setPastVotes(voterA, snap, 45e18);
        uint256 id = court.refer(CHALLENGE_ID);
        // floor = 10% of (1000 - 600) = 40e18; 45e18 turnout clears it.
        vm.prank(voterA);
        court.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        court.finalize(id);
        assertEq(uint256(court.caseOf(id).verdict), uint256(IChallengeGame.Verdict.Guilty));
    }

    function test_finalize_terminalRace_caseClosesViaCatch() public {
        // Ordering 2 of the review-E1 race: challenge went terminal first.
        uint256 id = _referredCase();
        vm.prank(voterA);
        court.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        game.setRuleReverts(true); // game: "already terminal"
        vm.expectEmit(true, true, false, false);
        emit ITokenCourt.ChallengeAlreadyTerminal(id, CHALLENGE_ID);
        court.finalize(id);
        assertEq(uint256(court.caseOf(id).phase), uint256(ITokenCourt.Phase.Resolved), "case closed anyway");
        assertFalse(game.ruled(), "verdict never landed");
    }

    function test_finalize_guards() public {
        uint256 id = _referredCase();
        vm.expectRevert(ITokenCourt.WindowOpen.selector);
        court.finalize(id);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        court.finalize(id);
        vm.expectRevert(ITokenCourt.WrongPhase.selector);
        court.finalize(id); // already resolved
    }
```

- [ ] **Step 7.2: Run, expect compile failure**

- [ ] **Step 7.3: Implement `finalize` + `_participationFloor`; change the contract line to `contract TokenCourt is Ownable2Step, ITokenCourt` and DELETE every local event/error copy** (the interface now supplies them; `@inheritdoc ITokenCourt` on each public function). `_participationFloor` natspec: write the POST-#29 argument ONLY (this is review finding E3's fix carried forward): the subtrahend is a sum of `getPastStake` values — the same raw basis `getPastTotalVotes` sums — so `sum <= total` holds by construction and the `>` fallback is defence-in-depth against a future basis divergence, not load-bearing:

```solidity
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

        // Terminal BEFORE the external call; with zero custody a missed rule
        // is bookkeeping, not stranded funds (review E1, made structural).
        c.verdict = verdict;
        c.finalizedAt = block.timestamp;
        c.phase = ITokenCourt.Phase.Resolved;
        emit CaseFinalized(caseId, verdict, guiltyVotes, notGuiltyVotes, floor);

        try IChallengeGame(challengeGame).rule(c.challengeId, verdict) {}
        catch {
            emit ChallengeAlreadyTerminal(caseId, c.challengeId);
        }
    }

    function _participationFloor(uint256 snapshotTs, uint256 accusedWeight) internal view returns (uint256) {
        uint256 total = IStakedWood(stakedWood).getPastTotalVotes(snapshotTs);
        uint256 base = total > accusedWeight ? total - accusedWeight : total;
        return participationFloorBps * base / BPS_DENOMINATOR;
    }
```

- [ ] **Step 7.4: Run TokenCourt suite + full suite + commit**

```bash
forge test --match-contract TokenCourtTest -q | tail -3 && forge test --no-match-path 'test/fork/**' -q | tail -3
git add -A && git commit -m "feat(court): finalize - floor, fail-safe verdicts, terminal-race catch (spec §3)"
```

---

### Task 8: Auto-referral from `dispute`

**Files:**
- Modify: `src/ChallengeGame.sol` (dispute's `complete` branch — locate with `grep -n "ChallengeDisputed(challengeId" src/ChallengeGame.sol`), `src/interfaces/IChallengeGame.sol` (event)
- Test: `test/ChallengeGame.t.sol`

- [ ] **Step 8.1: Failing tests** (mocks at file scope; fixtures — reuse the file's existing filing/pool-completion helpers, matching exact names before writing):

```solidity
contract MockRevertingCourt {
    function refer(uint256) external pure returns (uint256) {
        revert("nope");
    }
}

contract MockRecordingCourt {
    uint256 public lastReferred;

    function refer(uint256 challengeId) external returns (uint256) {
        lastReferred = challengeId;
        return 1;
    }
}
```

```solidity
    function test_dispute_autoRefersOnCompletion() public {
        MockRecordingCourt rec = new MockRecordingCourt();
        vm.prank(owner);
        game.setCourt(address(rec));
        uint256 id = _filedChallenge();
        _completePool(id); // accused contributes up to bondWood
        assertEq(rec.lastReferred(), id, "auto-referred on the completing contribution");
    }

    function test_dispute_courtRevertDoesNotBrickDispute() public {
        MockRevertingCourt rev = new MockRevertingCourt();
        vm.prank(owner);
        game.setCourt(address(rev));
        uint256 id = _filedChallenge();
        vm.expectEmit(true, false, false, false);
        emit IChallengeGame.AutoReferFailed(id);
        _completePool(id); // must NOT revert
        assertEq(uint256(game.challengeOf(id).status), uint256(IChallengeGame.Status.Disputed));
    }

    function test_dispute_noCourtSkipsAutoRefer() public {
        // court == address(0): D5 world, dispute completes silently.
        uint256 id = _filedChallenge();
        _completePool(id);
        assertEq(uint256(game.challengeOf(id).status), uint256(IChallengeGame.Status.Disputed));
    }
```

- [ ] **Step 8.2: Run, expect failure** (event undefined / no auto-refer behaviour)

- [ ] **Step 8.3: Implement.** Interface event:

```solidity
    /// @notice Best-effort auto-referral failed; manual `TokenCourt.refer`
    ///         remains available (spec §3). A reverting court cannot brick a
    ///         dispute - same doctrine as AdapterDemotionFailed (F11).
    event AutoReferFailed(uint256 indexed challengeId);
```

Game — in `dispute`, after the existing transfer + events (LAST statements of the function, preserving CEI), plus `import {ITokenCourt} from "./interfaces/ITokenCourt.sol";`:

```solidity
        if (complete) {
            address courtAddr = court;
            if (courtAddr != address(0)) {
                try ITokenCourt(courtAddr).refer(challengeId) {}
                catch {
                    emit AutoReferFailed(challengeId);
                }
            }
        }
```

- [ ] **Step 8.4: Run + full suite + commit**

```bash
forge test --match-test 'test_dispute_autoRefers|test_dispute_courtRevert|test_dispute_noCourt' -q | tail -3
forge test --no-match-path 'test/fork/**' -q | tail -3
git add -A && git commit -m "feat(game): best-effort auto-referral on dispute completion (spec §3)"
```

---

### Task 9: End-to-end arcs

**Files:**
- Create: `test/TokenCourtEndToEnd.t.sol`

- [ ] **Step 9.1: Write the E2E suite** on the REAL stack, copying `test/ChallengeEndToEnd.t.sol`'s `setUp` wiring (real `StakedWood`, `ExposureLedger`, `ChallengeGame`) and adding a real `TokenCourt` + `game.setCourt(address(court))` + `court.setChallengeGame/setStakedWood`. Four arcs, each one test:

1. `test_arc_guiltyVerdict_slashesAndPaysChallenger` — file → dispute completes (assert auto-refer: `court.caseOfChallenge(id) != 0`) → voters vote guilty past the floor → warp past window → `finalize` → assert: challenge `Settled`, accused slashed (sWOOD stake delta), challenger repaid bond + pool, adapter demoted.
2. `test_arc_notGuilty_forfeitsToDefenders` — same until the vote → majority not-guilty → assert challenge `Failed`; each contributor's `claimContribution` yields stake + forfeit share (pull, per #50); challenger bond gone (burn slice + distribution).
3. `test_arc_inconclusive_unwindsAndAllowsRefiling` — dust turnout below floor → assert challenge `Inconclusive`, challenger whole, contributors claim exactly their stakes, coverage unfrozen, then a fresh `file()` on the same proposal succeeds.
4. `test_arc_timeoutRace_bothOrderings` — (a) finalize first, then `game.resolve(id)` reverts `WrongStatus` (ruling beat the clock); (b) refer at the last legal instant (`filedAt + disputeTimeout - voteWindow - FINALIZE_BUFFER`, arithmetic as in `test_refer_clockCheckBoundary`), vote, warp to exactly `filedAt + disputeTimeout`, call `game.resolve(id)` (→ `_fail`), then `finalize` — expect `ChallengeAlreadyTerminal` and case `Resolved` (clock beat the ruling, court closes clean).

Every arc ends with:

```solidity
        assertEq(wood.balanceOf(address(court)), 0, "court custody is zero, always");
```

- [ ] **Step 9.2: Run until green; commit**

```bash
forge test --match-contract TokenCourtEndToEnd -q | tail -3
git add -A && git commit -m "test(court): end-to-end arcs - guilty, not-guilty, inconclusive, timeout race"
```

---

### Task 10: Deploy script + preflight

**Files:**
- Create: `script/DeployTokenCourt.s.sol`
- Create: `test/deploy/DeployTokenCourtPreflight.t.sol`

- [ ] **Step 10.1: Script.** Model on the deleted `DeployPlanE.s.sol` (recover with `git show 'HEAD@{1}':script/DeployPlanE.s.sol` or from the Task-1 commit's parent) for the env-var + console + `vm.startBroadcast` pattern. Two contracts:

- `DeployTokenCourt`: deploys `TokenCourt(msg.sender)`, wires `setChallengeGame(CHALLENGE_GAME)` + `setStakedWood(STAKED_WOOD)`, then `transferOwnership(PROTOCOL_OWNER)` (Ownable2Step: console-log the required `acceptOwnership`).
- `WireTokenCourt`: pre-flights below, then `game.setCourt(COURT)`.

Pre-flights (each a `require` with a `PRE-FLIGHT:` message):

1. `court.challengeGame() == CHALLENGE_GAME && court.stakedWood() == STAKED_WOOD`.
2. `game.stakedWood() == STAKED_WOOD` — sWOOD identity on both contracts.
3. `court.voteWindow() + court.FINALIZE_BUFFER() <= game.disputeTimeout() - game.autoSlashDelay()` (spec §5: worst-case dispute completes at the end of `autoSlashDelay`; a vote must still fit).
4. `court.participationFloorBps() < swood.ageFloorBps()` (spec §5 launch math), and console-log the implied raw-turnout requirement: `participationFloorBps * 10_000 / ageFloorBps` bps of raw stake.
5. Plan D wiring intact: `ledger.coverageFreezer() == CHALLENGE_GAME`, `tiers.authorizedDemoter() == CHALLENGE_GAME`, `swood.authorizedSlasher() == CHALLENGE_GAME`.

`MANUAL NEXT` console lines: referral is automatic on dispute completion with permissionless `refer` as fallback; off-chain voter incentives are an operational commitment (spec §1); accept court ownership.

- [ ] **Step 10.2: Preflight tests.** Model on the deleted `DeployPlanEPreflight.t.sol` harness (`_runWireExpecting` + script-caller pattern — recover via `git show` as above). One test per pre-flight proving it bites (misconfigure, expect the `PRE-FLIGHT:` revert string), plus one boundary-accept test for check 3 (`==` passes and wires).

- [ ] **Step 10.3: Run + commit**

```bash
forge test --match-contract DeployTokenCourtPreflight -q | tail -3
git add -A && git commit -m "feat(deploy): TokenCourt deploy + wire scripts with launch-math preflights (spec §5)"
```

---

### Task 11: Gates, PR, close #26

- [ ] **Step 11.1: Full gates**

```bash
forge test --no-match-path 'test/fork/**' -q | tail -3   # expect: only fork tests failing
forge fmt --check src test script                         # CI-matching forge (guardrail: fmt version differs across forges)
./script/check-layout-goldens.sh                          # expect: no-op, nothing upgradeable changed
```

- [ ] **Step 11.2: Reference sweep**

```bash
grep -rn "ICourt\b\|panelBond\|badFaith\|panelRule\|finalizeAppeal\|finalizeUnappealed" src script test --include='*.sol' | head
```
Expected: zero hits. (Hits in `docs/superpowers/plans/2026-07-25-*` are historical — leave them.)

- [ ] **Step 11.3: Push + PR**

```bash
git push -u origin feat/token-court
gh pr create --base integration/lifecycle-planb --title "feat(court): TokenCourt - single-layer WOOD-vote adjudication (spec 2026-07-28)" \
  --body "Implements docs/superpowers/specs/2026-07-28-token-court-design.md. Replaces #26's two-layer court: panel, appeal bonds and bad-faith track deleted; Verdict.Inconclusive refund path, auto-referral, filings pause added. Net ~-3,500 lines vs #26."
```

- [ ] **Step 11.4: Close #26 with pointer** (do NOT delete branch `e` — it is this branch's base ancestry)

```bash
gh pr close 26 --repo sherwoodagent/sherwood-protocol \
  --comment "Superseded by the token-court redesign (decision 2026-07-28): docs/superpowers/specs/2026-07-28-token-court-design.md - single-layer WOOD vote; the panel, appeal bonds and bad-faith track are removed. Replacement PR: feat/token-court."
```

---

## Self-review (performed at write time; issues fixed inline)

- **Spec coverage:** §2 deletions → Task 1; §3 refer/vote/finalize/setters/no-court-pause → Tasks 4–7; §4 Verdict/`_refundAll`/pause/auto-refer → Tasks 2, 3, 8; §5 launch math → Task 10 checks 3–4; §6 test matrix → Tasks 2–10 (each named test maps to a spec bullet); §7 migration → Tasks 0, 11.
- **Known unknowns are named, not guessed:** exact fixture-helper names in `ChallengeGame.t.sol` (Steps 2.1, 3.1, 8.1), `ISyndicateGovernor.getProposal` struct shape + recoverable governor mock (Step 4.2), `MockStakedWood` setter names (Step 5.1) — each step states the exact file or git command to recover them.
- **Type consistency:** `Verdict` lives in `IChallengeGame`, referenced as `IChallengeGame.Verdict` everywhere; `Phase`/`Ruling`/`Case` live in `ITokenCourt`; `rule(uint256, Verdict)` identical in Tasks 2, 7, 8; error selectors match across the local-copy phase because signatures are identical.
