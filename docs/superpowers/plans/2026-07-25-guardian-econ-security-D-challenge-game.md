# Guardian Economic Security — Plan D: Challenge Game (v1b, part 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the challenge game of spec §3.4 — the *trigger* above Plan C's payout rails. Anyone may post a bonded challenge against an executed proposal citing an objective violation predicate; a mechanically-provable predicate auto-proves on-chain and, after a delay with no dispute, slashes the covering approvers straight into the `CompensationEscrow`; a disputed or assertion-only challenge parks for the court (v1c).

**Architecture:** One new contract, `ChallengeGame` (Ownable2Step, not upgradeable — same shape as `TierRegistry`/`ExposureLedger`). It reads proposal facts from `SyndicateGovernor` (stored calls, envelope, capital snapshot, executedAt) and the covering approver set from `ExposureLedger`, freezes that proposal's committed coverage while a challenge is live, and on a passed challenge calls `StakedWood.slashToEscrow` — which Plan C already built and tested. `ExposureLedger` gains a coverage freeze and a public approver getter; `TierRegistry` gains an authorized-demoter role so a passed challenge can demote the offending adapter.

**Tech Stack:** Solidity 0.8.28, Foundry (forge test/fmt), OpenZeppelin Ownable2Step / SafeERC20. Repo conventions: custom errors declared in the interface, natspec with spec-section tags, tests in `test/*.t.sol`, storage goldens via `script/check-layout-goldens.sh`.

**Sequencing:** Plan A (§3.1–3.2) → Plan B (v1a: coverage ledger, quorum, bonds) → Plan C (v1b part 1: slash rails + compensation escrow, PR #24) → **this**. After it, v1b still needs:
- **Plan E — §3.4a epoch NAV checkpointing** (per-epoch mark-to-market, renewal-before-reveal, forced wind-down). Required before predicate 5 can bind on strategies longer than one epoch; this plan implements predicate 5 only for strategies that settle within one epoch.
- **Plan F — approver premium (§3.10) + watchtower funding**, gated on the §4 **blocking** ROE validation.
- v1c — the two-layer court (§3.5), which is what a disputed challenge parks for.

---

## The decisive scoping fact: only three of the five predicates are on-chain checkable

§3.4 lists five predicates and calls them all "objective violation predicates checkable from public calldata + trace". Two of them are not checkable *on-chain*:

| # | Predicate | On-chain? | Handling in this plan |
|---|---|---|---|
| 1 | Net outflow to addresses outside the whitelisted adapter set | **Yes** — re-derive from the governor's stored `_executeCalls` + `TierRegistry.isAdapterAllowed` | `prove()` verifies, auto-passes |
| 2 | Execution price deviation vs a manipulation-resistant oracle | **No** — needs the oracle round at the execution block plus a venue-specific fair-value model | Assertion only → parks for the court |
| 3 | Outflow destination linkable to the proposer (funding graph) | **No** — §8 itself says this "needs a consistent evidentiary standard" | Assertion only → parks for the court |
| 4 | Allowance/ownership granted to a non-protocol address | **Yes** — the same selector/target analysis the vault's `_guardBatchCalls` already performs | `prove()` verifies, auto-passes |
| 5 | Single-proposal drawdown breach vs declared `maxDrawdownBps` | **Yes, for a strategy settling within one epoch** — `getCapitalSnapshot(pid)` vs realized assets at settle | `prove()` verifies, auto-passes; long strategies need Plan E |

**This is the plan's central design decision (D1).** A challenge carries a predicate id. Predicates 1/4/5 are *provable*: `prove()` re-derives the violation from chain state and, if it holds, moves the challenge to `Proven` with no human in the loop. Predicates 2/3 are *assertions*: they can be filed and they freeze coverage, but they can only ever reach `Disputed` and wait for the court. Pretending 2/3 were auto-verifiable would be the dangerous outcome — it would let a bonded filing slash on an unproven claim.

**Consequence to state in the PR:** until v1c exists, a predicate-2 or -3 challenge can freeze coverage and forfeit bonds but can never slash. Only 1/4/5 close the loop end-to-end.

---

## Design decisions pinned before any code

**D1 — Provable vs assertion-only predicates.** As above. `prove()` reverts `PredicateNotProvable` for 2/3.

**D2 — Who gets slashed: the ledger's committed approvers.** `ExposureLedger._approversOf[reviewKey]` is the covering set, and each entry's committed share is what that guardian actually backed. It is currently `internal` with no getter — this plan adds `approversOf(governor, proposalId)`. Slashing that exact set is what makes §2's inequality hold: recovery is the sum of *their* bonds.

**D3 — Freeze is per-proposal, never whole-stake** (§3.4 "Freeze scope"). A live challenge marks the proposal's committed coverage frozen in the ledger so `releaseApproval` cannot free it and the guardian cannot recycle that budget into a fresh approval while under challenge. It does **not** touch the guardian's stake or its other open approvals.

**D4 — Challenger bond scales with frozen exposure** (§3.4). `bond = frozenCoverageUsd * challengerBondBps / 10_000`, converted to WOOD at the ledger's haircut price. A failed challenge forfeits it to the accused approvers pro-rata to their committed shares; a passed challenge returns it and pays the §3.4 first-detector bounty.

**D5 — Disputed parks, it does not resolve.** An accused approver posts a counter-bond to dispute. That moves the challenge to `Disputed` and stops the auto-slash clock **permanently until v1c**. This plan ships no adjudication. `Disputed` is a terminal state here, and the PR must say so plainly rather than implying a court exists.

**D6 — The compensation snapshot is the block before execution.** Per §3.8, for predicates 1–4 and predicate 5 on a short strategy, "pre-drain block" is the block before the challenged proposal executed. `ChallengeGame` passes `executedAt - 1` to `slashToEscrow`. Plan C's `snapshotTimestamp <= openedAt` guard is satisfied because the verdict opens after execution.

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
        OutOfAdapterOutflow,   // 1 — provable
        OraclePriceDeviation,  // 2 — assertion only
        ProposerLinkedOutflow, // 3 — assertion only
        RogueAllowance,        // 4 — provable
        DrawdownBreach         // 5 — provable (single-epoch strategies)
    }

    enum Status { None, Filed, Proven, Disputed, Failed, Settled }

    error NotExecuted();
    error WindowClosed();
    error AlreadyChallenged();
    error NothingToFreeze();
    error PredicateNotProvable();
    error PredicateNotViolated();
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
    event ChallengeProven(uint256 indexed challengeId);
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

### Task 4: The three provable predicates

**Files:**
- Modify: `src/ChallengeGame.sol`
- Test: `test/ChallengeGame.t.sol` (append)

`prove(challengeId)` is permissionless and re-derives the violation from chain state. It reverts `PredicateNotProvable` for predicates 2/3 and `PredicateNotViolated` when the check does not hold.

- **Predicate 1 — out-of-adapter outflow.** Walk the governor's stored execute calls; for each value-moving ERC20 selector (`approve` `0x095ea7b3`, `increaseAllowance` `0x39509351`, `transfer` `0xa9059cbb`, `transferFrom` `0x23b872dd` — the same four the vault's `_guardBatchCalls` gates) decode the spender/recipient and assert `TierRegistry.isAdapterAllowed(dest) == false && dest != vault`. Any such call proves the predicate.
  **Reuse the vault's argument offsets exactly:** `approve`/`increaseAllowance`/`transfer` read arg 1 at `data[4:36]`; **`transferFrom` reads `to` at `data[36:68]` (arg 2), NOT `from`.** That is the classic parser bug and PR #13's review called it out by name. Mask to 160 bits. Treat calldata shorter than the read as non-proving rather than reverting.
- **Predicate 4 — rogue allowance.** The `approve`/`increaseAllowance` subset of the same walk — strictly narrower than 1, kept distinct because §3.4 lists them separately and they carry different evidentiary weight.
- **Predicate 5 — drawdown breach (single-epoch strategies only).** `capital = governor.getCapitalSnapshot(pid)`; `realized = ISyndicateVault(vault).totalAssets()`; violation iff `capital - realized > capital * maxDrawdownBps / 10_000`. **Guard it:** revert `PredicateNotProvable` when the proposal is not yet `Settled` (nothing realized to compare against), when `maxDrawdownBps == 10_000` (§3.4: "void when the envelope is 10_000 — passive-beta mandate"), and when the strategy spanned more than one coverage epoch (needs Plan E's NAV checkpoints).

Tests must include: each provable predicate proving on a genuine violation; each *failing* to prove on a clean proposal (`PredicateNotViolated`); predicates 2/3 reverting `PredicateNotProvable`; the `maxDrawdownBps == 10_000` void case; an unsettled proposal reverting for predicate 5; and **a `transferFrom`-to-vault call NOT proving predicate 1** — pulling INTO the vault is inflow, the exact case the vault's own guard also allows, and the offsets must be right for this to pass.

- [ ] Commit: `feat(challenge): on-chain proof for the three mechanically-checkable predicates (spec 3.4)`

---

### Task 5: Dispute, resolve, slash, demote

**Files:**
- Modify: `src/ChallengeGame.sol`
- Test: `test/ChallengeGame.t.sol` (append)

- **`dispute(challengeId)`** — callable only by an accused approver of that proposal (checked against the ledger's approver list, `NotAccusedApprover` otherwise), only from `Filed` or `Proven`, and only before the auto-slash delay elapses. Pulls a counter-bond equal to the challenger's and moves to `Disputed`. **`Disputed` is terminal in this plan (D5)** — it awaits v1c, and both bonds stay escrowed.
- **`resolve(challengeId)`** — permissionless, callable once `filedAt + autoSlashDelay` has elapsed:
  - from `Proven` → **slash**: read the approver set and committed shares from the ledger, call `StakedWood.slashToEscrow(caseKey, filedAt, approvers, maxSlashBps, vault, executedAt - 1)`, demote the offending adapter via `TierRegistry.demoteByChallenge`, return the challenger's bond plus the first-detector bounty, unfreeze the coverage, status `Settled`, emit `ChallengeSettled` with the escrow's `caseId`.
  - from `Filed` (never proven, never disputed) → **fail**: forfeit the challenger's bond to the accused approvers pro-rata to committed shares, unfreeze, status `Failed`.
- Owner setters: `challengeWindow`, `autoSlashDelay`, `challengerBondBps`, `detectorBountyWood`, plus the wired addresses (governor-agnostic: ledger, tier registry, sWOOD, escrow).

Tests must include: undisputed `Proven` → slash lands in the escrow as a case pinned to `executedAt - 1` and the adapter is demoted; unproven `Filed` → challenger bond goes to the accused pro-rata; `Disputed` cannot be resolved (stays parked, both bonds held); `resolve` before the delay reverts `DelayNotElapsed`; a non-approver cannot `dispute`; coverage is unfrozen on **both** terminal paths. Plus the §4-mandated fuzz: **the game's WOOD balance always equals the bonds held for live (`Filed`/`Disputed`) challenges**, across fuzzed bond sizes and resolution orders over several concurrent challenges.

- [ ] Commit: `feat(challenge): dispute, auto-slash on undisputed proof, bond forfeiture (spec 3.4)`

---

### Task 6: End-to-end — real drain, real slash, real compensation

**Files:**
- Create: `test/ChallengeEndToEnd.t.sol`

Model the fixture on `test/CompensationEndToEnd.t.sol` (real sWOOD, registry, vault, governor, escrow) and extend it with a real `ExposureLedger`, `TierRegistry` and `ChallengeGame`, fully wired: ledger's `coverageFreezer` = game, tier registry's `authorizedDemoter` = game, sWOOD's `authorizedSlasher` = game, escrow's `authorizedFunder` = sWOOD.

Two arcs, both substantive:

1. **The full happy arc**, asserting at each stage: `propose (bond locked) → guardian approves (coverage committed) → execute → file a predicate-1 challenge (bond pulled, coverage frozen, and assert the guardian genuinely CANNOT release it) → prove → warp past the delay → resolve → guardian slashed, proceeds in the escrow as a case pinned to the pre-drain block, adapter demoted, challenger bond returned → pre-drain LPs redeem their compensation, post-drain buyer gets nothing.`
2. **The bad-faith arc:** a clean proposal challenged → `prove` reverts `PredicateNotViolated` → after the delay `resolve` forfeits the challenger's bond to the approvers and unfreezes their coverage, which they can then release normally. This is what makes the bond a real deterrent rather than a formality.

- [ ] Commit: `test: end-to-end challenge -> proof -> slash -> victim compensation`

---

### Task 7: Deploy wiring, goldens, full suite, PR

- [ ] **Deploy script.** Add `script/DeployPlanD.s.sol` following `script/DeployPlanB.s.sol`'s conventions (env-var address book, pre-flight asserts, no `--broadcast` in testing): deploy `ChallengeGame`, then wire all four roles — `ledger.setCoverageFreezer`, `tierRegistry.setAuthorizedDemoter`, `swood.setAuthorizedSlasher`, and confirm `escrow.authorizedFunder == swood`. Pre-flight assert each role is unset before wiring, and print the manual follow-ups.
- [ ] **Goldens.** `ExposureLedger` and `TierRegistry` are NOT upgradeable, so their layouts are unconstrained — but run `./script/check-layout-goldens.sh` anyway and confirm the four pinned contracts are untouched. **Inspect `git diff` and confirm no pre-existing slot moved.**
- [ ] **Full suite.** `forge test` — no new failures beyond the known baseline (22: 21 fork tests needing `--fork-url`, 1 `SetGuardianRegistry` mock issue).
- [ ] **Format.** `forge fmt && forge fmt --check`.
- [ ] **Spec status.** Update the header: v1b part 2 complete; predicates 2/3 remain assertion-only pending v1c; predicate 5 covers only single-epoch strategies pending Plan E; `authorizedSlasher` is now the ChallengeGame rather than a multisig, so a verdict on predicates 1/4/5 is finally adjudicated by code rather than governance.
- [ ] **PR** against `feat/guardian-econ-security-c`.

---

## Self-review checklist

1. **Spec coverage:** §3.4 bonded filing → Task 3. Five predicates → Task 4 (three provable) + D1 (two assertion-only, with the reason stated). Freeze scope → Task 1 + D3. Undisputed auto-slash → Task 5. Disputed → escalation → Task 5 + D5 (parks; v1c does not exist). Failed challenge forfeits to the accused → Task 5. Adapters demote only on a passed challenge → Tasks 2 + 5. §4 invariant + fuzz → Task 5.
2. **Deliberately NOT in this plan (state in the PR):** adjudication of a disputed challenge (v1c); §3.4a epoch NAV checkpointing, so predicate 5 binds only on strategies settling within one epoch (Plan E); the watchtower's funded monitoring role and §3.10's approver premium (Plan F). The first-detector bounty is *paid* here, but its funding source is Plan F's.
3. **Known gaps carried forward — name these in the PR:** predicates 2 and 3 can freeze coverage and forfeit bonds but can never slash until v1c, which is a griefing vector bounded only by the challenger bond; and because `Disputed` is terminal, a determined accused party can park a valid challenge indefinitely by posting a counter-bond. Both are direct consequences of shipping the game before the court, and neither should be discovered by a reader rather than told.
4. **Type consistency:** `approversOf(address,uint256) → (address[], uint256[])` is used identically in Tasks 1, 5, 6. `slashToEscrow`'s real arity is Plan C's post-review **six**-parameter form `(bytes32 caseKey, uint256 openedAt, address[] approvers, uint256 slashBps, address vault, uint256 snapshotTimestamp)` — the escrow address is owner-set state on `StakedWood`, NOT a parameter. `demoteByChallenge(address,bytes4)` matches Tasks 2 and 5. `Predicate` / `Status` enum member names are identical in Tasks 3, 4, 5, 6.
