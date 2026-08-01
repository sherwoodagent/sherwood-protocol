# Guardian Economic Security — Plan E: Two-Layer Court (v1c)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the adjudication layer of spec §3.5 — the bonded panel and the token-vote appeal that resolve the challenges Plan D can only park. This closes the hole Plan D knowingly opened: today a disputed challenge times out in favour of the accused, so **a genuinely guilty approver can dispute and run out the clock**.

**Architecture:** One new contract, `Court` (Ownable2Step, not upgradeable — the house shape). A disputed challenge is referred to a panel of governance-elected members, each holding a slashable bond; the panel rules within `panelWindow`. Any ruling is appealable to a full WOOD vote weighted by `StakedWood.getPastVotes` at the block **before the challenged proposal executed**, and an appeal only overturns if turnout clears a participation floor. A **separate** token vote — never the merits appeal — decides whether a ruling was made in bad faith and slashes the panelist's bond. The final outcome calls a new court-only `ChallengeGame.rule(challengeId, guilty)`, which routes into Plan D's existing `_settle` (slash into the compensation escrow) or `_fail` (challenger's bond forfeits to the accused).

**Tech Stack:** Solidity 0.8.28, Foundry (forge test/fmt), OpenZeppelin Ownable2Step / SafeERC20. Repo conventions: custom errors declared in the interface, natspec with spec-section tags, tests in `test/*.t.sol`, storage goldens via `script/check-layout-goldens.sh`.

**Sequencing:** Plan A (§3.1–3.2) → Plan B (v1a) → Plan C (v1b part 1: slash rails + compensation escrow, PR #24) → Plan D (v1b part 2: challenge game, PR #25) → **this**. Remaining afterwards: **Plan F** (§3.4a epoch NAV checkpointing) and **Plan G** (§3.10 approver premium + watchtower funding, gated on the §4 blocking ROE validation).

---

## Two facts that shape this plan

**1. The aged-stake requirement is already satisfied — do not build it again.** §3.5 asks that "dispute voting weight uses **aged** stake … so WOOD accumulated shortly before the exploit carries reduced weight." `StakedWood`'s own interface documents `getPastVotes` as *"AGE-WEIGHTED own staked + delegated-inbound capped at `delegatedWeightCapX ×` aged own"* (`src/interfaces/IStakedWood.sol:66-67`). So the pre-accumulation defense comes free from the existing primitive: read `getPastVotes(voter, snapshotTs)` and the age weighting is applied for you. Writing new age math would duplicate — and inevitably diverge from — the staking contract's.

**2. This plan cannot be split into "panel now, appeal later."** §3.5 is explicit about why:

> A token vote alone is (1) incompetent for forensic questions (single-digit turnout, narrative over trace) and (2) capturable at ~$15M mcap. A standalone panel is bribable (5 humans, bribe 3) with no check above it. **The layers cover each other's failure mode.**

Shipping the panel without the appeal deploys a mechanism the spec names as bribable, holding authority over 100% slashes. Shipping the appeal without the panel puts forensic questions to a single-digit-turnout token vote. **Neither half is safe alone, so `Court` must not be wired into `ChallengeGame` until both layers plus the bad-faith track are live.** Task 7 makes that a deploy-time pre-flight, not a convention.

---

## Design decisions pinned before any code

**D1 — Panel membership is owner-set; elections stay off-chain.** §3.5 says panel members are "elected by WOOD governance." On-chain elections are a governance subsystem in their own right and are out of scope. `Court` takes an owner-set panel roster (`setPanel`), where the owner is the governance multisig executing the election result. State this plainly in the PR — the *selection* is trusted, the *behaviour* is bonded.

**D2 — The snapshot is `executedAt - 1`, reusing Plan C's rule.** §3.5: voting power is snapshotted "before the challenged proposal's execution block." That is the same instant §3.8 uses for compensation claims, and Plan D already passes it to `slashToEscrow`. The court reads `governor.getProposal(proposalId).executedAt` and snapshots at `executedAt - 1`. One rule, three consumers — do not invent a second.

**D3 — Aged stake comes from `getPastVotes`; the floor denominator from `getPastTotalVotes`.** Per fact 1. The participation floor is `turnout >= participationFloorBps * getPastTotalVotes(snapshotTs) / 10_000`.

**D4 — Bad faith is a SEPARATE vote from the merits appeal (F6).** This is the single most important structural point in §3.5. The first draft slashed the panel bond only on a merits overturn, which "let an attacker who controls the cheap appeal make a corrupt ruling safe and gave panelists a beauty-contest incentive to predict the vote." Therefore: overturning a ruling on the merits **must not** slash the panelist, and controlling the merits appeal **must not** immunize one. Two independent tracks, two independent votes.

**D5 — Panelist reward is flat.** Independent of which way they rule, so there is no incentive to track the expected vote rather than the evidence (§3.5). A ruling panelist earns the same whether it convicts or acquits.

**D6 — Below the participation floor, the panel ruling stands.** An appeal that fails to reach quorum is not an acquittal and not a conviction — it is a non-event, and the panel's ruling is final. This is what removes the "swing a single-digit-turnout appeal cheaply" path.

**D7 — A guilty verdict slashes at `maxSlashBps`, no severity ramp** (§3.5: "ground truth established"). Plan D's `_settle` already does exactly this; the court supplies only the guilty/not-guilty bit.

**Invariant (spec §4 requires one per new accounting path, with a fuzz test):** the court's WOOD balance always equals the sum of (panel bonds posted by seated panelists) + (appeal and bad-faith bonds for votes still open).

---

### Task 1: ChallengeGame — a court-only ruling entrypoint

**Files:**
- Modify: `src/ChallengeGame.sol`, `src/interfaces/IChallengeGame.sol`
- Test: `test/ChallengeGame.t.sol` (append)

Plan D left `Disputed` terminal-with-timeout. The court needs to force either outcome before that timeout.

- [ ] **Step 1: Write the failing tests**

```solidity
function test_rule_onlyCourt() public {
    uint256 id = _fileAndDispute();
    vm.expectRevert(IChallengeGame.NotCourt.selector);
    game.rule(id, true);
}

/// @notice A guilty ruling routes into the SAME settle path an undisputed
///         challenge takes — slash into the escrow, adapter demoted, bond
///         returned — so the court supplies only the verdict bit (D7).
function test_rule_guiltySettles() public {
    uint256 id = _fileAndDispute();
    vm.prank(court);
    game.rule(id, true);
    assertEq(uint256(game.challengeOf(id).status), uint256(IChallengeGame.Status.Settled));
}

/// @notice A not-guilty ruling fails the challenge: the challenger's bond
///         forfeits to the accused, exactly as a timeout would.
function test_rule_notGuiltyFails() public {
    uint256 id = _fileAndDispute();
    vm.prank(court);
    game.rule(id, false);
    assertEq(uint256(game.challengeOf(id).status), uint256(IChallengeGame.Status.Failed));
}

/// @notice The court may only rule on a DISPUTED challenge. A `Filed` one is
///         still inside its own auto-slash clock and has not been escalated.
function test_rule_onlyFromDisputed() public {
    uint256 id = _file();
    vm.prank(court);
    vm.expectRevert(IChallengeGame.WrongStatus.selector);
    game.rule(id, true);
}

/// @notice A ruling BEATS the timeout: once the court has ruled, the challenge
///         is terminal and `resolve` cannot re-resolve it.
function test_rule_thenResolveReverts() public {
    uint256 id = _fileAndDispute();
    vm.prank(court);
    game.rule(id, true);
    vm.warp(vm.getBlockTimestamp() + game.disputeTimeout() + 1);
    vm.expectRevert(IChallengeGame.WrongStatus.selector);
    game.resolve(id);
}

/// @notice With no court wired, Plan D's timeout behaviour is unchanged — a
///         disputed challenge still fails to the accused. This is what makes
///         the court additive rather than a breaking change.
function test_noCourtWired_timeoutStillFailsToAccused() public {
    vm.prank(owner);
    game.setCourt(address(0));
    uint256 id = _fileAndDispute();
    vm.warp(vm.getBlockTimestamp() + game.disputeTimeout() + 1);
    game.resolve(id);
    assertEq(uint256(game.challengeOf(id).status), uint256(IChallengeGame.Status.Failed));
}
```

- [ ] **Step 2: Run to verify they fail** — `forge test --match-contract ChallengeGameTest -vv`; `rule` / `setCourt` / `NotCourt` missing.

- [ ] **Step 3: Implement**

Add to `IChallengeGame`: `error NotCourt();`, `event CourtSet(address indexed oldCourt, address indexed newCourt);`, `event ChallengeRuled(uint256 indexed challengeId, bool guilty);`, and `rule(uint256,bool)` / `setCourt(address)` / `court()`.

In `ChallengeGame`:

```solidity
    /// @notice The adjudicator for disputed challenges (spec §3.5, Plan E).
    ///         address(0) leaves Plan D's behaviour intact: a disputed
    ///         challenge simply times out in favour of the accused.
    address public court;

    function setCourt(address newCourt) external onlyOwner {
        emit CourtSet(court, newCourt);
        court = newCourt;
    }

    /// @notice Court-only verdict on a disputed challenge (§3.5). Supplies ONLY
    ///         the guilty/not-guilty bit: a guilty ruling routes into the same
    ///         `_settle` an undisputed challenge takes (slash at `maxSlashBps`
    ///         with no severity ramp — §3.5 "ground truth established"), and a
    ///         not-guilty one into the same `_fail`. Ruling BEATS the timeout:
    ///         once terminal, `resolve` can no longer act.
    function rule(uint256 challengeId, bool guilty) external {
        if (msg.sender != court) revert NotCourt();
        Challenge storage c = _challenges[challengeId];
        if (c.status != Status.Disputed) revert WrongStatus();
        emit ChallengeRuled(challengeId, guilty);
        if (guilty) {
            _settle(challengeId, c);
        } else {
            _fail(challengeId, c);
        }
    }
```

**Check `_fail`'s counter-bond handling before wiring.** Plan D's `_fail` returns the counter-bond to its poster and forfeits the challenger's bond to the accused. That is correct for a not-guilty ruling too — the disputer was right. Read `_fail` and confirm it makes no assumption specific to the timeout path; if it does, fix it here.

- [ ] **Step 4: Run → green. Step 5: Commit**

```bash
git add src/ChallengeGame.sol src/interfaces/IChallengeGame.sol test/ChallengeGame.t.sol
git commit -m "feat(challenge): court-only ruling entrypoint on disputed challenges (spec 3.5)"
```

---

### Task 2: Court — panel roster and bonds

**Files:**
- Create: `src/Court.sol`, `src/interfaces/ICourt.sol`
- Create: `test/Court.t.sol`

- [ ] **Step 1: Write the failing tests**

Cover: `setPanel` is owner-only and seats N members (D1); a seated panelist must post `panelBondWood` before it can rule, and `postPanelBond` pulls it with SafeERC20; an unbonded panelist cannot rule; `setPanel` cannot unseat a panelist while it has an open ruling (else its bond escapes the bad-faith track); `withdrawPanelBond` only after the member is unseated **and** no bad-faith window is open against any of its rulings; the §4 invariant view (`bondedWood`) tracks posted bonds exactly.

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement the roster half**

`ICourt` declares errors (`NotPanelist`, `PanelBondNotPosted`, `AlreadyRuled`, `WrongPhase`, `WindowClosed`, `WindowOpen`, `ParticipationFloorNotMet`, `AlreadyVoted`, `NoVotingPower`, `ZeroAddress`, `InvalidParameter`), the `Ruling` enum (`None, Guilty, NotGuilty`), the events, and the function set. `Court` stores the roster as `mapping(address => bool) isPanelist` plus a seated count, `panelBondWood` per member, and `bondedWood` for the invariant.

- [ ] **Step 4: Green. Step 5: Commit**

```bash
git commit -m "feat(court): panel roster with slashable member bonds (spec 3.5)"
```

---

### Task 3: Layer 1 — the panel rules

**Files:**
- Modify: `src/Court.sol`, `src/interfaces/ICourt.sol`
- Test: `test/Court.t.sol` (append)

`refer(challengeId)` — callable by anyone once a challenge is `Disputed` (read `ChallengeGame.challengeOf`), opening a case `(challengeId, snapshotTs, referredAt, phase = Panel)`. **The snapshot is computed here, ONCE**, as `governor.getProposal(proposalId).executedAt - 1` (D2), and stored — every later vote reads the stored value, so no two votes can disagree about the electorate.

`panelRule(caseId, guilty)` — a bonded panelist records its vote. `finalizePanel(caseId)` writes `panelRuling` once `panelWindow` elapses or every seated member has voted, and opens the appeal window. **A panel that does not rule within `panelWindow` yields `NotGuilty` by default** — fail-safe toward not slashing, consistent with Plan D's D5. Document it; it is a real property, not an accident.

Tests: non-panelist cannot rule; unbonded panelist cannot rule; double-vote reverts; majority resolves; tie → `NotGuilty` (fail-safe); silence past the window → `NotGuilty`; `finalizePanel` before the window with votes outstanding reverts; a case cannot be referred twice; referring a non-`Disputed` challenge reverts.

- [ ] Commit: `feat(court): layer-1 panel ruling with fail-safe default (spec 3.5)`

---

### Task 4: Layer 2 — the token-vote appeal

**Files:**
- Modify: `src/Court.sol`, `src/interfaces/ICourt.sol`
- Test: `test/Court.t.sol` (append)

`appeal(caseId)` — anyone may appeal within `appealWindow` of `finalizePanel`, posting `appealBondWood`. Moves the case to `phase = Appeal`.

`voteAppeal(caseId, guilty)` — weight is `stakedWood.getPastVotes(msg.sender, c.snapshotTs)`; zero weight reverts `NoVotingPower`; one vote per address per case. **The age weighting is already inside `getPastVotes` (D3) — do not re-weight.**

`finalizeAppeal(caseId)` after `appealVoteWindow`:
- `turnout = guiltyVotes + notGuiltyVotes`; `floor = participationFloorBps * stakedWood.getPastTotalVotes(c.snapshotTs) / 10_000`
- **`turnout < floor` → the PANEL RULING STANDS** (D6). Not an acquittal; a non-event. The appellant's bond forfeits (it failed to raise a quorum). Give this its own branch and its own event — it is the anti-capture property.
- `turnout >= floor` → the majority of cast votes decides and overrides the panel.
- Either way, call `ChallengeGame.rule(challengeId, finalRuling == Guilty)`.

`finalizeUnappealed(caseId)` — if `appealWindow` passed with no appeal, the panel ruling is final; call `rule` directly.

Tests: appeal after the window reverts; a voter with no pre-exploit stake reverts `NoVotingPower` (**this is the flash-loan / post-drain-buyer defense — assert it with an address that staked only AFTER `snapshotTs`**); double-vote reverts; below-floor turnout leaves the panel ruling standing even when the cast votes went the other way (the D6 test, and the most important in this task); above-floor turnout overturns; an unappealed ruling finalizes; `rule` is actually called on `ChallengeGame` with the right bit in every branch.

- [ ] Commit: `feat(court): layer-2 token-vote appeal with participation floor (spec 3.5)`

---

### Task 5: The bad-faith track (F6)

**Files:**
- Modify: `src/Court.sol`, `src/interfaces/ICourt.sol`
- Test: `test/Court.t.sol` (append)

**This is a SEPARATE track from the merits appeal (D4), and the tests must prove the independence in BOTH directions.**

`openBadFaith(caseId, panelist)` — within `badFaithWindow` of the case finalizing, anyone may open a bad-faith vote against a specific panelist's ruling, posting `badFaithBondWood`.

`voteBadFaith(caseId, panelist, badFaith)` — same electorate and the same stored `snapshotTs` as the appeal, same participation floor.

`finalizeBadFaith(caseId, panelist)` — if the floor is met and the majority says bad faith, slash that panelist's `panelBondWood`; otherwise return the posting and leave the panelist whole. Send slashed panel bonds to the protocol backstop (the same address `CompensationEscrow.backstop` uses) — pick one destination and document why it is not the compensation escrow's per-case claims (a corrupt panelist's bond is not the drained value, and mixing them would let a bad-faith slash inflate a victim case).

Tests that must exist:
- **Overturning the merits does NOT slash the panelist** — run an appeal that overturns, assert the panel bond is untouched. Without this test the F6 fix is unverified.
- **Controlling the merits appeal does NOT immunize a panelist** — a case where the merits appeal *upheld* the ruling but a bad-faith vote still slashes.
- A below-floor bad-faith vote does not slash.
- A panelist cannot withdraw its bond while a bad-faith window is open.
- Flat reward (D5): assert a panelist's reward is identical whether it ruled guilty or not guilty.

- [ ] Commit: `feat(court): bad-faith panel-bond track, independent of the merits appeal (spec 3.5 F6)`

---

### Task 6: End-to-end — a disputed challenge actually resolves

**Files:**
- Create: `test/CourtEndToEnd.t.sol`

Extend `test/ChallengeEndToEnd.t.sol`'s real stack (real sWOOD, registry, vault, governor, ledger, tier registry, both escrows, `ChallengeGame`) with a real `Court`, wired `game.setCourt(court)`.

Three arcs:

1. **Guilty, unappealed:** propose → approve → execute → file → dispute → refer → panel rules guilty → appeal window lapses → `finalizeUnappealed` → **the guardian is slashed into the compensation escrow and pre-drain LPs redeem**. This is the arc proving Plan D's hole is closed: assert the guilty approver could NOT have escaped by disputing.
2. **Acquitted on appeal:** panel rules guilty → the appeal reaches quorum and overturns → challenge `Failed`, challenger's bond forfeits to the accused, **and the panelist's bond is untouched** (D4).
3. **Below-floor appeal:** panel rules guilty → an appeal is filed but turnout misses the floor → **the panel ruling stands** and the guardian is slashed (D6). The anti-capture arc.

- [ ] Commit: `test: end-to-end disputed challenge -> panel -> appeal -> slash`

---

### Task 7: Deploy wiring, goldens, full suite, PR

- [ ] **Deploy script** `script/DeployPlanE.s.sol`, following `script/DeployPlanD.s.sol`'s conventions (env-var address book, pre-flights that fail before deploying, `console.log` of manual follow-ups, never `--broadcast` in testing).

  **The pre-flights are load-bearing here, not ceremony** — because of fact 2 at the top of this plan, a half-wired court is worse than none:
  - `game.court() == address(0)` (not stealing the role from a live court)
  - the panel roster is seated AND every seated member has posted its bond — a court wired to an unbonded panel has no slashable skin in the game, which is the entire binding incentive
  - `participationFloorBps != 0` — a zero floor silently removes D6's anti-capture property
  - `badFaithWindow != 0` — a zero window means the F6 track can never open, leaving a bribable panel
  - Plan D's own wiring intact (`game.stakedWood()`, ledger freezer, tier demoter) so the ruling path does not dead-end

  Verify by simulation against a local anvil if no fork RPC is configured, and **break the state deliberately to prove each pre-flight bites** (Plan D's Task 6 agent did this; match that bar). Never `--broadcast`.

- [ ] **Goldens:** `Court` is not upgradeable, so its layout is unconstrained. Run `./script/check-layout-goldens.sh` and confirm the four pinned contracts are untouched. `ChallengeGame` gained a `court` slot — it is also not upgradeable, so no golden covers it; **say that rather than implying it was checked.**
- [ ] **Full suite:** `forge test` — no NEW failures beyond the known baseline of 22 (21 fork tests needing `--fork-url`, 1 `SetGuardianRegistry` mock issue). Report exact counts.
- [ ] **`forge fmt && forge fmt --check`.**
- [ ] **Spec status header:** v1c complete — the court adjudicates disputed challenges, closing the Plan D hole (a guilty approver disputing and running out the clock). Note what remains: Plan F (§3.4a epoch NAV) and Plan G (§3.10 premium + watchtower funding).
- [ ] **PR** against `feat/guardian-econ-security-d`.

---

## Self-review checklist

1. **Spec coverage:** §3.5 pre-exploit voting snapshot → D2 + Task 3 (computed once, stored). Aged stake → D3 (free from `getPastVotes`). Participation floor → Task 4 + D6. Two-layer panel + appeal → Tasks 3, 4. Bad-faith track separate from merits → Task 5 + D4. Flat panelist reward → D5 + Task 5. Guilty → `maxSlashBps`, proceeds to the compensation escrow → Task 1 + D7 (reuses Plan D's `_settle`, which reuses Plan C's `slashToEscrow`). §4 invariant + fuzz → Task 2.
2. **Deliberately NOT in this plan (state in the PR):** on-chain panel elections (D1 — the roster is owner-set from an off-chain governance result); §3.4a epoch NAV checkpointing (Plan F); the approver premium and watchtower funding (Plan G). Panel *selection* is trusted; panel *behaviour* is bonded — say it that way.
3. **Known gaps to name in the PR:** (a) D1 means a compromised governance multisig can seat a captured panel — the bad-faith track and the sovereign appeal are the checks, not the roster; (b) a panel that simply never rules yields `NotGuilty` by default, so an inactive panel acquits rather than convicts (fail-safe, but panel liveness becomes an operational requirement); (c) the participation floor is a fixed bps of `getPastTotalVotes` at the snapshot — if staking participation collapses, the floor gets easier to clear in absolute terms.
4. **Type consistency:** `ChallengeGame.rule(uint256,bool)` is used identically in Tasks 1, 4, 5, 6. `Ruling` enum member names are identical across Tasks 3–6. The snapshot is `executedAt - 1` everywhere (D2) — the same expression Plan C's `slashToEscrow` and Plan D's `_settle` already use. `getPastVotes(address,uint256)` / `getPastTotalVotes(uint256)` match `src/interfaces/IStakedWood.sol` exactly.
