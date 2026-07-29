# Court Incentives Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make filing a challenge profitable, make voters provably current holders, make the `Inconclusive` fallback real, and fix the four defects the PR #52 adversarial review found — per `docs/superpowers/specs/2026-07-29-court-incentives-design.md`.

**Architecture:** A conviction bounty paid by `StakedWood` at slash time (new calldata params on `slashToEscrow`, no new storage there); a one-line present-holdings gate in `TokenCourt.vote`; a per-`reviewKey` re-challenge deadline in `ChallengeGame`; and four targeted defect fixes (case-key namespacing, `NotCourt` bubbling, cross-contract setter guards, spec corrections).

**Tech Stack:** Solidity 0.8.28, Foundry (`via_ir`, `optimizer_runs = 50`), OpenZeppelin, UUPS-upgradeable `StakedWood` with storage-layout goldens.

**Baseline at HEAD `57559b1`:** full suite 1747 passed / 21 pre-existing fork failures. TokenCourt 28, TokenCourtEndToEnd 5, ChallengeGame 92, preflight 12.

**PROCESS RULES (hard — several agents stranded themselves on these in the previous plan):**
- ALL forge commands FOREGROUND with a generous timeout. NEVER background a run and stop to wait; nothing will resume you.
- Run only the suites a task touches while iterating. The controller gates the full suite.
- After any change to `src/StakedWood.sol`, run `./script/check-layout-goldens.sh` — it must stay OK.
- `vm.prank` is consumed by calls in ARGUMENT position — hoist reads into locals first.
- Use `vm.getBlockTimestamp()`, never a cached `block.timestamp` across `vm.warp`. Warp forward only.
- A test that does not FAIL under the corresponding mutation does not count. Where a task says "mutation-verify", actually apply the mutation, watch the test fail, restore from a backup copy, and confirm the tree is byte-identical.

---

### Task 1: `slashToEscrow` pays a conviction bounty

**Files:**
- Modify: `src/interfaces/IStakedWood.sol` (the `slashToEscrow` declaration)
- Modify: `src/StakedWood.sol` (`slashToEscrow` ~line 1290, the `openCase` block ~1412)
- Modify: `test/mocks/MockStakedWood.sol` (signature must match)
- Test: `test/StakedWoodSlashToEscrow.t.sol` (grep to confirm it exists; if absent use `test/StakedWood.t.sol`)

**Why calldata, not storage:** the bounty rate and recipient arrive as arguments, so `StakedWood` gains NO state variable and the layout goldens are untouched. This is a plain UUPS upgrade, not a migration.

- [ ] **Step 1.1: Write the failing tests**

```solidity
    function test_slashToEscrow_paysBountyAndNetsTheEscrowCase() public {
        address challenger = makeAddr("challenger");
        uint256 before = wood.balanceOf(challenger);

        (uint256 total, uint256 caseId) = _slashWithBounty(challenger, 500);

        uint256 expectedBounty = total * 500 / 10_000;
        assertGt(expectedBounty, 0, "fixture must produce a non-trivial bounty");
        assertEq(wood.balanceOf(challenger) - before, expectedBounty, "challenger paid the bounty");
        // The escrow case is opened NET of the bounty - no accounting fiction.
        assertEq(escrow.caseProceeds(caseId), total - expectedBounty, "case proceeds are net");
    }

    function test_slashToEscrow_zeroBpsPaysNothing() public {
        address challenger = makeAddr("challenger");
        uint256 before = wood.balanceOf(challenger);
        (uint256 total, uint256 caseId) = _slashWithBounty(challenger, 0);
        assertEq(wood.balanceOf(challenger), before, "no bounty at 0 bps");
        assertEq(escrow.caseProceeds(caseId), total, "full proceeds to the escrow");
    }

    function test_slashToEscrow_zeroRecipientPaysNothing() public {
        // A caller passing address(0) gets no bounty and the escrow keeps the
        // whole slash - never a transfer to the zero address, which OZ's ERC20
        // would revert on anyway.
        (uint256 total, uint256 caseId) = _slashWithBounty(address(0), 500);
        assertEq(escrow.caseProceeds(caseId), total, "full proceeds when no recipient");
    }
```

Write `_slashWithBounty(address bountyTo, uint256 bountyBps)` mirroring the file's existing slash fixture, forwarding the two new args. Read that fixture first and reuse its setup verbatim — do not invent a second one. `total` here is the value the function RETURNS; if the implementation nets the return value, adjust the expectation and say so in your report. If the escrow mock has no `caseProceeds` getter, read the case struct the way the file's existing assertions do.

- [ ] **Step 1.2: Run to verify failure**

Run: `forge test --match-test test_slashToEscrow_ -q 2>&1 | tail -5`
Expected: compilation failure — `slashToEscrow` does not take those arguments.

- [ ] **Step 1.3: Change the interface**

In `src/interfaces/IStakedWood.sol`, replace the `slashToEscrow` declaration:

```solidity
    /// @notice Execute a verdict slash and route the proceeds to the escrow,
    ///         paying `bountyTo` a `bountyBps` slice of the recovered WOOD
    ///         first.
    /// @dev    THE BOUNTY IS THE PROSECUTOR'S FEE (spec 2026-07-29 §2). It is
    ///         paid only when a slash actually recovers WOOD, so it can never
    ///         fund a filing that recovered nothing, and it is deducted BEFORE
    ///         `openCase` so the escrow's `proceeds` equal what claimants can
    ///         really redeem. `bountyTo == address(0)` or `bountyBps == 0`
    ///         disables it and the escrow receives the whole slash.
    /// @param  bountyTo   Recipient of the conviction bounty, or `address(0)`.
    /// @param  bountyBps  Slice of the recovered total, in bps.
    function slashToEscrow(
        bytes32 caseKey,
        uint256 openedAt,
        address[] calldata approvers,
        uint256[] calldata slashBpsPer,
        address vault,
        uint256 snapshotTimestamp,
        address bountyTo,
        uint256 bountyBps
    ) external returns (uint256 total, uint256 caseId);
```

- [ ] **Step 1.4: Implement in `StakedWood`**

Add the two parameters, then insert the payout immediately before the `forceApprove`/`openCase` block. The existing `if (total == 0) return (0, 0);` early exit must stay ahead of it.

```solidity
        // THE BOUNTY COMES OFF THE TOP, BEFORE THE ESCROW SEES THE MONEY
        // (spec 2026-07-29 §2). Paying the prosecutor out of what the
        // prosecution recovered is what makes filing rational: a correct but
        // unanswered challenge currently LOSES `settleBurnBps` of its bond, so
        // nobody outside the drained vault has a reason to watch. Deducting
        // here rather than inside the escrow keeps `proceeds` honest - the
        // number a claimant redeems against is the number actually present -
        // and keeps a non-victim payout out of the contract whose only job is
        // victim compensation.
        uint256 bounty;
        if (bountyTo != address(0) && bountyBps != 0) {
            bounty = total * bountyBps / BPS_DENOMINATOR;
            if (bounty != 0) {
                total -= bounty;
                IERC20(wood).safeTransfer(bountyTo, bounty);
                emit ConvictionBountyPaid(caseKey, bountyTo, bounty);
            }
        }
```

Declare the event in `IStakedWood`:

```solidity
    /// @notice A conviction bounty was paid out of a verdict slash before the
    ///         remainder opened a compensation case (spec 2026-07-29 §2).
    event ConvictionBountyPaid(bytes32 indexed caseKey, address indexed bountyTo, uint256 amount);
```

Confirm `BPS_DENOMINATOR` exists in `StakedWood` (grep); if not, use the literal `10_000` as neighbouring code does.

**Ordering is load-bearing.** `total` is decremented BEFORE `forceApprove(escrow, total)` and `openCase(..., total)`, so both see the net figure. The burn-fallback `catch` also burns the net `total` — correct, because the bounty has already left and burning it twice would under-account. Add a comment saying exactly that at the `_burnWood(total)` line.

- [ ] **Step 1.5: Update the mock**

`test/mocks/MockStakedWood.sol` must match the new signature or every suite using it fails to compile. Mirror the real behaviour minimally (record the bounty, net the total).

- [ ] **Step 1.6: Run tests, layout goldens, commit**

```bash
forge test --match-test test_slashToEscrow_ -q | tail -3
./script/check-layout-goldens.sh | tail -2      # MUST still be OK - no new storage
forge build --quiet && echo BUILD OK
git add -A && git commit -m "feat(swood): conviction bounty paid off the top of a verdict slash (spec 2026-07-29 §2)"
```

---

### Task 2: `ChallengeGame` pins and passes the bounty rate

**Files:**
- Modify: `src/interfaces/IChallengeGame.sol` (getter, setter, event, `Challenge` struct field)
- Modify: `src/ChallengeGame.sol` (state var, `file` pin ~line 565, `_settle` call site ~1069, setter)
- Test: `test/ChallengeGame.t.sol`

- [ ] **Step 2.1: Write the failing tests**

```solidity
    function test_convictionBounty_paidOnTheSilencePath() public {
        uint256 id = _fileStandard(PROPOSAL);
        uint256 before = wood.balanceOf(challenger);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        game.resolve(id);

        IChallengeGame.Challenge memory c = game.challengeOf(id);
        uint256 slashed = _slashedFrom(id); // see note below
        uint256 expected = slashed * 500 / 10_000;
        assertGt(expected, 0, "fixture must recover real WOOD");
        uint256 burn = c.bondWood * c.settleBurnBpsAtFiling / 10_000;
        assertEq(
            wood.balanceOf(challenger) - before,
            c.bondWood - burn + expected,
            "bounty on top of the returned bond"
        );
    }

    function test_convictionBounty_paidOnTheGuiltyRuling() public {
        uint256 id = _fileAndDispute();
        uint256 before = wood.balanceOf(challenger);
        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Guilty);
        IChallengeGame.Challenge memory c = game.challengeOf(id);
        assertGt(
            wood.balanceOf(challenger) - before,
            c.bondWood + c.counterBondWood,
            "escalated pays bond + pool, PLUS the bounty"
        );
    }

    function test_convictionBounty_notPaidOnFailOrInconclusive() public {
        uint256 a = _fileAndDispute();
        uint256 beforeA = wood.balanceOf(challenger);
        vm.prank(court);
        game.rule(a, IChallengeGame.Verdict.NotGuilty);
        assertEq(wood.balanceOf(challenger), beforeA, "no bounty on _fail");

        uint256 b = _fileAndDisputeSecondProposal(); // adapt to the file's real fixture
        uint256 beforeB = wood.balanceOf(challenger);
        vm.prank(court);
        game.rule(b, IChallengeGame.Verdict.Inconclusive);
        IChallengeGame.Challenge memory cb = game.challengeOf(b);
        assertEq(wood.balanceOf(challenger) - beforeB, cb.bondWood, "bond whole, no bounty on _refundAll");
    }

    function test_convictionBounty_pinnedAtFiling() public {
        uint256 id = _fileStandard(PROPOSAL);
        vm.prank(owner);
        game.setConvictionBountyBps(2_000); // raise AFTER filing
        uint256 before = wood.balanceOf(challenger);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        game.resolve(id);
        IChallengeGame.Challenge memory c = game.challengeOf(id);
        assertEq(c.convictionBountyBpsAtFiling, 500, "the challenge keeps the rate it was filed under");
        uint256 burn = c.bondWood * c.settleBurnBpsAtFiling / 10_000;
        uint256 atOld = _slashedFrom(id) * 500 / 10_000;
        assertEq(wood.balanceOf(challenger) - before, c.bondWood - burn + atOld, "paid at the pinned rate");
    }

    function test_setConvictionBountyBps_boundsAndOwner() public {
        vm.prank(owner);
        vm.expectRevert(IChallengeGame.InvalidParameter.selector);
        game.setConvictionBountyBps(2_001);
        vm.prank(challenger);
        vm.expectRevert();
        game.setConvictionBountyBps(100);
        vm.prank(owner);
        game.setConvictionBountyBps(0); // zero is legal - bounty off
        assertEq(game.convictionBountyBps(), 0);
    }
```

`_slashedFrom(uint256 id)`: the `Challenge` struct may not carry the slashed amount. Check first. If it does not, do NOT add a field — write the helper to read the escrow case opened by that settle, or capture `ChallengeSettled(challengeId, slashedWood, caseId)` with `vm.recordLogs`. The file already asserts on slash amounts somewhere; find that pattern and reuse it.

- [ ] **Step 2.2: Run to verify failure** — `forge test --match-test 'test_convictionBounty|test_setConvictionBountyBps' -q 2>&1 | tail -5`. Expected: compile failure.

- [ ] **Step 2.3: Interface**

```solidity
    /// @notice Slice of a verdict slash paid to the challenger that caused it
    ///         (spec 2026-07-29 §2). Pinned per challenge at filing.
    /// @dev    PAID ONLY AT TERMINAL RESOLUTION, never while a dispute is open:
    ///         `_settle` is the sole payer, and it is reached only by the
    ///         silence timeout or a `Guilty` ruling - both of which write the
    ///         terminal status in the same transaction. A `NotGuilty` ruling,
    ///         an `Inconclusive` unwind, and the dispute timeout all pay zero.
    function convictionBountyBps() external view returns (uint256);
    function setConvictionBountyBps(uint256 newBps) external;
    event ConvictionBountyBpsSet(uint256 oldBps, uint256 newBps);
```

Append `uint256 convictionBountyBpsAtFiling;` to the `Challenge` struct (append-only, after the existing pinned rates) and document it beside its siblings.

- [ ] **Step 2.4: Implement**

State + setter, mirroring `setSettleBurnBps`'s shape exactly (read it first):

```solidity
    uint256 public constant MAX_CONVICTION_BOUNTY_BPS = 2_000;
    uint256 public convictionBountyBps = 500;

    function setConvictionBountyBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_CONVICTION_BOUNTY_BPS) revert InvalidParameter();
        emit ConvictionBountyBpsSet(convictionBountyBps, newBps);
        convictionBountyBps = newBps;
    }
```

Zero is legal (bounty off) — do not reject it. In `file`, pin it alongside the other rates: `convictionBountyBpsAtFiling: convictionBountyBps,`.

In `_settle`, forward it:

```solidity
            (slashedWood, caseId) = swood.slashToEscrow(
                key,
                c.executedAt,
                approvers,
                slashBpsPer,
                c.vault,
                c.executedAt - 1,
                c.challenger,
                c.convictionBountyBpsAtFiling
            );
```

This sits inside the `else` branch of `if (_convicted[key])`, so a second challenge against an already-convicted proposal collects nothing — asserted next.

- [ ] **Step 2.5: Add the double-pay guard test**

```solidity
    function test_convictionBounty_notPaidTwiceOnAConcurrentChallenge() public {
        (uint256 first, uint256 second) = _twoConcurrentChallenges(); // adapt to the file's real fixture
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        game.resolve(first);
        uint256 afterFirst = wood.balanceOf(challenger2);
        game.resolve(second); // hits the _convicted short-circuit
        IChallengeGame.Challenge memory c = game.challengeOf(second);
        uint256 burn = c.bondWood * c.settleBurnBpsAtFiling / 10_000;
        assertEq(
            wood.balanceOf(challenger2) - afterFirst,
            c.bondWood - burn,
            "the second challenger gets its bond back, never a second bounty"
        );
    }
```

- [ ] **Step 2.6: Run + commit**

```bash
forge test --match-path test/ChallengeGame.t.sol | tail -3
forge fmt src test
git add -A && git commit -m "feat(game): conviction bounty pinned at filing, paid only at terminal resolution (spec §2)"
```

---

### Task 3: Present-holdings gate on voting (defect B4)

**Files:**
- Modify: `src/TokenCourt.sol` (`vote`, ~line 258)
- Modify: `test/mocks/MockStakedWood.sol` (add `getVotes`/`setVotes` if absent)
- Test: `test/TokenCourt.t.sol`

- [ ] **Step 3.1: Failing tests**

```solidity
    function test_vote_refusesAFullyExitedHolder() public {
        uint256 id = _referredCase();
        uint256 snap = court.caseOf(id).snapshotTs;
        address exited = makeAddr("exited");
        swood.setPastVotes(exited, snap, 400e18); // historic weight survives the exit
        swood.setVotes(exited, 0);                // present holdings: none
        vm.prank(exited);
        vm.expectRevert(ITokenCourt.NoVotingPower.selector);
        court.vote(id, false);
    }

    function test_vote_acceptsACurrentHolderWithHistoricWeight() public {
        uint256 id = _referredCase();
        swood.setVotes(voterA, 1); // any present stake at all
        vm.prank(voterA);
        court.vote(id, true);
        assertEq(
            court.caseOf(id).guiltyVotes,
            300e18,
            "weight is still the SNAPSHOT figure, not the present one"
        );
    }

    function test_vote_refusesPresentHolderWithNoSnapshotWeight() public {
        uint256 id = _referredCase();
        address latecomer = makeAddr("latecomer");
        swood.setVotes(latecomer, 5_000e18); // bought in after the drain
        vm.prank(latecomer);
        vm.expectRevert(ITokenCourt.NoVotingPower.selector);
        court.vote(id, true);
    }
```

`MockStakedWood` needs `setVotes(address,uint256)` and `getVotes(address)`. Check with `grep -n "getVotes" test/mocks/MockStakedWood.sol`. **Its default must be non-zero for addresses that already have snapshot weight**, or the existing 28 tests break — read how the mock defaults `getPastVotes` and mirror that shape.

- [ ] **Step 3.2: Run to verify failure** — the exited-holder test must FAIL (it currently votes successfully).

- [ ] **Step 3.3: Implement**

```solidity
        uint256 weight = IStakedWood(stakedWood).getPastVotes(msg.sender, c.snapshotTs);
        if (weight == 0) revert NoVotingPower();
        // PRESENT HOLDINGS ARE A GATE, NEVER A WEIGHT (spec 2026-07-29 §3).
        // Historical weight still decides how much a vote counts - that is the
        // D2 flash-loan defence and it is unchanged. This decides only WHETHER
        // you may vote, and it exists because `claimUnstakeGuardian` deletes
        // the guardian record: `stakedAt` becomes 0, `_ageFactorBps` floors at
        // `ageFloorBps`, and the raw checkpoint at `snapshotTs` survives the
        // exit. Without this line an attacker pre-positions stake, executes the
        // drain, requests unstake, votes to acquit at 25% of historic weight,
        // and claims out - voting capital liquid before the verdict lands, and
        // alignment exactly zero for the party most motivated to vote.
        // Re-WEIGHTING on present holdings would reintroduce the post-hoc
        // accumulation the snapshot exists to close, so this stays binary.
        if (IStakedWood(stakedWood).getVotes(msg.sender) == 0) revert NoVotingPower();
```

- [ ] **Step 3.4: Mutation-verify, run, commit**

Copy `src/TokenCourt.sol` to a backup outside the repo, delete the new line, confirm `test_vote_refusesAFullyExitedHolder` FAILS, restore, confirm `git diff src/TokenCourt.sol` shows only the intended change.

```bash
forge test --match-contract TokenCourtTest | tail -3
git add -A && git commit -m "fix(court): voting requires present holdings, not just historic weight (B4, spec §3)"
```

---

### Task 4: Re-challenge window extension (finding M3)

**Files:**
- Modify: `src/interfaces/IChallengeGame.sol` (getter), `src/ChallengeGame.sol` (`file` gate ~line 483, `_refundAll`)
- Test: `test/ChallengeGame.t.sol`

- [ ] **Step 4.1: Failing test**

```solidity
    function test_inconclusive_extendsTheRechallengeWindow() public {
        // Today: file at day 3, accused stalls the pool to the last legal
        // instant, finalize -> Inconclusive lands past `executedAt + 14 days`,
        // so no re-filing is possible and the acquittal is permanent.
        uint256 id = _fileStandardAt(PROPOSAL, 3 days); // adapt: file 3 days after execution
        _completePoolAt(id, 7 days - 1);                // accused stalls
        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Inconclusive);

        bytes32 key = keccak256(abi.encode(address(gov), PROPOSAL)); // match _reviewKey exactly
        assertGt(game.challengeableUntil(key), vm.getBlockTimestamp(), "window was extended");

        vm.warp(vm.getBlockTimestamp() + 5 days); // well past executedAt + 14 days
        uint256 refiled = _fileStandard(PROPOSAL); // MUST NOT revert WindowClosed
        assertGt(refiled, 0, "the proposal is genuinely re-challengeable");
    }

    function test_challengeableUntil_onlyEverLengthens() public {
        uint256 id = _fileStandard(PROPOSAL);
        _completePool(id);
        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Inconclusive);
        bytes32 key = keccak256(abi.encode(address(gov), PROPOSAL));
        uint256 first = game.challengeableUntil(key);

        uint256 again = _fileStandard(PROPOSAL);
        _completePool(again);
        vm.prank(court);
        game.rule(again, IChallengeGame.Verdict.Inconclusive);
        assertGe(game.challengeableUntil(key), first, "never shortens");
    }
```

Read `_reviewKey` at `src/ChallengeGame.sol:438` first and copy its exact hashing so the test key matches. If the game exposes a public key helper, use that instead.

- [ ] **Step 4.2: Run to verify failure** — expect `WindowClosed` on the re-file.

- [ ] **Step 4.3: Implement**

```solidity
    /// @notice Per-proposal deadline for NEW filings, extended whenever a
    ///         challenge unwinds inconclusively (spec 2026-07-29 §5).
    /// @dev    WITHOUT THIS, `Inconclusive` IS A PERMANENT ACQUITTAL. Reaching
    ///         it takes at least `autoSlashDelay + voteWindow` = 12 days at the
    ///         defaults, and THE ACCUSED CHOOSES when the pool completes - so a
    ///         challenge filed more than 2 days after execution could never be
    ///         re-filed, and stalling converted "the electorate did not turn
    ///         out" into "the accused wins, finally". Extending on the unwind
    ///         makes the stall buy a delay instead of an acquittal. Zero means
    ///         never inconclusive: fall back to `executedAt + challengeWindow`.
    mapping(bytes32 reviewKey => uint256) public challengeableUntil;
```

In `file`, replace the gate:

```solidity
        bytes32 key = _reviewKey(governor, proposalId);
        uint256 deadline = challengeableUntil[key];
        if (deadline == 0) deadline = executedAt + challengeWindow;
        if (block.timestamp > deadline) revert WindowClosed();
```

If `file` already computes `_reviewKey` further down, hoist that computation rather than computing it twice.

In `_refundAll`, after the freeze release:

```solidity
        // Extend, never shorten - two inconclusive rounds must not let the
        // second pull the deadline back in.
        bytes32 rk = _reviewKey(governor, proposalId);
        uint256 extended = block.timestamp + challengeWindow;
        if (extended > challengeableUntil[rk]) challengeableUntil[rk] = extended;
```

- [ ] **Step 4.4: Run + commit**

```bash
forge test --match-path test/ChallengeGame.t.sol | tail -3
git add -A && git commit -m "fix(game): Inconclusive extends the re-challenge window (M3, spec §5)"
```

---

### Task 5: Namespace the case registry by game (defect B1)

**Files:** `src/TokenCourt.sol`, `src/interfaces/ITokenCourt.sol`, `test/TokenCourt.t.sol`

**The defect:** `caseOfChallenge` is keyed by challenge id alone. `ChallengeGame` is non-upgradeable, so redeploying it IS the upgrade path and `setChallengeGame` exists to serve it — but a new game's ids restart at 1, colliding with every id the old game minted. Colliding challenges revert `AlreadyReferred` on both auto- and manual referral, forever, and time out to `_fail`. The `Case.game` pin closed the `finalize` half of this and left the `refer` half open.

- [ ] **Step 5.1: Failing test**

```solidity
    function test_refer_afterGameMigration_doesNotCollideOnChallengeId() public {
        _disputedChallenge();
        uint256 firstCase = court.refer(CHALLENGE_ID);
        assertEq(firstCase, 1);

        // Migrate to a second game; its ids restart from the same numbers.
        MockGameForCourt game2 = new MockGameForCourt();
        game2.setExposureLedger(address(ledger));
        vm.prank(owner);
        court.setChallengeGame(address(game2));
        game2.setChallenge(
            CHALLENGE_ID,
            governor,
            PROPOSAL_ID,
            IChallengeGame.Status.Disputed,
            vm.getBlockTimestamp(),
            30 days,
            vm.getBlockTimestamp() - 1 days
        );

        uint256 secondCase = court.refer(CHALLENGE_ID); // MUST NOT revert AlreadyReferred
        assertEq(secondCase, 2, "the new game's challenge gets its own case");
        assertEq(court.caseOfChallenge(address(game2), CHALLENGE_ID), secondCase);
        assertEq(court.caseOfChallenge(address(game), CHALLENGE_ID), firstCase, "the old mapping is intact");
    }
```

Match `setChallenge`'s real arity — Task 5 of the previous plan gave it an `executedAt` param; read the mock before writing.

- [ ] **Step 5.2: Run to verify failure** — expect `AlreadyReferred`.

- [ ] **Step 5.3: Implement**

```solidity
    /// @dev KEYED BY (GAME, CHALLENGE ID), not by id alone. `ChallengeGame` is
    ///      non-upgradeable, so redeploying it is the migration path and
    ///      `setChallengeGame` exists to serve it - but a fresh game's ids
    ///      restart at 1 and would collide with every case the old game already
    ///      minted, bricking referral for those ids permanently. Pinning
    ///      `Case.game` fixed `finalize`; this fixes `refer`.
    mapping(address game => mapping(uint256 challengeId => uint256 caseId)) public caseOfChallenge;
```

Update `refer`'s guard and write to `caseOfChallenge[game][challengeId]`, the interface declaration, and every call site. Grep for `caseOfChallenge` across `src`, `test`, and `script` and fix all of them.

- [ ] **Step 5.4: Run + commit**

```bash
forge test --match-contract TokenCourtTest | tail -3
forge test --match-path test/TokenCourtEndToEnd.t.sol | tail -3
git add -A && git commit -m "fix(court): namespace the case registry by game (B1)"
```

---

### Task 6: Bubble `NotCourt` instead of swallowing it (defect B2)

**Files:** `src/TokenCourt.sol` (`finalize`'s catch), `src/interfaces/ITokenCourt.sol` (event natspec), `test/TokenCourt.t.sol`

**The defect:** the filter swallows `WrongStatus` AND `NotCourt`. `WrongStatus` genuinely means terminal. `NotCourt` means `game.court != address(this)` while the challenge is **still `Disputed` and fully rulable** — so unwiring the court (a documented emergency lever) makes `finalize` close the case with a `Guilty` verdict recorded and undelivered. Re-wiring cannot redeliver (`AlreadyReferred`), and the timeout acquits. That is the verdict-burning primitive the filter was written to close.

- [ ] **Step 6.1: Failing test**

```solidity
    function test_finalize_notCourt_bubblesAndLeavesCaseVoting() public {
        uint256 id = _referredCase();
        vm.prank(voterA);
        court.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);

        game.setRuleRevertsNotCourt(true); // the game no longer recognises this court
        vm.expectRevert(IChallengeGame.NotCourt.selector);
        court.finalize(id);

        assertEq(uint256(court.caseOf(id).phase), uint256(ITokenCourt.Phase.Voting), "case stays retryable");
        assertFalse(game.ruled(), "nothing delivered");

        // Re-wire and the verdict lands for real.
        game.setRuleRevertsNotCourt(false);
        court.finalize(id);
        assertEq(uint256(game.lastVerdict()), uint256(IChallengeGame.Verdict.Guilty));
    }
```

There is an existing `test_finalize_notCourt_swallowed` — **delete it**; it pins the defect.

- [ ] **Step 6.2: Run to verify failure** — `finalize` currently succeeds and the case goes `Resolved`.

- [ ] **Step 6.3: Implement**

```solidity
        catch (bytes memory reason) {
            // SWALLOW ONLY `WrongStatus` - the one revert that genuinely means
            // "there is nothing left to rule" (the challenge went terminal
            // first: the E1 race). `NotCourt` does NOT mean that (B2): it means
            // the game was re-pointed away while the challenge is STILL
            // `Disputed` and fully rulable, so swallowing it closes the case
            // with a verdict recorded and undelivered, and re-wiring cannot
            // redeliver because `refer` reverts `AlreadyReferred`. That is the
            // verdict-burning primitive this filter exists to close, reached by
            // an owner action instead of a gas dial. It is transient and
            // retryable, so it bubbles with everything else.
            bytes4 sel = reason.length >= 4 ? bytes4(reason) : bytes4(0);
            if (sel != IChallengeGame.WrongStatus.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
            emit ChallengeAlreadyTerminal(caseId, c.challengeId);
        }
```

Update `ChallengeAlreadyTerminal`'s natspec in `ITokenCourt` to name one cause, not two.

- [ ] **Step 6.4: Run + commit**

```bash
forge test --match-contract TokenCourtTest | tail -3
git add -A && git commit -m "fix(court): bubble NotCourt - it is retryable, not terminal (B2)"
```

---

### Task 7: Cross-contract setter guards (defect B3)

**Files:** `src/ChallengeGame.sol` (`setAutoSlashDelay`, `setDisputeTimeout`), `src/TokenCourt.sol` (`setVoteWindow`), both interfaces, both test files

**The defect:** `autoSlashDelay + voteWindow + FINALIZE_BUFFER <= disputeTimeout` is enforced only by a deploy script. Three setters across two contracts can each break it afterwards with no on-chain signal, and once broken the accused defeats adjudication unilaterally by stalling the pool until `refer` can never fit.

- [ ] **Step 7.1: Failing tests**

```solidity
    // test/ChallengeGame.t.sol
    function test_setDisputeTimeout_refusesAValueTheCourtCannotFitIn() public {
        vm.prank(owner);
        vm.expectRevert(IChallengeGame.WindowInvariantViolated.selector);
        game.setDisputeTimeout(8 days); // 7 + 5 + 1 = 13 > 8
    }

    function test_setAutoSlashDelay_refusesAValueThatEatsTheReferralWindow() public {
        vm.prank(owner);
        vm.expectRevert(IChallengeGame.WindowInvariantViolated.selector);
        game.setAutoSlashDelay(25 days); // 25 + 5 + 1 = 31 > 30
    }

    function test_setters_unaffectedWhenNoCourtIsWired() public {
        vm.startPrank(owner);
        game.setCourt(address(0));
        game.setDisputeTimeout(8 days); // no court to fit: the invariant is vacuous
        vm.stopPrank();
        assertEq(game.disputeTimeout(), 8 days);
    }
```

```solidity
    // test/TokenCourt.t.sol
    function test_setVoteWindow_refusesAValueTheGameCannotFit() public {
        game.setDisputeTimeout(20 days);
        game.setAutoSlashDelay(7 days);
        vm.prank(owner);
        vm.expectRevert(ITokenCourt.WindowInvariantViolated.selector);
        court.setVoteWindow(14 days); // 7 + 14 + 1 = 22 > 20
    }
```

`MockGameForCourt` needs `autoSlashDelay()`, `disputeTimeout()`, and setters for both.

**Note:** the existing `test_setDisputeTimeout_*` / `test_setAutoSlashDelay_*` tests in `ChallengeGame.t.sol` may set values that now violate the invariant. Run the suite after implementing and fix any that break by choosing conforming values — do NOT weaken the new guard to accommodate them.

- [ ] **Step 7.2: Run to verify failure** — all three setters currently accept the values.

- [ ] **Step 7.3: Implement**

Add `error WindowInvariantViolated();` to both interfaces. In `ChallengeGame`, a shared private check:

```solidity
    /// @dev THE INVARIANT SPANS TWO CONTRACTS, so neither can hold it alone
    ///      (B3). A counter-bond pool may complete as late as
    ///      `filedAt + autoSlashDelay`, and from that instant a referral needs
    ///      `voteWindow + FINALIZE_BUFFER` of runway before the challenge dies
    ///      at `filedAt + disputeTimeout`. Violated, the referral window can be
    ///      NEGATIVE - and the ACCUSED chooses when the pool completes, so they
    ///      defeat adjudication unilaterally by stalling. The deploy pre-flight
    ///      catches the wiring-time case; this catches the three setters that
    ///      could each break it afterwards. Vacuous with no court wired: there
    ///      is no referral to fit.
    function _requireWindowFits(uint256 autoSlash, uint256 timeout) private view {
        address c = court;
        if (c == address(0)) return;
        if (autoSlash + ITokenCourt(c).voteWindow() + ITokenCourt(c).FINALIZE_BUFFER() > timeout) {
            revert WindowInvariantViolated();
        }
    }
```

Call it as the LAST check in both setters — `_requireWindowFits(newDelay, disputeTimeout)` and `_requireWindowFits(autoSlashDelay, newTimeout)` — after their existing bounds checks.

In `TokenCourt.setVoteWindow`, the mirror:

```solidity
        address g = challengeGame;
        if (g != address(0)) {
            IChallengeGame gg = IChallengeGame(g);
            if (gg.autoSlashDelay() + newWindow + FINALIZE_BUFFER > gg.disputeTimeout()) {
                revert WindowInvariantViolated();
            }
        }
```

`autoSlashDelay()` and `disputeTimeout()` must be declared in `IChallengeGame` — check and add if missing.

- [ ] **Step 7.4: Run + commit**

```bash
forge test --match-path test/ChallengeGame.t.sol | tail -3
forge test --match-contract TokenCourtTest | tail -3
git add -A && git commit -m "fix: enforce the cross-contract window invariant on all three setters (B3)"
```

---

### Task 8: Speculative-filing pre-flight bound

**Files:** `script/DeployTokenCourt.s.sol`, `test/deploy/DeployTokenCourtPreflight.t.sol`

Spec §2 requires the burn stay larger than the bounty on a baseless filing: a bogus unopposed filing against a well-covered guardian still produces a real slash, so it also collects a bounty.

- [ ] **Step 8.1: Do the arithmetic FIRST and report it**

Both rates are bps of different bases. The burn takes `settleBurnBps` of the BOND; the bounty pays `convictionBountyBps` of the SLASH. The bond is `challengerBondBps` of coverage, and the worst case for the attacker's profit is a slash equal to the full coverage. So expressed against the slash:

```
burn earns   = settleBurnBps * challengerBondBps / 10_000   bps of the slash
bounty pays  = convictionBountyBps                          bps of the slash
```

At the current defaults: `2_000 * 500 / 10_000 = 100` bps, against a proposed bounty of **500** bps.

**The proposed default therefore FAILS its own bound.** Do not silently change either number. Report this to the controller with the arithmetic and stop for a decision: lower `convictionBountyBps` below 100 bps, raise `settleBurnBps`, or re-derive the bound against a different base. Implement Steps 8.2–8.4 only once the controller answers.

- [ ] **Step 8.2: Failing test**

```solidity
    function test_wirePreflight_bites_whenTheBountyOutrunsTheBurn() public {
        vm.startPrank(DEFAULT_SENDER);
        game.setSettleBurnBps(100);          // 1% of the bond
        game.setConvictionBountyBps(2_000);  // 20% of the slash
        vm.stopPrank();
        _runWireExpecting("PRE-FLIGHT: convictionBountyBps makes speculative filing profitable");
    }
```

- [ ] **Step 8.3: Implement** — pre-flight 6 in `WireTokenCourt`, after the existing five:

```solidity
        // ── Pre-flight 6: a baseless filing must cost more than it earns ──
        // A bogus unopposed filing against a well-covered guardian produces a
        // REAL slash and therefore a real bounty. `settleBurnBps` is the only
        // price on that attack, so it must exceed what the bounty pays back.
        // The two are bps of different bases (bond vs slash), so the bound is
        // expressed against the slash: the burn earns
        // `settleBurnBps * challengerBondBps / 10_000` of it.
        uint256 burnOnSlash = game.settleBurnBps() * game.challengerBondBps() / 10_000;
        require(
            game.convictionBountyBps() < burnOnSlash,
            "PRE-FLIGHT: convictionBountyBps makes speculative filing profitable - it must stay "
            "below settleBurnBps * challengerBondBps / 10_000, or a baseless unopposed filing "
            "earns more from the bounty than the burn takes from its bond."
        );
        console.log("speculative-filing margin (bps of slash): %s", burnOnSlash - game.convictionBountyBps());
```

- [ ] **Step 8.4: Run + commit**

```bash
forge test --match-path test/deploy/DeployTokenCourtPreflight.t.sol | tail -3
git add -A && git commit -m "feat(deploy): pre-flight the speculative-filing bound (spec §2)"
```

---

### Task 9: Spec and natspec honesty pass

**Files:** `docs/superpowers/specs/2026-07-28-token-court-design.md`, `src/TokenCourt.sol`, `src/ChallengeGame.sol`

- [ ] **Step 9.1: Correct §1 of the 2026-07-28 spec**

Replace the "capture economics are better than UMA's, not worse" passage and its three bullet properties with the corrected framing from `2026-07-29-court-incentives-design.md` §6: property 2 ("voters hold no position in the outcome") is what makes them cheap to buy; property 1 (the snapshot) does not bind the accused, who is a pre-positioned whale by construction; property 3 (aged weight) had its inverse fixed in Task 3. State plainly that the optimistic layer is the mechanism and the court is a backstop against unsophisticated adversaries. Add a pointer to the 2026-07-29 spec.

- [ ] **Step 9.2: Correct `AccusedCannotVote`'s natspec (A1)**

In `src/TokenCourt.sol`: the bar covers the approving ADDRESS, not the party. Address splitting defeats it, and the floor's accused-subtraction makes the siblings' quorum *smaller* as the accused cohort grows. Say so; stop claiming it bars a defendant.

- [ ] **Step 9.3: Record A2 and A5**

Add a `@dev` on `finalize` noting the last-mover advantage (public tallies + hard deadline + tie-acquits means the acquitting side need only match, not exceed, in the final block), with the trigger from spec §6. Add a `@dev` on `vote` noting A5 (a mid-case top-up re-anchors `stakedAt` and silently drops the voter toward the age floor, so achievable turnout decays during the window).

- [ ] **Step 9.4: Commit**

```bash
forge fmt src
git add -A && git commit -m "docs: correct the capture-economics claim; record A1, A2, A5 where they live"
```

---

### Task 10: Gates, mutation battery, PR update

- [ ] **Step 10.1: Full gates**

```bash
forge test --no-match-path 'test/fork/**' 2>&1 | grep -E "tests succeeded|Encountered" | tail -2
forge fmt --check src test script
./script/check-layout-goldens.sh | tail -2
```
Expected: 1747 + your new tests; the same 21 fork failures; fmt clean; goldens OK.

- [ ] **Step 10.2: Mutation battery**

Apply each mutation, confirm the named test FAILS, restore from a backup copy outside the repo, confirm `git diff` is empty:

| Mutation | Must fail |
|---|---|
| `bounty` never deducted from `total` in `slashToEscrow` | `test_slashToEscrow_paysBountyAndNetsTheEscrowCase` |
| bounty read from live `convictionBountyBps` instead of the pin | `test_convictionBounty_pinnedAtFiling` |
| present-holdings check deleted | `test_vote_refusesAFullyExitedHolder` |
| `challengeableUntil` write removed from `_refundAll` | `test_inconclusive_extendsTheRechallengeWindow` |
| `caseOfChallenge` reverted to a single key | `test_refer_afterGameMigration_doesNotCollideOnChallengeId` |
| `NotCourt` re-added to the selector filter | `test_finalize_notCourt_bubblesAndLeavesCaseVoting` |
| `_requireWindowFits` body emptied | `test_setDisputeTimeout_refusesAValueTheCourtCannotFitIn` |

Report any mutation that SURVIVES — that test is decorative and must be strengthened before the task closes.

- [ ] **Step 10.3: Push and update PR #52**

```bash
git push origin feat/token-court
gh pr comment 52 --repo sherwoodagent/sherwood-protocol --body "Incentive layer + review defects landed. See docs/superpowers/specs/2026-07-29-court-incentives-design.md. B1-B4 fixed; M1 accepted risk documented in §6 with its trigger."
```

---

## Self-review

**Spec coverage:** §2 bounty → Tasks 1, 2, 8. §3 holdings gate → Task 3. §4 off-chain APY → no task (policy, not code — correctly out of scope). §5 re-challenge window → Task 4. §6 M1 accepted → Task 9.1. §7 A1/A2/A5 → Tasks 9.2–9.3. §8 parameters/tests → Tasks 2, 8, 10.2. Review defects: B1→5, B2→6, B3→7, B4→3.

**Known unknowns, named not guessed:** whether `Challenge` carries the slashed amount (Step 2.1), whether `MockStakedWood` has `getVotes` (3.1), whether `BPS_DENOMINATOR` exists in `StakedWood` (1.4), `MockGameForCourt.setChallenge`'s real arity (5.1), the real fixture names in both test files, and — flagged loudest — **the proposed 500 bps default appears to FAIL its own pre-flight bound** (Step 8.1), which stops that task for a controller decision rather than guessing.

**Type consistency:** `slashToEscrow(..., address bountyTo, uint256 bountyBps)` identical in Tasks 1 and 2; `convictionBountyBpsAtFiling` on the `Challenge` struct used in Tasks 2 and 10; `WindowInvariantViolated` declared in both interfaces in Task 7; `caseOfChallenge(address,uint256)` consistent across Tasks 5 and 10.
