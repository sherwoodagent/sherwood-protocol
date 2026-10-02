# Design — propose-time target validation (issue #118)

## Context

`_guardBatchCalls` (src/SyndicateVault.sol:590-643) does two separable things:

1. **Part 1 — unconditional privileged-target denylist.** Rejects any call whose `target` is `address(this)` (the vault) or `_withdrawalQueue`. Runs before, and independent of, everything else — including both degrade-open returns of Part 2. No registry, no configuration, no mutable inputs beyond the queue binding itself, which is factory-only and set-once (src/SyndicateVault.sol:427-434, `WithdrawalQueueAlreadySet`).
2. **Part 2 — registry-gated value-moving-selector gate.** Resolves the calling governor's `tierRegistry()` by staticcall (degrading open when the getter is missing or the registry unset) and checks the spender/recipient of the four guarded ERC20 selectors against `isAdapterAllowed`.

The guard runs only inside `executeGovernorBatch`. `propose` stores both call arrays without looking at their targets, so a violation is discovered a full lifecycle later — at `settleProposal`, where it is terminal (see proposal.md's asymmetry derivation).

## Decision 1 — the predicate lives on the vault, exposed as a view; the governor never restates it

**Decision:** extract Part 1's membership test into one internal function on the vault (`_isPrivilegedBatchTarget(address) → bool`), keep `_guardBatchCalls` Part 1 looping over that internal, and expose it as a new external view `isPrivilegedBatchTarget(address)` on `ISyndicateVault`. `propose` loops over both call arrays and asks the vault, reverting `ISyndicateVault.DisallowedBatchTarget(target)` on a hit — the same error, for the same violation, as the execution-time guard.

**Why not duplicate the denylist in the governor?** It is tempting: `withdrawalQueue()` and the vault address are both already visible to the governor, so a governor-side `target == vault || target == queue` needs no vault change at all. But that plants the same security predicate in two contracts, and duplicated security predicates drift — specifically, the vault's own guard documentation insists Part 1 is "a target CLASS, not a selector list" whose breadth is expected to grow (src/SyndicateVault.sol comment block above :590). The day a third privileged address joins the class in `_guardBatchCalls`, a governor-side copy silently reverts to today's two-address list, and the propose-time check starts approving proposals the settle-time guard will kill — recreating exactly the defect this change exists to close, with the added insult that the code *looks* fixed. Single-sourcing on the vault makes that divergence structurally impossible: there is one predicate body; the view and the guard are two callers of it.

**Why the vault and not a shared library?** The predicate is defined by vault state (`address(this)`, `_withdrawalQueue`). A library would still need the vault to supply both addresses, which reduces to the duplication case with extra steps.

**Mixed-version safety — degrade open, never fail closed at propose.** If the governor is upgraded before the vault (or against a vault that is never upgraded), a typed call to a nonexistent view would make *every* `propose` revert — a fail-early check must never become a fail-always check. `propose` therefore consumes the view by staticcall and skips the propose-time check when the call fails or returns malformed data, mirroring the repo's established pattern (the vault's own `tierRegistry()` staticcall probe in `_guardBatchCalls`). The safety argument does not depend on the propose-time check existing at all: `_guardBatchCalls` at `executeGovernorBatch` remains the authoritative enforcement on every batch path, exactly as today. The propose-time check is failure-locality, not the security boundary.

**Error choice.** Reusing `DisallowedBatchTarget` (declared on `ISyndicateVault`, importable by the governor) keeps one error per violation class and lets the moved test assertions keep their exact revert bytes. A distinct governor-side error was considered for observability (propose-time vs batch-time rejection) and rejected: the call context already disambiguates, and a second selector for the same violation is one more thing to keep aligned.

**Bytecode.** The view adds a small amount of vault code. The deployment target is Robinhood Chain 4663 (MaxCodeSize 98,304 bytes; vault ~25.6 KB — enormous margin). The legacy Base (8453) vault sits 18 bytes under the 24,576 EIP-170 limit and cannot take this or any upgrade; it is out of scope by standing decision (Robinhood-only stack).

## Decision 2 — propose validates the denylist half only; checking the registry half would manufacture false completeness

**Decision:** the propose-time check covers exactly Part 1. Part 2 is deliberately not evaluated at propose.

The two halves differ in the one property that matters for a propose-time check: **whether propose-time truth survives to settle time.**

- **Part 1 is deterministic across the proposal's lifetime.** The vault address cannot change. `setWithdrawalQueue` is factory-only, set-once, and called by `SyndicateFactory.createSyndicate` immediately after init — before any proposal can exist. A target that violates the denylist at propose violates it at settle, and vice versa. (Completeness edge: if a vault somehow had no queue bound at propose, the propose-time check passes queue-less targets — and so does the settle-time guard, which also skips the queue clause when `q == address(0)`. Parity holds in both directions.)
- **Part 2 is a function of mutable, even *stateless-mutable*, inputs.** `_demote` clears allowlist entries between propose and settle. PR #149 (issue #137) makes `isAdapterAllowed` codehash-aware, so an adapter flips from allowed to not-allowed **with no state write at all** — a propose-time pass over the registry half is stale the moment the adapter self-destructs, upgrades, or gets re-certified. A green check at propose would invite exactly the wrong inference ("the batch was validated"), while the actual enforcement still happens — and can still fail — at execute/settle. The execute path already handles the mutable-state problem the right way: `executeProposal` *re-resolves* tier and coverage live and refuses on regression (`TierRegressed` / `CoverageRegressed`, src/SyndicateGovernor.sol:400-410). Re-checking mutable state at the moment of use is correct; pre-checking it at propose is theater.

So the unconditional denylist is not just the cheap subset — it is the *entire* correct scope for a propose-time check. Everything propose can truthfully promise, it now promises; everything it cannot, it leaves to the layer that can.

## executeCalls get the same treatment

Verified asymmetry (details in proposal.md): a poisoned execute leg self-heals through `Approved → Expired` + `_decOpen` (src/ProposalLifecycle.sol:109, :208-210); a poisoned settlement leg permanently strands `Executed` with `redemptionsLocked()` true. Only the settlement leg is a defect. Both arrays are validated anyway: the loop is identical, the bound is the same `MAX_CALLS_PER_PROPOSAL` (64+64 targets, view calls on a cold path — gas is irrelevant), and validating both keeps the invariant statable in one sentence: **no stored proposal ever names a privileged target.** A half-invariant ("settlement calls never do; execute calls might") is harder to reason about than the check it saves.

## emergencySettleWithCalls stays unvalidated at submission — argued, not assumed

Three reasons, in decreasing order of weight:

1. **Enforcement already exists where it matters.** Owner-supplied emergency calls execute only through `finalizeEmergencySettle → executeGovernorBatch → _guardBatchCalls` (src/GovernorEmergency.sol:102-117). The privileged-target denylist fires there today, end-to-end pinned by `test_finalizeEmergencySettle_vaultSelfTargetingCalls_reverts` (test/governor/GovernorEmergency.t.sol:601). Submission-time validation would add a second check, not a first one.
2. **A rejected emergency batch is recoverable, unlike the defect this change fixes.** If finalize reverts on the guard, the whole tx rolls back, the registry review remains open, and the owner can `cancelEmergencySettle` and re-open with clean calls (src/GovernorEmergency.sol:90-98). The cost of late rejection is a wasted review period, not a stuck vault. The propose→settle path had no such loop — that is precisely why it needed the early check and the emergency path does not.
3. **Rescue of pre-fix proposals never needed emergency-path laxity.** Proposals created before this change land with poisoned settlement calls already stored; they will still brick at `settleProposal` (and at `unstick`, which replays the same calls). Their rescue is `emergencySettleWithCalls` with *fresh, owner-supplied* calls — which are clean by construction (a rescue naming the queue would fail finalize under today's guard regardless of this change). Nothing in this change touches that path, so nothing here can strand a pre-fix proposal.

A submission-time pre-check (fail at open rather than after the review period) would be a UX nicety. It is explicitly out of scope: minimal blast radius, and the approved scope is two items.

## nonReentrant on claimUnclaimedFees — deadlock check

The governor's latch is a single contract-wide status (`_reentrancyStatus`, shared by `nonReentrant` and `GovernorEmergency.emergencyNonReentrant` via the `_emergencyReentrancyEnter/Leave` overrides, src/SyndicateGovernor.sol:191-210). Two ways adding the latch could bite:

- **Guarded internal caller → deadlock.** `claimUnclaimedFees` has zero internal call sites — repo-wide grep finds only the external declaration, comments, and the interface. `_payFee` (the escrow *writer*, called under `settleProposal`'s latch) never calls it. No deadlock is reachable.
- **Behavior change on the reentrant path.** All batch-driving entrypoints (`executeProposal`, `settleProposal`, `unstick`, `finalizeEmergencySettle`) hold the latch through `executeGovernorBatch`, and the governor is *not* a denylisted batch target — so a batch sub-call can reach `claimUnclaimedFees` mid-batch today. Currently it no-ops (key `(vault, vault, token)` is unpopulated, `amt == 0` early-returns); after this change it reverts `Reentrancy`, failing the whole batch. That is proposer-authored calldata calling back into the governor — the sweep found no test, script, or legitimate pattern doing it, and a batch that does is refusing itself. Accepted, and pinned by a test so the change of behavior is deliberate rather than incidental.

Honesty requirement carried into code: the existing comment "No `nonReentrant` required: CEI is respected…" (src/SyndicateGovernor.sol:1629-1632) is *correct* and must not be silently deleted as if it had been wrong. It is rewritten to: CEI (zero-before-transfer) remains the primary defense; the latch is uniformity with every sibling entrypoint, closing the re-derivation cost the next time surrounding code changes.

## Test impact — per-site verdicts

Sweep: every construction of a batch `Call` targeting the vault or the queue in `test/` and `script/` (three grep shapes over targets; `script/` has none — the only script matches are storage-layout goldens).

| Site | Verdict |
|---|---|
| `test/audit-fixes/Vault_batchQueueTargets.t.sol` (whole file) | **Legitimate — keeps working unchanged.** Drives `vault.executeGovernorBatch` directly behind a mocked governor; never touches `propose`. Remains the authoritative pin of the execution-time guard, including both degrade-open branches. |
| `Vault_batchQueueTargets_lifecycle.t.sol::test_sixStepQueueSteal_isRejectedAtExecuteProposal` | **Pins the gap.** Steps 3-4 of its own trace ("propose … it passes review") stop being true: `propose` now reverts at step 3. Restructure: assert `DisallowedBatchTarget` at `propose`; the execute-time chokepoint claim it also carried is retained by the unit file above. |
| `Vault_batchQueueTargets_lifecycle.t.sol::test_queueTargetingSettlementBatch_isRejectedAtSettleProposal` | **Pins the gap — this is issue #118's exact scenario, asserted at the wrong (late) stage.** Becomes the headline propose-time rejection test: queue in `settlementCalls`, revert at `propose`. |
| `Vault_batchQueueTargets_lifecycle.t.sol::test_unstickWithQueueTargetingCalls_reverts` | **Pins the gap (transitively).** Needs a *stored* queue-targeting settlement batch, which can no longer exist via `propose`. Retire the lifecycle version with a comment; the `unstick`-path guard remains covered because `unstick` routes through `executeGovernorBatch` (pinned at unit level) and the emergency path keeps its own end-to-end witness (next row). |
| `Vault_batchQueueTargets_lifecycle.t.sol::test_unstickWithHonestCallsStillSettles` | **Legitimate — keeps working unchanged** (benign calls). |
| `test/governor/GovernorEmergency.t.sol::test_finalizeEmergencySettle_vaultSelfTargetingCalls_reverts` (:601) | **Legitimate — keeps working unchanged, and gains importance.** Owner-supplied emergency calls bypass `propose` by design, so this becomes the surviving end-to-end proof that the vault guard bites on a real entrypoint path post-fix. |

New tests this change owes: propose-time rejection for queue-in-settlementCalls, vault-in-executeCalls; degrade-open behavior against a vault without the view (propose accepts; `executeGovernorBatch` still rejects — proving the authoritative layer is intact); predicate-parity between the view and the guard; mid-batch `claimUnclaimedFees` reverts `Reentrancy`; and a plain external `claimUnclaimedFees` claim still works under the latch.

## Does item 1 subsume #150?

**Not as scoped — expected answer: no, and it must be checked rather than assumed.** #150's vector is an earlier proposal's batch calling into a strategy clone pre-deployed for a *later* proposal (flipping its one-shot `Executed` ratchet). Strategy clones are the *legitimate* batch surface — the denylist covers exactly two addresses (vault, queue) and deliberately leaves adapters open, and Part 2 gates only ERC20 selectors, which `BaseStrategy.execute()` is not. So the poisoning batch should still pass both `propose` and `_guardBatchCalls` after this change.

What this change *does* buy #150 is the seam: a propose-time target-validation loop now exists in `propose`, which is the natural place for #150's cheaper option 1 ("a batch may not target a strategy clone other than the proposal's own `p.strategy`") if it is ever taken.

**How to check, after implementation (record the result on #150):** on the landed branch, write #150's PoC shape — deploy a clone via `StrategyFactory` for a would-be future proposal, then drive an unrelated proposal through `propose → executeProposal` whose `executeCalls` contain `clone.execute()`. Expected: propose accepts, the batch runs, the clone's ratchet flips, and a later proposal referencing that clone bricks with `AlreadyExecuted`. If that holds, #150 remains open and correctly filed; if the batch is somehow refused, document which check refused it and close #150 against that evidence.

## Risks

- **Placement inside `propose`.** The check must run after the `TooManyCalls` cap (bounding the loop) and before `_proposalCount` increments / any state-changing external call (`lockBond`), alongside the other cheap input validation. `propose` is documented as sitting near Yul's stack budget (repeated hoisting comments in the function body); the loop should live in a private helper like its neighbors (`_snapshotTierAndGate`, `_checkMaxCapitalCeiling`) rather than inline.
- **Sequencing collision with #151/#43.** Both edit `propose`. Mitigated by the agreed order (#147 → this → #151 → #43); this change keeps `propose`'s signature frozen precisely so the later ones rebase cleanly.
- **A future third member of the target class.** Covered by construction: it joins the internal predicate and both consumers inherit it. The spec delta states this as the requirement (one implementation, all consumers), so a re-duplication would be a spec violation, not just a style regression.
