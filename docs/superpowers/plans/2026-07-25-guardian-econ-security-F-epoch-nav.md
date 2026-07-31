# Plan F — Epoch NAV Checkpointing (§3.4a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make predicate 5 (drawdown breach) enforceable on strategies that outlive one coverage epoch, by checkpointing NAV at every epoch boundary, attaching liability to the guardians covering the epoch in which the breach *surfaces*, and converting expiring coverage into an orderly wind-down instead of a gap.

**Architecture:** A new non-upgradeable `CoverageEpochs` contract owns the per-strategy epoch schedule: it snapshots a baseline NAV when a proposal executes, accepts renewal commitments for epoch N+1 **strictly before** epoch N's boundary, checkpoints NAV at each boundary via the same `PriceRouter.valueStrategy` the vault's Lane A already trusts, and evaluates cumulative drawdown against the proposal's declared envelope. `ChallengeGame` learns to ask it who was covering a given epoch, so a predicate-5 challenge accuses the epoch's coverers rather than the original approvers. A strategy nobody renews is flagged for wind-down, which lets `settleProposal` be called permissionlessly ahead of `strategyDuration`.

**Tech Stack:** Solidity 0.8.28, Foundry (forge test/fmt/inspect), OpenZeppelin `Ownable2Step`, existing `IPriceRouter`, `IExposureLedger`, `ISyndicateGovernor`, `IChallengeGame`.

---

## Two facts that shape this plan

**1. `totalAssets()` is the wrong NAV source, and using it would fabricate catastrophic drawdowns.**

`SyndicateVault.totalAssets()` is `idle float + liveNav`, where `liveNav` comes from `_laneState()`:

```solidity
try IPriceRouter(pr).valueStrategy(active) returns (uint256 v, bool ok) {
    if (ok) { liveNav = v; laneA = true; }
} catch {} // fail-closed: laneA stays false
```

When the router cannot price the strategy — outage, stale feed, unsupported venue — `laneA` is false and **`liveNav` is silently 0**. That is correct for the vault (it falls back to float-only NAV and routes LP flow through the async queue), but catastrophic for a checkpoint: a checkpoint reading `totalAssets()` during a router outage would record a ~100% loss, breach the drawdown envelope, and expose honest guardians to a 100% slash over an oracle hiccup.

So `CoverageEpochs` **must call `valueStrategy` directly and refuse to checkpoint when `instantOK` is false.** Never `totalAssets()`. This is the single most important rule in this plan.

**2. Renewal-before-checkpoint closes the *jump*, not the *drift* — and the plan must say so.**

§3.4a says renewal commits before the boundary NAV "is revealed", so the exit-run failure mode is "closed by sequencing, not trust." That is true only in a narrow sense worth stating plainly, because an implementer who believes sequencing is the whole defence will size `renewalLeadTime` wrongly.

`valueStrategy` is a **public view**. A guardian can read it continuously and compute what the boundary checkpoint will almost certainly say. Sequencing therefore does *not* create real information asymmetry about a gradually deteriorating strategy — it only prevents renewing (or refusing to renew) on a **discontinuous** move landing between `renewalDeadline` and the boundary: a hack, a depeg, a liquidation cascade.

The gradual case is handled by a different mechanism, and both are needed:

| Failure | Defence |
| --- | --- |
| Bad news lands in the last hours before a boundary | **Sequencing** — renewal already closed |
| Strategy deteriorates visibly across the epoch | **Repricing** — §3.10 prices each epoch, so a riskier strategy costs more to renew; if nobody will pay, it winds down (§3.4a: "adverse-selection repricing at renewal is a feature") |

Set `renewalLeadTime` long enough that the jump window is meaningful, short enough that guardians are not committing against badly stale information. Task 4 pins it at 3 days against a 28-day epoch and tests both ends.

---

## Design decisions pinned before any code

- **D1 — NAV source is `IPriceRouter.valueStrategy(strategy)`, fail-closed on `instantOK == false`.** Never `totalAssets()`. See fact 1.
- **D2 — Baseline is the NAV at `openCover`, not at `executedAt`.** `openCover` is permissionless and may run some blocks after execution. Recording the NAV actually observed is honest; back-dating a number nobody read is not. `openCover` is callable only while the proposal is `Executed`, and the drawdown denominator is this observed baseline.
- **D3 — Epoch schedule is copied from `ExposureLedger`, not re-derived.** Read `epochLength()` and `epochGenesis()` once at `openCover` and store them on the cover. `ExposureLedger.epochLength` is immutable, but reading once means a future ledger re-point cannot retroactively re-slice a live strategy's epochs.
- **D4 — A missed checkpoint is not an acquittal.** If nobody calls `checkpoint()` at a boundary, the epoch stays uncheckpointed and the *next* checkpoint evaluates cumulative loss against the same baseline. Drawdown is measured cumulatively from baseline, never epoch-over-epoch, so skipped boundaries cannot launder a loss.
- **D5 — Passive mandates (`maxDrawdownBps == 10_000`) checkpoint but never breach.** §3.4a(c): their epochs still record NAV to feed §6 monitoring, but they carry no predicate-5 liability.
- **D6 — Unpriceable at the boundary → wind-down, after a grace window.** A checkpoint that cannot be taken because `instantOK` is false may be retried anywhere inside `checkpointGrace`. If the grace expires with no successful checkpoint, the cover is flagged `windDown`. A strategy whose value cannot be established cannot be underwritten, and the alternative — carry on uncovered — is exactly the gap §3.4a exists to prevent.
- **D7 — Wind-down seizes nothing.** It sets a flag making `settleProposal` permissionlessly callable ahead of `strategyDuration`. The existing settlement path does the unwinding. `CoverageEpochs` never moves funds; it holds no tokens at all.

---

## File structure

| File | Responsibility |
| --- | --- |
| `src/CoverageEpochs.sol` (new) | Epoch schedule, baseline + per-epoch NAV checkpoints, drawdown evaluation, renewal commitments, coverer sets, wind-down flag |
| `src/interfaces/ICoverageEpochs.sol` (new) | Errors, events, structs, external surface |
| `src/ChallengeGame.sol` (modify) | Predicate-5 challenges accuse the cited epoch's coverers |
| `src/interfaces/IChallengeGame.sol` (modify) | `file` gains an `epoch` argument |
| `src/SyndicateGovernor.sol` (modify) | `settleProposal` honours the wind-down flag |
| `src/interfaces/ISyndicateGovernor.sol` (modify) | `coverageEpochs` getter + setter declarations |
| `test/CoverageEpochs.t.sol` (new) | Unit tests |
| `test/CoverageEpochsEndToEnd.t.sol` (new) | Multi-epoch arcs against the real stack |
| `script/DeployPlanF.s.sol` (new) | Deploy + wiring with load-bearing pre-flights |

---

### Task 1: `CoverageEpochs` — cover open and baseline NAV

**Files:**
- Create: `src/interfaces/ICoverageEpochs.sol`, `src/CoverageEpochs.sol`
- Test: `test/CoverageEpochs.t.sol`

Read `src/ExposureLedger.sol`'s constructor and `currentEpoch()` for the epoch idiom, and `src/CompensationEscrow.sol` for house style (errors declared in the interface, natspec with spec-section tags, CEI).

`openCover(address governor, uint256 proposalId)` — permissionless. Reads the proposal via `ISyndicateGovernor.getProposal`, requires `state == Executed` and `strategy != address(0)`, snapshots `maxDrawdownBps`, and takes the baseline NAV from the price router. Reverts `NotExecuted`, `NoStrategy`, `AlreadyOpened`, `NavUnavailable`.

Key, mirroring `ChallengeGame._reviewKey`: `keccak256(abi.encode(governor, proposalId))`.

```solidity
struct Cover {
    address governor;
    uint256 proposalId;
    address strategy;
    uint64  openedAt;
    uint64  epochLength;    // copied from the ledger (D3)
    uint64  epochGenesis;   // copied from the ledger (D3)
    uint16  maxDrawdownBps; // snapshot (D5: 10_000 == passive)
    uint256 baselineNav;    // D2: the NAV actually observed at openCover
    uint64  lastCheckpointedEpoch;
    uint64  breachEpoch;
    bool    opened;
    bool    windDown;
    bool    breached;
}
```

- [ ] **Step 1: Write the failing tests**

```solidity
function test_openCover_snapshotsBaselineFromTheRouterNotTotalAssets() public {
    router.setValue(strategy, 1_000e18, true);
    vault.setTotalAssets(999_999e18); // must be ignored
    epochs.openCover(address(governor), pid);
    assertEq(epochs.baselineNavOf(address(governor), pid), 1_000e18, "baseline must come from valueStrategy");
}

function test_openCover_revertsWhenTheRouterCannotPrice() public {
    router.setValue(strategy, 0, false); // instantOK == false
    vm.expectRevert(ICoverageEpochs.NavUnavailable.selector);
    epochs.openCover(address(governor), pid);
}

function test_openCover_revertsBeforeExecution() public {
    governor.setState(pid, ISyndicateGovernor.ProposalState.Approved);
    vm.expectRevert(ICoverageEpochs.NotExecuted.selector);
    epochs.openCover(address(governor), pid);
}

function test_openCover_isIdempotentlyRefused() public {
    router.setValue(strategy, 1_000e18, true);
    epochs.openCover(address(governor), pid);
    vm.expectRevert(ICoverageEpochs.AlreadyOpened.selector);
    epochs.openCover(address(governor), pid);
}

function test_openCover_copiesTheLedgerEpochSchedule() public {
    router.setValue(strategy, 1_000e18, true);
    epochs.openCover(address(governor), pid);
    assertEq(epochs.epochLengthOf(address(governor), pid), ledger.epochLength());
    assertEq(epochs.epochGenesisOf(address(governor), pid), ledger.epochGenesis());
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `forge test --match-contract CoverageEpochs -vv`
Expected: FAIL — `CoverageEpochs` does not exist.

- [ ] **Step 3: Implement `openCover`**

```solidity
function openCover(address governor, uint256 proposalId) external {
    bytes32 key = _coverKey(governor, proposalId);
    Cover storage c = _covers[key];
    if (c.opened) revert AlreadyOpened();

    ISyndicateGovernor.StrategyProposal memory p =
        ISyndicateGovernor(governor).getProposal(proposalId);
    if (p.state != ISyndicateGovernor.ProposalState.Executed) revert NotExecuted();
    if (p.strategy == address(0)) revert NoStrategy();

    // D1: the router, never totalAssets() — a router outage reports float-only
    // NAV, which as a checkpoint would fabricate a ~100% loss and slash honest
    // guardians for an oracle hiccup.
    (uint256 nav, bool ok) = IPriceRouter(priceRouter).valueStrategy(p.strategy);
    if (!ok) revert NavUnavailable();

    c.governor = governor;
    c.proposalId = proposalId;
    c.strategy = p.strategy;
    c.openedAt = uint64(block.timestamp);
    c.epochLength = uint64(exposureLedger.epochLength());
    c.epochGenesis = uint64(exposureLedger.epochGenesis());
    c.maxDrawdownBps = p.maxDrawdownBps;
    c.baselineNav = nav;
    c.opened = true;

    emit CoverOpened(key, governor, proposalId, p.strategy, nav, c.maxDrawdownBps);
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `forge test --match-contract CoverageEpochs -vv`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/CoverageEpochs.sol src/interfaces/ICoverageEpochs.sol test/CoverageEpochs.t.sol
git commit -m "feat(epochs): cover open with a router-sourced baseline NAV (spec 3.4a)"
```

---

### Task 2: Boundary checkpointing

**Files:**
- Modify: `src/CoverageEpochs.sol`, `src/interfaces/ICoverageEpochs.sol`
- Test: `test/CoverageEpochs.t.sol` (append)

`checkpoint(governor, proposalId)` — permissionless, once per epoch, only at or after that epoch's boundary. Records the NAV and advances `lastCheckpointedEpoch`.

Epoch of a timestamp, from the cover's own copied schedule: `(ts - epochGenesis) / epochLength`.

- [ ] **Step 1: Write the failing tests**

```solidity
function test_checkpoint_revertsBeforeTheBoundary() public {
    _open();
    vm.expectRevert(ICoverageEpochs.BoundaryNotReached.selector);
    epochs.checkpoint(address(governor), pid);
}

function test_checkpoint_recordsNavAtTheBoundary() public {
    _open();
    _warpToEpochBoundary(1);
    router.setValue(strategy, 900e18, true);
    epochs.checkpoint(address(governor), pid);
    assertEq(epochs.navAt(address(governor), pid, 0), 900e18);
}

function test_checkpoint_cannotRunTwiceForOneEpoch() public {
    _open();
    _warpToEpochBoundary(1);
    epochs.checkpoint(address(governor), pid);
    vm.expectRevert(ICoverageEpochs.AlreadyCheckpointed.selector);
    epochs.checkpoint(address(governor), pid);
}

function test_checkpoint_revertsWhenTheRouterCannotPrice() public {
    _open();
    _warpToEpochBoundary(1);
    router.setValue(strategy, 0, false);
    vm.expectRevert(ICoverageEpochs.NavUnavailable.selector);
    epochs.checkpoint(address(governor), pid);
}

/// D4: a skipped boundary must not launder a loss. Miss epoch 0 entirely,
/// checkpoint during epoch 2, and the loss must still measure from BASELINE.
function test_checkpoint_missedBoundaryStillMeasuresFromBaseline() public {
    _open(); // baseline 1_000e18
    _warpToEpochBoundary(2);
    router.setValue(strategy, 700e18, true);
    epochs.checkpoint(address(governor), pid);
    assertEq(epochs.cumulativeLossBps(address(governor), pid), 3_000);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `forge test --match-test test_checkpoint -vv`
Expected: FAIL — `checkpoint` undefined.

- [ ] **Step 3: Implement**

```solidity
function checkpoint(address governor, uint256 proposalId) external {
    bytes32 key = _coverKey(governor, proposalId);
    Cover storage c = _covers[key];
    if (!c.opened) revert NotOpened();

    uint256 due = c.lastCheckpointedEpoch;
    // The epoch being closed must be strictly behind us — `due`'s boundary is
    // the START of epoch `due + 1`.
    if (block.timestamp < _boundary(c, due + 1)) revert BoundaryNotReached();
    if (_checkpointed[key][due]) revert AlreadyCheckpointed();

    (uint256 nav, bool ok) = IPriceRouter(priceRouter).valueStrategy(c.strategy);
    if (!ok) revert NavUnavailable();

    _nav[key][due] = nav;
    _checkpointed[key][due] = true;
    c.lastCheckpointedEpoch = uint64(due + 1);
    _lastNav[key] = nav;

    emit Checkpointed(key, due, nav, cumulativeLossBps(governor, proposalId));
}

/// @notice Cumulative loss from BASELINE in bps (D4). Zero when NAV >= baseline.
///         Cumulative, never epoch-over-epoch: a skipped boundary must not let
///         a loss be laundered by re-baselining against the depressed value.
function cumulativeLossBps(address governor, uint256 proposalId) public view returns (uint256) {
    bytes32 key = _coverKey(governor, proposalId);
    Cover storage c = _covers[key];
    if (!c.opened || c.baselineNav == 0) return 0;
    uint256 last = _lastNav[key];
    if (last >= c.baselineNav) return 0;
    return ((c.baselineNav - last) * BPS_DENOMINATOR) / c.baselineNav;
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `forge test --match-contract CoverageEpochs -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add -A && git commit -m "feat(epochs): boundary NAV checkpoints measured cumulatively from baseline (spec 3.4a)"
```

---

### Task 3: Drawdown evaluation and the passive-mandate skip

**Files:**
- Modify: `src/CoverageEpochs.sol`, `src/interfaces/ICoverageEpochs.sol`
- Test: `test/CoverageEpochs.t.sol` (append)

A checkpoint whose `cumulativeLossBps` exceeds `maxDrawdownBps` sets `breached = true`, records `breachEpoch`, and emits `DrawdownBreached(key, epoch, lossBps, maxDrawdownBps)` — the event watchtowers file predicate 5 against.

**D5: `maxDrawdownBps == 10_000` never breaches.** A passive mandate declared the whole notional as its envelope; it still checkpoints (feeding §6 monitoring) but carries no predicate-5 liability. Give it its own branch and its own test — silently letting `10_000 > 10_000` fail the comparison is the same behaviour by accident, and an accident is not a documented property.

- [ ] **Step 1: Write the failing tests**

```solidity
function test_breach_setsTheFlagAndEmits() public {
    _openWithEnvelope(2_000); // 20%
    _warpToEpochBoundary(1);
    router.setValue(strategy, 700e18, true); // 30% loss
    vm.expectEmit(true, true, true, true);
    emit ICoverageEpochs.DrawdownBreached(_key(), 0, 3_000, 2_000);
    epochs.checkpoint(address(governor), pid);
    assertTrue(epochs.breached(address(governor), pid));
}

function test_lossInsideTheEnvelopeDoesNotBreach() public {
    _openWithEnvelope(2_000);
    _warpToEpochBoundary(1);
    router.setValue(strategy, 850e18, true); // 15% < 20%
    epochs.checkpoint(address(governor), pid);
    assertFalse(epochs.breached(address(governor), pid));
}

function test_lossExactlyAtTheEnvelopeDoesNotBreach() public {
    _openWithEnvelope(2_000);
    _warpToEpochBoundary(1);
    router.setValue(strategy, 800e18, true); // exactly 20%
    epochs.checkpoint(address(governor), pid);
    assertFalse(epochs.breached(address(governor), pid), "breach must be strictly greater");
}

/// D5 — the passive mandate. Total loss, no breach, NAV still recorded.
function test_passiveMandateCheckpointsButNeverBreaches() public {
    _openWithEnvelope(10_000);
    _warpToEpochBoundary(1);
    router.setValue(strategy, 1, true); // ~100% loss
    epochs.checkpoint(address(governor), pid);
    assertFalse(epochs.breached(address(governor), pid));
    assertEq(epochs.navAt(address(governor), pid, 0), 1, "NAV still feeds monitoring");
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `forge test --match-test "test_breach|test_loss|test_passive" -vv`
Expected: FAIL.

- [ ] **Step 3: Implement — append to `checkpoint`**

```solidity
// D5: a passive mandate (envelope 10_000) declared the full notional. It
// checkpoints so §6 monitoring sees the NAV, but it can never breach. The
// early return is deliberate — relying on `lossBps > 10_000` being
// unreachable would be the same behaviour by accident.
if (c.maxDrawdownBps >= BPS_DENOMINATOR) return;

uint256 lossBps = cumulativeLossBps(governor, proposalId);
if (lossBps > c.maxDrawdownBps && !c.breached) {
    c.breached = true;
    c.breachEpoch = uint64(due);
    emit DrawdownBreached(key, due, lossBps, c.maxDrawdownBps);
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `forge test --match-contract CoverageEpochs -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add -A && git commit -m "feat(epochs): per-epoch drawdown evaluation with the passive-mandate skip (spec 3.4a)"
```

---

### Task 4: Renewal, and the sequencing that closes the exit run

**Files:**
- Modify: `src/CoverageEpochs.sol`, `src/interfaces/ICoverageEpochs.sol`
- Test: `test/CoverageEpochs.t.sol` (append)

`commitRenewal(governor, proposalId, epoch)` — a guardian commits to cover `epoch`. Accepted only while `block.timestamp < renewalDeadline(epoch)`, where:

```
boundary(epoch)        = epochGenesis + epoch * epochLength
renewalDeadline(epoch) = boundary(epoch) - renewalLeadTime
```

`renewalLeadTime` is owner-set, default **3 days**, bounded `(0, epochLength / 2]`. Read fact 2 before changing it: sequencing closes the *jump* window only, and a lead time approaching the epoch length would have guardians committing against badly stale information — a different failure, not a stronger defence.

The commitment calls `exposureLedger.recordApproval(governor, proposalId, guardian)` so it consumes the same aggregate exposure cap a fresh approval would. A guardian without capacity cannot renew — that is the point.

- [ ] **Step 1: Write the failing tests**

```solidity
function test_renewal_acceptedBeforeTheDeadline() public {
    _open();
    vm.warp(epochs.renewalDeadline(address(governor), pid, 1) - 1);
    vm.prank(guardianA);
    epochs.commitRenewal(address(governor), pid, 1);
    assertEq(epochs.coverersOf(address(governor), pid, 1).length, 1);
}

/// THE SEQUENCING TEST. After the deadline — even one second before the
/// boundary, when the NAV is visibly cratering — renewal is closed. This is
/// what stops the last-moment exit run.
function test_renewal_refusedAfterTheDeadlineEvenBeforeTheBoundary() public {
    _open();
    vm.warp(epochs.renewalDeadline(address(governor), pid, 1) + 1);
    router.setValue(strategy, 1e18, true); // visibly catastrophic
    vm.prank(guardianA);
    vm.expectRevert(ICoverageEpochs.RenewalClosed.selector);
    epochs.commitRenewal(address(governor), pid, 1);
}

function test_checkpointCannotPrecedeTheRenewalDeadline() public {
    _open();
    vm.warp(epochs.renewalDeadline(address(governor), pid, 1));
    vm.expectRevert(ICoverageEpochs.BoundaryNotReached.selector);
    epochs.checkpoint(address(governor), pid);
}

function test_renewal_consumesExposureCapacity() public {
    _open();
    uint256 before = ledger.openExposureUsd(guardianA);
    vm.prank(guardianA);
    epochs.commitRenewal(address(governor), pid, 1);
    assertGt(ledger.openExposureUsd(guardianA), before, "renewal must book exposure");
}

function test_renewal_doubleCommitReverts() public {
    _open();
    vm.startPrank(guardianA);
    epochs.commitRenewal(address(governor), pid, 1);
    vm.expectRevert(ICoverageEpochs.AlreadyCommitted.selector);
    epochs.commitRenewal(address(governor), pid, 1);
    vm.stopPrank();
}

function test_renewalLeadTime_boundedAndOwnerOnly() public {
    vm.prank(stranger);
    vm.expectRevert();
    epochs.setRenewalLeadTime(1 days);

    uint256 half = ledger.epochLength() / 2;
    vm.startPrank(owner);
    vm.expectRevert(ICoverageEpochs.InvalidParameter.selector);
    epochs.setRenewalLeadTime(0);
    vm.expectRevert(ICoverageEpochs.InvalidParameter.selector);
    epochs.setRenewalLeadTime(half + 1);
    epochs.setRenewalLeadTime(half); // the boundary itself is legal
    vm.stopPrank();
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `forge test --match-test "test_renewal|test_checkpointCannot" -vv`
Expected: FAIL.

- [ ] **Step 3: Implement**

```solidity
/// @notice The instant renewal for `epoch` closes. Deliberately BEFORE the
///         boundary: this closes the DISCONTINUOUS exit run (a hack landing in
///         the last hours). Gradual deterioration is handled by repricing at
///         renewal (§3.10), NOT by this deadline — `valueStrategy` is a public
///         view, so a guardian can watch a slow decline in real time and this
///         deadline buys nothing against it.
function renewalDeadline(address governor, uint256 proposalId, uint256 epoch)
    public view returns (uint256)
{
    Cover storage c = _covers[_coverKey(governor, proposalId)];
    return _boundary(c, epoch) - renewalLeadTime;
}

function commitRenewal(address governor, uint256 proposalId, uint256 epoch) external {
    bytes32 key = _coverKey(governor, proposalId);
    Cover storage c = _covers[key];
    if (!c.opened) revert NotOpened();
    if (c.windDown) revert WoundDown();
    if (epoch == 0) revert InvalidParameter(); // epoch 0 is the original approval
    if (block.timestamp >= renewalDeadline(governor, proposalId, epoch)) revert RenewalClosed();
    if (_committed[key][epoch][msg.sender]) revert AlreadyCommitted();

    _committed[key][epoch][msg.sender] = true;
    _coverers[key][epoch].push(msg.sender);

    // The commitment books real exposure against the same aggregate cap a
    // fresh approval consumes — a guardian with no capacity cannot renew.
    exposureLedger.recordApproval(governor, proposalId, msg.sender);

    emit RenewalCommitted(key, epoch, msg.sender);
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `forge test --match-contract CoverageEpochs -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add -A && git commit -m "feat(epochs): renewal commitments sequenced ahead of the boundary checkpoint (spec 3.4a)"
```

---

### Task 5: Claims-made attribution

**Files:**
- Modify: `src/CoverageEpochs.sol`, `src/interfaces/ICoverageEpochs.sol`
- Test: `test/CoverageEpochs.t.sol` (append)

`coverersOf(governor, proposalId, epoch)` returns who answers for a breach surfacing in that epoch:

- **Epoch 0** — the original approvers from `exposureLedger.approversOf`, filtered to non-zero `committedUsd` **exactly as `ChallengeGame._accused` does**. Mirror that filter; do not invent a second notion of "covering".
- **Epoch N > 0** — the guardians who committed renewal for epoch N.

This is the point of §3.4a: liability attaches to the watch it surfaced on, so no guardian is committed longer than one epoch + challenge window however long the strategy runs.

- [ ] **Step 1: Write the failing tests**

```solidity
function test_epochZeroCoverersAreTheOriginalApprovers() public {
    _open(); // guardianA and guardianB approved
    assertEq(epochs.coverersOf(address(governor), pid, 0).length, 2);
}

function test_laterEpochCoverersAreTheRenewers() public {
    _open();
    vm.prank(guardianC);
    epochs.commitRenewal(address(governor), pid, 1);
    address[] memory cov = epochs.coverersOf(address(governor), pid, 1);
    assertEq(cov.length, 1);
    assertEq(cov[0], guardianC, "epoch 1 is guardianC's watch");
}

/// The core claims-made property: an original approver who did not renew
/// answers for NOTHING that surfaces after its own epoch.
function test_originalApproverIsNotLiableForALaterEpoch() public {
    _open();
    vm.prank(guardianC);
    epochs.commitRenewal(address(governor), pid, 1);
    address[] memory cov = epochs.coverersOf(address(governor), pid, 1);
    for (uint256 i = 0; i < cov.length; i++) {
        assertNotEq(cov[i], guardianA, "guardianA's watch ended at epoch 0");
    }
}

function test_releasedApproverIsNotACoverer() public {
    _open();
    vm.prank(address(governor));
    ledger.releaseApproval(address(governor), pid, guardianB);
    address[] memory cov = epochs.coverersOf(address(governor), pid, 0);
    for (uint256 i = 0; i < cov.length; i++) {
        assertNotEq(cov[i], guardianB, "a zero committed share is not coverage");
    }
}

function test_breachEpochIsRecorded() public {
    _openWithEnvelope(2_000);
    _warpToEpochBoundary(2);
    router.setValue(strategy, 700e18, true);
    epochs.checkpoint(address(governor), pid);
    assertEq(epochs.breachEpochOf(address(governor), pid), 0, "epoch 0 was the watch that closed");
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `forge test --match-test "test_epochZero|test_later|test_original|test_released|test_breachEpoch" -vv`
Expected: FAIL.

- [ ] **Step 3: Implement**

```solidity
/// @notice §3.4a claims-made attribution: liability for a breach surfacing in
///         epoch N attaches to the guardians covering epoch N, NOT to epoch 0's
///         approvers (who may have exited). This bounds a guardian's commitment
///         at one epoch + challenge window however long the strategy runs —
///         the entire reason epochs exist.
function coverersOf(address governor, uint256 proposalId, uint256 epoch)
    public view returns (address[] memory)
{
    if (epoch == 0) {
        (address[] memory all, uint256[] memory committedUsd) =
            exposureLedger.approversOf(governor, proposalId);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            if (committedUsd[i] != 0) n++;
        }
        address[] memory out = new address[](n);
        uint256 j;
        for (uint256 i = 0; i < all.length; i++) {
            if (committedUsd[i] == 0) continue;
            out[j] = all[i];
            j++;
        }
        return out;
    }
    return _coverers[_coverKey(governor, proposalId)][epoch];
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `forge test --match-contract CoverageEpochs -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add -A && git commit -m "feat(epochs): claims-made attribution to the covering epoch (spec 3.4a)"
```

---

### Task 6: No renewal → forced wind-down

**Files:**
- Modify: `src/CoverageEpochs.sol`, `src/interfaces/ICoverageEpochs.sol`, `src/SyndicateGovernor.sol`, `src/interfaces/ISyndicateGovernor.sol`
- Test: `test/CoverageEpochs.t.sol` (append)

`flagWindDown(governor, proposalId)` — permissionless, callable once a boundary has passed with **no coverers committed for the epoch now beginning**, or once `checkpointGrace` has expired with no successful checkpoint (D6).

Then `SyndicateGovernor.settleProposal` honours it. Today settle is "proposer any time after 1h; anyone after `strategyDuration`". Wind-down makes it **permissionless immediately** — an uninsurable strategy must not have to run its full term.

**Storage-layout warning:** `SyndicateGovernor` is beacon-upgradeable with golden-pinned layout. Add `_coverageEpochs` as an **append-only** field carved from `__gap`, exactly as Plan B added `_exposureLedger` and `_bondEscrow`. Run `./script/check-layout-goldens.sh` before committing and update the pinned JSON in the same commit.

- [ ] **Step 1: Write the failing tests**

```solidity
function test_windDown_flaggedWhenNobodyRenewed() public {
    _open();
    _warpToEpochBoundary(1);
    epochs.flagWindDown(address(governor), pid);
    assertTrue(epochs.windDownRequired(address(governor), pid));
}

function test_windDown_refusedWhileCoverageExists() public {
    _open();
    vm.prank(guardianC);
    epochs.commitRenewal(address(governor), pid, 1);
    _warpToEpochBoundary(1);
    vm.expectRevert(ICoverageEpochs.StillCovered.selector);
    epochs.flagWindDown(address(governor), pid);
}

/// D6 — an unpriceable strategy cannot be underwritten.
function test_windDown_flaggedWhenNavStaysUnavailablePastTheGrace() public {
    _open();
    vm.prank(guardianC);
    epochs.commitRenewal(address(governor), pid, 1);
    _warpToEpochBoundary(1);
    router.setValue(strategy, 0, false);
    vm.warp(vm.getBlockTimestamp() + epochs.checkpointGrace() + 1);
    epochs.flagWindDown(address(governor), pid);
    assertTrue(epochs.windDownRequired(address(governor), pid));
}

function test_settleProposal_isPermissionlessOnceWoundDown() public {
    _open();
    _warpToEpochBoundary(1);
    epochs.flagWindDown(address(governor), pid);
    vm.prank(stranger); // not the proposer, well before strategyDuration
    governor.settleProposal(pid);
    assertEq(
        uint256(governor.getProposal(pid).state),
        uint256(ISyndicateGovernor.ProposalState.Settled)
    );
}

function test_settleProposal_stillGatedWithoutWindDown() public {
    _open();
    vm.prank(stranger);
    vm.expectRevert();
    governor.settleProposal(pid);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `forge test --match-test "test_windDown|test_settleProposal" -vv`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `CoverageEpochs`:

```solidity
/// @dev §3.4a's clearinghouse close-out rule: expiring coverage converts to an
///      orderly exit, never a gap. D7 — this seizes nothing and moves no funds;
///      it only unlocks the settlement path that already exists.
function flagWindDown(address governor, uint256 proposalId) external {
    bytes32 key = _coverKey(governor, proposalId);
    Cover storage c = _covers[key];
    if (!c.opened) revert NotOpened();
    if (c.windDown) revert AlreadyWoundDown();

    uint256 nowEpoch = _epochAt(c, block.timestamp);
    if (nowEpoch == 0) revert BoundaryNotReached();

    bool uncovered = _coverers[key][nowEpoch].length == 0;
    bool stale = !_checkpointed[key][nowEpoch - 1]
        && block.timestamp > _boundary(c, nowEpoch) + checkpointGrace;
    if (!uncovered && !stale) revert StillCovered();

    c.windDown = true;
    emit WindDownFlagged(key, nowEpoch, uncovered, stale);
}
```

In `SyndicateGovernor.settleProposal`, before the existing caller/timing gate:

```solidity
// §3.4a: a strategy nobody renewed, or one whose NAV cannot be established,
// unwinds at the boundary rather than running uncovered to term. Wind-down
// makes settle permissionless immediately.
bool woundDown = _coverageEpochs != address(0)
    && ICoverageEpochs(_coverageEpochs).windDownRequired(address(this), proposalId);
```

Admit the caller when `woundDown` is true, bypassing the `strategyDuration` wait.

- [ ] **Step 4: Run tests and the layout goldens**

```bash
forge test --match-contract "CoverageEpochs|Governor" -vv
./script/check-layout-goldens.sh
```
Expected: tests PASS; goldens report the appended field, and you update the pinned JSON in this commit.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add -A && git commit -m "feat(epochs): forced wind-down when coverage lapses or NAV is unavailable (spec 3.4a)"
```

---

### Task 7: `ChallengeGame` accuses the epoch's coverers

**Files:**
- Modify: `src/ChallengeGame.sol`, `src/interfaces/IChallengeGame.sol`
- Test: `test/ChallengeGame.t.sol` (append)

`file` gains an `epoch` argument. For `Predicate.Drawdown` (predicate 5) with `epoch > 0`, the accused set comes from `CoverageEpochs.coverersOf(governor, proposalId, epoch)` instead of `exposureLedger.approversOf`. Every other predicate, and `epoch == 0`, keeps today's behaviour exactly.

**Read `_accused` and all its callers before changing anything.** Plan E's Task 1 found `_settle` was correct only because of *which states could reach it*; widening a helper without re-deriving its invariants stranded funds. `_accused` feeds slashing, the failed-challenge forfeit split, and the coverage freeze — check all three.

Guard it: a cited epoch with no coverers must revert `NoCoverage` rather than produce an empty accused set. An empty set means nobody is slashed and the challenger's bond returns through the defensive branch — a silent no-op challenge.

- [ ] **Step 1: Write the failing tests**

```solidity
function test_file_drawdownEpochAccusesTheEpochCoverers() public {
    _executeAndOpenCover();
    vm.prank(guardianC);
    epochs.commitRenewal(address(governor), pid, 1);
    _warpToEpochBoundary(1);

    uint256 id = _file(IChallengeGame.Predicate.Drawdown, 1);
    address[] memory accused = game.accusedOf(id);
    assertEq(accused.length, 1);
    assertEq(accused[0], guardianC);
}

function test_file_epochZeroKeepsLedgerBehaviour() public {
    _executeAndOpenCover();
    uint256 id = _file(IChallengeGame.Predicate.Drawdown, 0);
    assertEq(game.accusedOf(id).length, 2, "original approvers");
}

function test_file_nonDrawdownPredicateIgnoresTheEpoch() public {
    _executeAndOpenCover();
    uint256 id = _file(IChallengeGame.Predicate.UnauthorizedVenue, 1);
    assertEq(game.accusedOf(id).length, 2, "only predicate 5 is epoch-scoped");
}

function test_file_revertsWhenTheCitedEpochHasNoCoverers() public {
    _executeAndOpenCover();
    _warpToEpochBoundary(1);
    vm.expectRevert(IChallengeGame.NoCoverage.selector);
    _file(IChallengeGame.Predicate.Drawdown, 1);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `forge test --match-test test_file_ -vv`
Expected: FAIL — `file` arity.

- [ ] **Step 3: Implement**

Thread `epoch` onto the `Challenge` struct and branch inside `_accused`:

```solidity
// §3.4a claims-made: only the drawdown predicate is epoch-scoped, because only
// it can surface on a later watch than the approval it came from. Epoch 0 keeps
// the ledger path so every pre-Plan-F challenge behaves identically.
if (predicate == Predicate.Drawdown && epoch != 0 && coverageEpochs != address(0)) {
    address[] memory cov = ICoverageEpochs(coverageEpochs).coverersOf(governor, proposalId, epoch);
    if (cov.length == 0) revert NoCoverage();
    return cov;
}
```

- [ ] **Step 4: Run the full challenge and court suites**

Run: `forge test --match-contract "ChallengeGame|Court|ChallengeEndToEnd|CourtEndToEnd"`
Expected: PASS — every existing test unregressed.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add -A && git commit -m "feat(challenge): predicate 5 accuses the covering epoch's guardians (spec 3.4a)"
```

---

### Task 8: End-to-end, deploy wiring, goldens, PR

**Files:**
- Create: `test/CoverageEpochsEndToEnd.t.sol`, `script/DeployPlanF.s.sol`

- [ ] **Step 1: Three end-to-end arcs against the real stack**

Extend `test/CourtEndToEnd.t.sol`'s fixture (real sWOOD, registry, vault, governor, ledger, tier registry, both escrows, `ChallengeGame`, `Court`) with a real `CoverageEpochs`.

1. **Renewed, breach surfaces in a later epoch → that epoch's coverers slashed, epoch 0's approvers untouched.** The arc that proves claims-made attribution end-to-end, and the one justifying this whole plan.
2. **Nobody renews → wind-down → permissionless settle before `strategyDuration`.**
3. **Router outage past the grace → wind-down, and NO breach recorded** — proving fact 1: an unpriceable strategy is wound down, never slashed for a fabricated loss.

- [ ] **Step 2: Deploy script with load-bearing pre-flights**

Follow `script/DeployPlanE.s.sol`, including its **two-script split** (deploy inert, wire separately) if any pre-flight depends on guardians having acted first. Pre-flights:

- `governor.coverageEpochs() == address(0)` — do not steal the role from a live instance
- `priceRouter != address(0)` **and** `valueStrategy` answers `ok == true` for a known strategy — a router that cannot price makes every checkpoint revert and every cover wind down
- `exposureLedger` matches the one `ChallengeGame` uses — two ledgers means two different accused sets
- `renewalLeadTime > 0 && renewalLeadTime <= epochLength / 2` — a zero lead time silently deletes the sequencing property
- `checkpointGrace < epochLength` — a grace longer than an epoch means the wind-down flag can never fire

**Break each deliberately and prove it bites**, matching Plan E's bar.

- [ ] **Step 3: Goldens, full suite, fmt**

```bash
./script/check-layout-goldens.sh   # SyndicateGovernor CHANGED — update the pinned JSON
forge test                          # no new failures beyond the documented 22 baseline
forge fmt && forge fmt --check
```

`CoverageEpochs` is not upgradeable, so no golden covers it — say that plainly rather than implying it was checked.

- [ ] **Step 4: Spec status header**

Mark §3.4a complete in `docs/superpowers/specs/2026-07-22-guardian-economic-security-design.md`. Note Plan G (§3.10 premium + watchtower funding) remains, and that **mid-epoch exit (loss-portfolio transfer) is deferred to v2** per §3.4a.

- [ ] **Step 5: PR against `feat/guardian-econ-security-e`**

Known gaps the PR must name:

1. **Sequencing closes the jump, not the drift** — `valueStrategy` is a public view, so a guardian can watch a slow decline and decline to renew. Repricing (§3.10, Plan G) is the intended answer and is **not built yet**, so until Plan G ships a deteriorating strategy is renewed at a flat price or not at all.
2. **`openCover` is permissionless and unforced.** Nothing compels anyone to open a cover; an unopened strategy has no checkpoints and no epoch liability. Consider having execution call it in a later plan.
3. **Checkpoints are permissionless and unpaid** — the same liveness problem as the court panel. A missed boundary is not an acquittal (D4), but it does delay breach surfacing.
4. **Baseline is the NAV at `openCover`, not at execution** (D2) — a cover opened late bakes in any drift since execution.
5. **Wind-down does not force liquidation** — it only unlocks permissionless settle. Someone must still call it.

---

## Self-review checklist

- [ ] Every NAV read uses `valueStrategy` and fails closed on `instantOK == false`; `totalAssets()` appears nowhere in `CoverageEpochs`
- [ ] Drawdown is cumulative from baseline on every path, so a skipped boundary cannot launder a loss (D4)
- [ ] The passive-mandate skip is an explicit branch with its own test, not an accident of the comparison (D5)
- [ ] Renewal provably closes before the boundary, tested at the exact second (fact 2)
- [ ] Epoch 0 attribution filters zero-`committedUsd` approvers exactly as `ChallengeGame._accused` does — one definition of "covering", not two
- [ ] `SyndicateGovernor`'s new field is append-only from `__gap` and the golden JSON is updated in the same commit
- [ ] Every pre-existing `ChallengeGame` / `Court` test passes unchanged
