# Guardian Economic Security — Plan D: Challenge Game (v1b, part 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the challenge game of spec §3.4 — the *trigger* above Plan C's payout rails. Anyone may post a bonded challenge against an executed proposal, citing a predicate and an evidence pointer, which freezes the accused coverage. If nobody disputes within the delay, the covering approvers are slashed straight into the `CompensationEscrow`. If an accused approver posts a counter-bond, the challenge escalates to the court (Plan E) and, absent a ruling, times out in favour of the accused.

**Architecture:** One new contract, `ChallengeGame` (Ownable2Step, not upgradeable — same shape as `TierRegistry`/`ExposureLedger`). It reads `executedAt` and the vault from `SyndicateGovernor` and the covering approver set from `ExposureLedger`, freezes that proposal's committed coverage while a challenge is live, and on a passed challenge calls `StakedWood.slashToEscrow` — which Plan C already built and tested. `ExposureLedger` gains a coverage freeze and a public approver getter; `TierRegistry` gains an authorized-demoter role so a passed challenge can demote the offending adapter.

**Tech Stack:** Solidity 0.8.28, Foundry (forge test/fmt), OpenZeppelin Ownable2Step / SafeERC20. Repo conventions: custom errors declared in the interface, natspec with spec-section tags, tests in `test/*.t.sol`, storage goldens via `script/check-layout-goldens.sh`.

**Sequencing:** Plan A (§3.1–3.2) → Plan B (v1a: coverage ledger, quorum, bonds) → Plan C (v1b part 1: slash rails + compensation escrow, PR #24) → **this**. Then:

- **Plan E — the two-layer court (§3.5).** Bonded panel + token-vote appeal, the pre-exploit/pre-accumulation voting snapshot, and the bad-faith panel-bond track. It resolves the challenges this plan can only park.
- **Plan F — §3.4a epoch NAV checkpointing** (per-epoch mark-to-market, renewal-before-reveal, forced wind-down), giving predicate 5 its per-epoch attribution on strategies longer than one epoch.
- **Plan G — approver premium (§3.10) + watchtower funding**, gated on the §4 **blocking** ROE validation.

**Deliberate deviation from spec §4's phasing, decided 2026-07-25.** §4 orders the court LAST (v1c), after the epoch machinery and the premium, on the reasoning that *"an order that front-loads the novel forensic court while deferring the machinery that bounds loss is backwards for risk."* That reasoning held while the court was the ONLY path to liability. It no longer is: this plan lands a working undisputed-slash path, so the court stops being the whole mechanism and becomes the patch for one escape hatch — a guilty approver disputing and running out `disputeTimeout` (D5). Leaving that hole open across two more plans is worse than building the court earlier, and nothing in the epoch machinery or the premium is a prerequisite for it. **Update the spec's §4 phasing to match when Plan E is written.**

---

## The decisive design fact: adjudication is silence, not on-chain proof

§3.4's flow is **assertion + silence**, not verification:

> **Undisputed** challenge → slash auto-executes after a delay.
> **Disputed** (accused post a counter-bond) → escalates to adjudication (§3.5).

Nothing in the spec asks the chain to *verify* a predicate. The accused is given a window and a cheap way to contest; not contesting IS the adjudication. An earlier draft of this plan added an on-chain `prove()` that re-derived predicates 1/4/5 from stored calldata. That is dropped, for three reasons:

1. **It was never required.** It is an addition beyond §3.4, and it bought real risk — calldata parsing with the exact `transferFrom` arg-2 offset bug PR #13's review caught, historical oracle round lookups, and a duplicate of logic the vault's `_guardBatchCalls` already implements. Two copies of a parser is a divergence waiting to happen.
2. **Only three of five predicates could ever be proven on-chain anyway.** Predicate 2 (oracle price deviation) needs a venue-specific fair-value model; predicate 3 (proposer-linked destination) is a funding-graph question §8 itself says "needs a consistent evidentiary standard." A design where 1/4/5 are code-enforced and 2/3 are judge-enforced runs **two different security models** in one mechanism.
3. **Judges are already the trust root for the hard cases.** Extending them to the easy cases adds no new trust assumption; it removes a bifurcation.

**So a challenge is an assertion with an evidence pointer.** All five predicates are handled identically: file with a bond and an `evidenceURI`, freeze the accused coverage, and let silence or a counter-bond decide.

**The consequence, which must be named in the PR:** vigilance cost moves to guardians. A guardian who sleeps through the dispute window is slashed on an unproven assertion. That is defensible — they are staked professionals, the challenger posts a bond scaled to the coverage it freezes, and a bad-faith challenger forfeits that bond — but it is a genuine shift in who bears the watching burden, and it is why the dispute window must be generous relative to the auto-slash delay.

---

## Design decisions pinned before any code

**D1 — A challenge is a bonded assertion; adjudication is silence.** No on-chain predicate verification. All five predicates take the same path. The `Predicate` enum is retained purely as a **classification carried in the event** so watchtowers, indexers and (later) judges can filter and route — it does not branch any logic.

**D2 — Who gets slashed: the ledger's committed approvers.** `ExposureLedger._approversOf[reviewKey]` is the covering set, and each entry's committed share is what that guardian actually backed. It is currently `internal` with no getter — this plan adds `approversOf(governor, proposalId)`. Slashing that exact set is what makes §2's inequality hold: recovery is the sum of *their* bonds.

**D3 — Freeze is per-proposal, never whole-stake** (§3.4 "Freeze scope"). A live challenge pins the proposal's committed coverage so `releaseApproval` cannot free it and the guardian cannot recycle that budget while under challenge. It does **not** touch the guardian's stake or its other open approvals.

**D4 — Challenger bond scales with frozen exposure** (§3.4). `bond = frozenCoverageUsd * challengerBondBps / 10_000`, converted to WOOD at the ledger's haircut price. This is the ONLY thing deterring frivolous filings now that no proof is required, so it is load-bearing — a failed challenge forfeits it to the accused approvers pro-rata to their committed shares.

**D5 — A disputed challenge times out in favour of the accused.** An accused approver posts a counter-bond to dispute, which stops the auto-slash clock and escalates to the court. **The court (Plan E) does not exist yet**, so without a fallback both bonds and the frozen coverage would sit stuck forever — anyone could freeze a guardian's coverage indefinitely just by filing. Therefore: if no ruling lands within `disputeTimeout`, the challenge **fails** — the challenger's bond forfeits to the accused and the coverage unfreezes. Fail-safe toward *not* slashing, which is the right default when the adjudicator is missing.

**Accepted consequence:** until Plan E ships, a genuinely guilty party can dispute and run out the clock. That is the honest cost of shipping the game before the court, and it must be stated in the PR rather than discovered. It is strictly better than the alternative (indefinite freeze), because it keeps the mechanism live and bounded.

**D6 — The compensation snapshot is the block before execution.** Per §3.8, "pre-drain block" is the block before the challenged proposal executed. `ChallengeGame` passes `executedAt - 1` to `slashToEscrow`. Plan C's `snapshotTimestamp <= openedAt` guard is satisfied because the challenge opens after execution.

**D7 — Adapter demotion needs a new role.** §3.4: "Adapters demote only on a **passed** challenge." `TierRegistry.demote` is `onlyOwner`, so this plan adds an `authorizedDemoter` role (owner-set, pointed at `ChallengeGame`) rather than making the game the registry owner — the game can revoke a certification, never grant one.

**Invariant (spec §4 requires one per new accounting path, with a fuzz test):** the game's WOOD balance always equals the sum of (challenger bonds + counter-bonds) held for challenges still in `Filed` or `Disputed`.

---

### Task 1: ExposureLedger — public approver getter + per-proposal coverage freeze

**Files:**
- Modify: `src/ExposureLedger.sol`, `src/interfaces/IExposureLedger.sol`
- Test: `test/ExposureLedger.t.sol` (append)

The game needs two things the ledger does not yet expose: *who* covered a proposal (with how much), and a way to pin that coverage while a challenge is live.

- [ ] **Step 1: Write the failing tests** (append to `ExposureLedgerTest`; add `address internal freezer = makeAddr("freezer");` to the fixture and call `ledger.setCoverageFreezer(freezer)` as `owner` inside `_wireRecording()`)

```solidity
function test_approversOf_listsCommittedApprovers() public {
    _wireRecording();
    address g2 = makeAddr("g2");
    swood.setStake(g2, 100_000e18, 0);
    mgov.set(8_000e6);
    vm.prank(registry);
    ledger.recordApproval(address(mgov), 1, guardian);
    vm.prank(registry);
    ledger.recordApproval(address(mgov), 1, g2);

    (address[] memory gs, uint256[] memory shares) = ledger.approversOf(address(mgov), 1);
    assertEq(gs.length, 2);
    assertEq(gs[0], guardian);
    assertEq(gs[1], g2);
    assertEq(shares[0], 5_000e18); // its whole budget
    assertEq(shares[1], 3_000e18); // the remainder
}

/// @notice A released commitment reports a zero share rather than being
///         dropped — a caller must see the full historical set.
function test_approversOf_reportsReleasedAsZero() public {
    _wireRecording();
    mgov.set(3_000e6);
    vm.prank(registry);
    ledger.recordApproval(address(mgov), 1, guardian);
    vm.prank(registry);
    ledger.releaseApproval(address(mgov), 1, guardian);
    (address[] memory gs, uint256[] memory shares) = ledger.approversOf(address(mgov), 1);
    assertEq(gs.length, 1);
    assertEq(shares[0], 0);
}

function test_freeze_onlyFreezer() public {
    _wireRecording();
    vm.expectRevert(IExposureLedger.NotCoverageFreezer.selector);
    ledger.freezeCoverage(address(mgov), 1);
}

/// @notice §3.4: a live challenge pins the proposal's coverage. The guardian
///         cannot vote-change out of it and recycle the budget elsewhere while
///         it is under challenge.
function test_freeze_blocksRelease() public {
    _wireRecording();
    mgov.set(3_000e6);
    vm.prank(registry);
    ledger.recordApproval(address(mgov), 1, guardian);

    vm.prank(freezer);
    ledger.freezeCoverage(address(mgov), 1);

    vm.prank(registry);
    vm.expectRevert(IExposureLedger.CoverageFrozen.selector);
    ledger.releaseApproval(address(mgov), 1, guardian);
    assertEq(ledger.openExposureUsd(guardian), 3_000e18, "still committed");
}

function test_unfreeze_restoresRelease() public {
    _wireRecording();
    mgov.set(3_000e6);
    vm.prank(registry);
    ledger.recordApproval(address(mgov), 1, guardian);
    vm.prank(freezer);
    ledger.freezeCoverage(address(mgov), 1);
    vm.prank(freezer);
    ledger.unfreezeCoverage(address(mgov), 1);
    vm.prank(registry);
    ledger.releaseApproval(address(mgov), 1, guardian);
    assertEq(ledger.openExposureUsd(guardian), 0);
}

/// @notice The freeze is per-proposal, NOT whole-stake (§3.4 freeze scope):
///         the guardian's other open approvals are untouched.
function test_freeze_doesNotTouchOtherApprovals() public {
    _wireRecording();
    swood.setStake(guardian, 200_000e18, 0); // $10,000 of budget
    mgov.set(3_000e6);
    vm.prank(registry);
    ledger.recordApproval(address(mgov), 1, guardian);
    vm.prank(registry);
    ledger.recordApproval(address(mgov), 2, guardian);

    vm.prank(freezer);
    ledger.freezeCoverage(address(mgov), 1);

    // Proposal 2's commitment still releases normally.
    vm.prank(registry);
    ledger.releaseApproval(address(mgov), 2, guardian);
    assertEq(ledger.openExposureUsd(guardian), 3_000e18, "only the frozen one remains");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract ExposureLedgerTest -vv`
Expected: compilation failure — `approversOf` / `freezeCoverage` / `setCoverageFreezer` missing.

- [ ] **Step 3: Implement**

In `src/interfaces/IExposureLedger.sol` add:

```solidity
    error NotCoverageFreezer();
    error CoverageFrozen();

    event CoverageFreezerSet(address indexed oldFreezer, address indexed newFreezer);
    event CoverageFrozenSet(address indexed governor, uint256 indexed proposalId, bool frozen);

    /// @notice The covering approvers of a proposal and the USD each committed.
    ///         A released commitment reports a zero share rather than being
    ///         dropped, so a caller sees the full historical set.
    function approversOf(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory committedUsd);

    function freezeCoverage(address governor, uint256 proposalId) external;
    function unfreezeCoverage(address governor, uint256 proposalId) external;
    function isCoverageFrozen(address governor, uint256 proposalId) external view returns (bool);
    function setCoverageFreezer(address freezer) external;
    function coverageFreezer() external view returns (address);
```

In `src/ExposureLedger.sol`, add storage beside the other mappings:

```solidity
    /// @notice The one address permitted to freeze a proposal's coverage — the
    ///         ChallengeGame (spec §3.4). Owner-set.
    address public coverageFreezer;

    /// @dev Proposals whose committed coverage is pinned by a live challenge.
    mapping(bytes32 reviewKey => bool) internal _frozen;
```

Add the modifier, setter and three functions:

```solidity
    modifier onlyFreezer() {
        if (msg.sender != coverageFreezer) revert NotCoverageFreezer();
        _;
    }

    function setCoverageFreezer(address freezer) external onlyOwner {
        emit CoverageFreezerSet(coverageFreezer, freezer);
        coverageFreezer = freezer;
    }

    /// @inheritdoc IExposureLedger
    function approversOf(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint256[] memory committedUsd)
    {
        bytes32 key = _reviewKey(governor, proposalId);
        approvers = _approversOf[key];
        committedUsd = new uint256[](approvers.length);
        for (uint256 i = 0; i < approvers.length; i++) {
            committedUsd[i] = _recorded[key][approvers[i]].usd;
        }
    }

    /// @inheritdoc IExposureLedger
    /// @dev Spec §3.4 freeze scope: this pins ONE proposal's committed
    ///      coverage. It deliberately does not touch the guardian's stake or
    ///      its other open approvals — a challenge freezes the coverage it
    ///      accuses, not the guardian.
    function freezeCoverage(address governor, uint256 proposalId) external onlyFreezer {
        _frozen[_reviewKey(governor, proposalId)] = true;
        emit CoverageFrozenSet(governor, proposalId, true);
    }

    /// @inheritdoc IExposureLedger
    function unfreezeCoverage(address governor, uint256 proposalId) external onlyFreezer {
        _frozen[_reviewKey(governor, proposalId)] = false;
        emit CoverageFrozenSet(governor, proposalId, false);
    }

    /// @inheritdoc IExposureLedger
    function isCoverageFrozen(address governor, uint256 proposalId) external view returns (bool) {
        return _frozen[_reviewKey(governor, proposalId)];
    }
```

And in `releaseApproval`, immediately after computing `key`:

```solidity
        // A live challenge pins this coverage (§3.4): the guardian may not
        // release it and recycle the budget while under challenge.
        if (_frozen[key]) revert CoverageFrozen();
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract "ExposureLedger|RegistryExposureHook|GovernorCoverageGates|CoverageEndToEnd" -vv`
Expected: all PASS — the pre-existing suites never freeze, so they are unaffected.

- [ ] **Step 5: Commit**

```bash
git add src/ExposureLedger.sol src/interfaces/IExposureLedger.sol test/ExposureLedger.t.sol
git commit -m "feat(ledger): approver getter + per-proposal coverage freeze for the challenge game (spec 3.4)"
```

---

### Task 2: TierRegistry — authorized demoter

**Files:**
- Modify: `src/TierRegistry.sol`
- Test: `test/TierRegistry.t.sol` (append)

§3.4: "Adapters demote only on a **passed** challenge." `demote` is `onlyOwner`, so the game cannot call it. Add a role rather than handing the game registry ownership.

- [ ] **Step 1: Write the failing tests** (append to the existing `TierRegistryTest`; reuse its `reg` / `owner` / `target` fixture)

```solidity
function test_setAuthorizedDemoter_onlyOwner() public {
    vm.expectRevert();
    reg.setAuthorizedDemoter(makeAddr("rogue"));
}

function test_demoteByChallenge_onlyDemoter() public {
    vm.prank(owner);
    reg.certify(target, bytes4(0x77777777), 1, 500, address(0));
    vm.expectRevert(TierRegistry.NotAuthorizedDemoter.selector);
    reg.demoteByChallenge(target, bytes4(0x77777777));
}

/// @notice A passed challenge demotes the offending adapter back to the
///         tier-2 default without needing registry ownership (§3.4).
function test_demoteByChallenge_demotes() public {
    address demoter = makeAddr("demoter");
    vm.startPrank(owner);
    reg.certify(target, bytes4(0x77777777), 1, 500, address(0));
    reg.setAuthorizedDemoter(demoter);
    vm.stopPrank();

    (uint8 tierBefore,) = reg.tierOf(target, bytes4(0x77777777));
    assertEq(tierBefore, 1);

    vm.prank(demoter);
    reg.demoteByChallenge(target, bytes4(0x77777777));

    (uint8 tierAfter, uint16 boundAfter) = reg.tierOf(target, bytes4(0x77777777));
    assertEq(tierAfter, 2, "back to the arbitrary-calldata default");
    assertEq(boundAfter, 10_000);
}

/// @notice The demoter can only REVOKE. It must not be able to certify — that
///         is why this is a role rather than registry ownership.
function test_demoter_cannotCertify() public {
    address demoter = makeAddr("demoter");
    vm.prank(owner);
    reg.setAuthorizedDemoter(demoter);
    vm.prank(demoter);
    vm.expectRevert();
    reg.certify(target, bytes4(0x88888888), 1, 500, address(0));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract TierRegistryTest -vv`
Expected: compilation failure — `setAuthorizedDemoter` / `demoteByChallenge` / `NotAuthorizedDemoter` missing.

- [ ] **Step 3: Implement** — in `src/TierRegistry.sol`:

```solidity
    /// @notice The one address permitted to demote on a passed challenge — the
    ///         ChallengeGame (spec §3.4: "adapters demote only on a passed
    ///         challenge"). A ROLE rather than registry ownership, so the game
    ///         can revoke a certification but never grant one.
    address public authorizedDemoter;

    error NotAuthorizedDemoter();

    event AuthorizedDemoterSet(address indexed demoter);

    function setAuthorizedDemoter(address demoter) external onlyOwner {
        authorizedDemoter = demoter;
        emit AuthorizedDemoterSet(demoter);
    }

    /// @notice Demote (target, selector) back to the tier-2 default because a
    ///         challenge against it passed. Reuses the same `_demote` path as
    ///         owner demotion, so the submitter-bond release timelock starts
    ///         identically (§3.6 slash-first layering).
    function demoteByChallenge(address target, bytes4 selector) external {
        if (msg.sender != authorizedDemoter) revert NotAuthorizedDemoter();
        _demote(target, selector);
    }
```

- [ ] **Step 4: Run tests**

Run: `forge test --match-contract "TierRegistry|SelectorGuard|TierResolution|TierEndToEnd" -vv`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/TierRegistry.sol test/TierRegistry.t.sol
git commit -m "feat(tiers): authorized-demoter role so a passed challenge can demote (spec 3.4)"
```

---

### Task 3: ChallengeGame — filing, bonding, freeze

**Files:**
- Create: `src/ChallengeGame.sol`, `src/interfaces/IChallengeGame.sol`
- Create: `test/ChallengeGame.t.sol`

Build the fixture with mocks for the three reads the game makes (governor, ledger, tier registry) plus a real `ERC20Mock` WOOD — the real-integration proof lives in Task 6.

- [ ] **Step 1: Write the failing tests**

Cover: `file` pulls the bond and freezes coverage, and the challenge lands in `Filed`; the bond scales with frozen exposure ($10,000 committed × 500 bps = $500 → 10,000 WOOD at $0.05); filing against an unexecuted proposal reverts `NotExecuted`; filing after `executedAt + challengeWindow` reverts `WindowClosed`; a second live challenge on the same proposal reverts `AlreadyChallenged`; a proposal with zero committed coverage reverts `NothingToFreeze`.

- [ ] **Step 2: Run to verify they fail** — `forge test --match-contract ChallengeGameTest -vv`, compilation failure.

- [ ] **Step 3: Implement the interface and the filing half**

`src/interfaces/IChallengeGame.sol` declares:

```solidity
    enum Predicate {
        // Classification only (D1): carried in the event so watchtowers,
        // indexers and judges can filter and route. Branches no logic — every
        // predicate takes the same assertion path.
        OutOfAdapterOutflow,   // §3.4 #1
        OraclePriceDeviation,  // §3.4 #2
        ProposerLinkedOutflow, // §3.4 #3
        RogueAllowance,        // §3.4 #4
        DrawdownBreach         // §3.4 #5
    }

    enum Status { None, Filed, Disputed, Failed, Settled }

    error NotExecuted();
    error WindowClosed();
    error AlreadyChallenged();
    error NothingToFreeze();
    error WrongStatus();
    error DelayNotElapsed();
    error NotAccusedApprover();
    error ZeroAddress();
    error InvalidParameter();

    event ChallengeFiled(
        uint256 indexed challengeId,
        address indexed governor,
        uint256 indexed proposalId,
        address challenger,
        Predicate predicate,
        uint256 bondWood,
        string evidenceURI
    );
    event ChallengeDisputed(uint256 indexed challengeId, address indexed disputer, uint256 counterBondWood);
    event ChallengeSettled(uint256 indexed challengeId, uint256 slashedWood, uint256 caseId);
    event ChallengeFailed(uint256 indexed challengeId, uint256 forfeitedWood);
```

`ChallengeGame` stores per challenge: `(governor, proposalId, challenger, bondWood, counterBondWood, predicate, status, filedAt, frozenCoverageUsd)`.

`file(governor, proposalId, predicate, evidenceURI)`:
- reads the proposal (`executedAt != 0`, else `NotExecuted`), enforces `block.timestamp <= executedAt + challengeWindow`,
- sums the ledger's committed coverage for that proposal (`NothingToFreeze` if zero),
- computes `bondWood = coverageUsd * challengerBondBps / 10_000 * 1e8 / woodUsdPriceX8`,
- pulls the bond with SafeERC20, freezes coverage, records the challenge, emits `ChallengeFiled` (evidence URI included so predicates 2/3 carry their off-chain evidence pointer on-chain).

- [ ] **Step 4: Run → PASS. Step 5: Commit**

```bash
git add src/ChallengeGame.sol src/interfaces/IChallengeGame.sol test/ChallengeGame.t.sol
git commit -m "feat(challenge): bonded filing with per-proposal coverage freeze (spec 3.4)"
```

---

### Task 4: Dispute, timeout, resolve, slash, demote

**Files:**
- Modify: `src/ChallengeGame.sol`
- Test: `test/ChallengeGame.t.sol` (append)

- **`dispute(challengeId)`** — callable only by an accused approver of that proposal (checked against the ledger's approver list, `NotAccusedApprover` otherwise), only from `Filed`, and only before `filedAt + autoSlashDelay` elapses. Pulls a counter-bond equal to the challenger's and moves to `Disputed`, stopping the auto-slash clock.
- **`resolve(challengeId)`** — permissionless, and what it does depends on the state it finds:
  - **`Filed` and `filedAt + autoSlashDelay` elapsed → SLASH.** Nobody contested, so silence is the verdict (§3.4). Read the approver set and committed shares from the ledger, call `StakedWood.slashToEscrow(caseKey, filedAt, approvers, maxSlashBps, vault, executedAt - 1)`, demote the offending adapter via `TierRegistry.demoteByChallenge`, return the challenger's bond — **its bond and nothing else**, since the first-detector bounty is delivered off-chain (see below) — unfreeze, status `Settled`, emit `ChallengeSettled` with the escrow's `caseId`.
  - **`Disputed` and `filedAt + disputeTimeout` elapsed → FAIL (D5).** No court exists to rule, so the challenge fails safe: the challenger's bond forfeits to the accused approvers pro-rata to committed shares, the counter-bond returns to whoever posted it, coverage unfreezes, status `Failed`.
  - Neither deadline reached → revert `DelayNotElapsed`.
- **Owner setters:** `challengeWindow`, `autoSlashDelay`, `disputeTimeout`, `challengerBondBps`, plus the wired addresses (ledger, tier registry, sWOOD). **No `detectorBountyWood` and no escrow pointer:** the detector bounty is an off-chain bug-bounty program keyed off `ChallengeFiled` / `ChallengeSettled` (decided 2026-07-25 — no constant here can be "sized to cover forensic cost", which runs from minutes to days per case), and the compensation escrow is owner-set state on sWOOD rather than anything this game names, so the game can never redirect the proceeds of a slash it triggers. Bound `autoSlashDelay` to a sane floor — it is the guardian's entire window to notice and contest, and D1 moved the vigilance burden onto them.

Tests must include: undisputed `Filed` past the delay → slash lands in the escrow as a case pinned to `executedAt - 1`, and the adapter is demoted; `resolve` before the delay reverts `DelayNotElapsed`; `dispute` by a non-approver reverts `NotAccusedApprover`; `dispute` after the delay reverts (the window closed); a disputed challenge cannot be resolved before `disputeTimeout`; a disputed challenge past `disputeTimeout` fails, forfeits the challenger's bond to the accused pro-rata, and returns the counter-bond; coverage is unfrozen on **both** terminal paths, and the guardian can then actually `releaseApproval` again. Plus the §4-mandated fuzz: **the game's WOOD balance always equals the bonds held for live (`Filed`/`Disputed`) challenges**, across fuzzed bond sizes and resolution orders over several concurrent challenges.

- [ ] Commit: `feat(challenge): dispute, silence-verdict auto-slash, timeout-to-accused (spec 3.4)`

---

### Task 5: End-to-end — real drain, real slash, real compensation

**Files:**
- Create: `test/ChallengeEndToEnd.t.sol`

Model the fixture on `test/CompensationEndToEnd.t.sol` (real sWOOD, registry, vault, governor, escrow) and extend it with a real `ExposureLedger`, `TierRegistry` and `ChallengeGame`, fully wired: ledger's `coverageFreezer` = game, tier registry's `authorizedDemoter` = game, sWOOD's `authorizedSlasher` = game, escrow's `authorizedFunder` = sWOOD.

Two arcs, both substantive. **Note there is no `prove()` step in either of them** — D1 deleted on-chain predicate verification, so a challenge is filed and then either met with silence or met with a counter-bond. Both arcs therefore run `file → (dispute or silence) → resolve`, and the only thing that differs is which of the two `resolve` branches the clock lands on.

1. **The happy arc — silence is the verdict**, asserting at each stage: `propose (bond locked) → guardian approves (coverage committed) → execute → file a predicate-1 challenge naming the certified adapter (bond pulled, coverage frozen, and assert the guardian genuinely CANNOT release it) → nobody disputes → warp past autoSlashDelay → resolve → guardian slashed, proceeds in the escrow as a case pinned to the pre-drain block, adapter demoted, challenger bond returned → pre-drain LPs redeem their compensation, post-drain buyer gets nothing.`
2. **The bad-faith arc — a disputed challenge times out to the accused (D5).** A CLEAN proposal is challenged; nothing on-chain can tell that filing apart from the honest one, which is exactly D1's point and exactly why the bond prices the difference. An accused approver posts a matching counter-bond, which stops the auto-slash clock and escalates to a court that does not exist yet, so nobody rules. Warp past `disputeTimeout` → `resolve` forfeits the challenger's bond to the accused approvers pro-rata to their committed shares, returns the counter-bond, and unfreezes the coverage, which they can then release normally. Assert the negative space too: nothing slashed, no case opened, the adapter keeps its certification — a failed challenge must leave no mark. This is what makes the bond a real deterrent rather than a formality.

- [ ] Commit: `test: end-to-end challenge -> proof -> slash -> victim compensation`

---

### Task 6: Deploy wiring, goldens, full suite, PR

- [ ] **Deploy script.** Add `script/DeployPlanD.s.sol` following `script/DeployPlanB.s.sol`'s conventions (env-var address book, pre-flight asserts, no `--broadcast` in testing): deploy `ChallengeGame`, then wire all four roles — `ledger.setCoverageFreezer`, `tierRegistry.setAuthorizedDemoter`, `swood.setAuthorizedSlasher`, and confirm `escrow.authorizedFunder == swood`. Pre-flight assert each role is unset before wiring, and print the manual follow-ups.
- [ ] **Goldens.** `ExposureLedger` and `TierRegistry` are NOT upgradeable, so their layouts are unconstrained — but run `./script/check-layout-goldens.sh` anyway and confirm the four pinned contracts are untouched. **Inspect `git diff` and confirm no pre-existing slot moved.**
- [ ] **Full suite.** `forge test` — no new failures beyond the known baseline (22: 21 fork tests needing `--fork-url`, 1 `SetGuardianRegistry` mock issue).
- [ ] **Format.** `forge fmt && forge fmt --check`.
- [ ] **Spec status.** Update the header: v1b part 2 complete; `authorizedSlasher` is now the ChallengeGame rather than a multisig, so an UNDISPUTED verdict is finally driven by the mechanism instead of governance; a DISPUTED one still times out to the accused until Plan E (the court) ships. **Also update §4's phasing** to record that the court was moved ahead of the epoch machinery and the premium (see the Sequencing note above).
- [ ] **PR** against `feat/guardian-econ-security-c`.

---

## Self-review checklist

1. **Spec coverage:** §3.4 bonded filing → Task 3. All five predicates → Task 3 (uniform assertion path) + D1. Freeze scope → Task 1 + D3. Undisputed auto-slash → Task 4. Disputed → escalation → Task 4 + D5 (escalates, then times out to the accused because the court is not built yet). Failed challenge forfeits to the accused → Task 4. Adapters demote only on a passed challenge → Tasks 2 + 4. §4 invariant + fuzz → Task 4.
2. **Deliberately NOT in this plan (state in the PR):** adjudication of a disputed challenge (Plan E, next); §3.4a epoch NAV checkpointing and its per-epoch attribution (Plan F); the watchtower's funded monitoring role and §3.10's approver premium (Plan G). The first-detector bounty is **not paid here at all** — it moved off-chain to a protocol bug-bounty program keyed off this contract's events, which means that on-chain a successful challenger only breaks even and the incentive to file lives entirely outside the mechanism. **No on-chain predicate verification** — see D1 for why that is a deliberate simplification rather than a gap.
3. **Known gaps carried forward — name these in the PR:** (a) a genuinely guilty approver can dispute and run out `disputeTimeout`, escaping the slash until Plan E (the court) ships (D5) — the accepted cost of failing safe when the adjudicator is missing; (b) vigilance moves to guardians, who are slashed on an unproven assertion if they sleep through `autoSlashDelay` (D1); (c) a bad-faith challenger can freeze a guardian's coverage for the duration of a challenge at the cost of its bond. All three are direct consequences of shipping the game before the court, and none should be discovered by a reader rather than told.
4. **Type consistency:** `approversOf(address,uint256) → (address[], uint256[])` is used identically in Tasks 1, 4, 5. `slashToEscrow`'s arity as of this plan is Plan C's post-review **six**-parameter form `(bytes32 caseKey, uint256 openedAt, address[] approvers, uint256 slashBps, address vault, uint256 snapshotTimestamp)` — the escrow address is owner-set state on `StakedWood`, NOT a parameter. **STALE as of `2026-07-29-court-incentives-design.md` §2:** Task 1 of that plan appended `(address bountyTo, uint256 bountyBps)`, making the real arity today **eight** parameters, capped in `StakedWood` by `MAX_CONVICTION_BOUNTY_BPS`. `demoteByChallenge(address,bytes4)` matches Tasks 2 and 4. `Predicate` / `Status` enum member names are identical in Tasks 3, 4, 5.
