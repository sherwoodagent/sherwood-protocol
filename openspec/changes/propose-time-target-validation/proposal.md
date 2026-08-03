# Reject privileged batch targets at propose time; latch claimUnclaimedFees (issue #118)

## Why

**1. A pre-committed settlement call naming the queue bricks LP flow, and nothing catches it until it is too late to matter.** `_guardBatchCalls` (src/SyndicateVault.sol:590-643) rejects any governor batch call whose target is the vault itself or its bound withdrawal queue — but it runs only inside `executeGovernorBatch`, i.e. at execute/settle time. `SyndicateGovernor.propose` (src/SyndicateGovernor.sol:219-333) never consults it. A proposal whose `settlementCalls` name the withdrawal queue is therefore accepted, voted, and executed — and then reverts **permanently** at `settleProposal`: the proposal is stuck in `Executed`, `redemptionsLocked()` stays true, and every LP exit is frozen until the vault owner runs the emergency path. The guard did its job; it just did it a full lifecycle after the information was available. Rejecting the same targets at `propose` turns a silent, terminal settlement failure into a loud, immediate one at the point of entry — the calldata is pre-committed at propose, and the denylist it violates is deterministic from that moment (the vault address is fixed and `setWithdrawalQueue` is factory-only, set-once at syndicate creation — src/SyndicateVault.sol:427-434).

The two legs of a proposal fail asymmetrically, which is why this matters for `settlementCalls` far more than for `executeCalls` — verified against the state machine:

- a poisoned **execute** call reverts `executeProposal`, the whole tx rolls back, the proposal stays `Approved`, expires at `executeBy` (src/ProposalLifecycle.sol:109), and `_commitState` runs `_decOpen()` on the Expired edge (src/ProposalLifecycle.sol:208-210), releasing the vault. Self-healing.
- a poisoned **settlement** call reverts `settleProposal` after the `Executed` transition has already committed in an earlier tx. There is no expiry edge out of `Executed`; the only exits are the settlement paths themselves. `unstick` replays the same poisoned calls and reverts identically. Recovery is the owner-gated `emergencySettleWithCalls` review cycle. Terminal without owner intervention.

Both arrays are validated anyway — the loop is the same, and a proposal that can never execute wastes a full vote cycle for no reason — but the settlement leg is the defect that justifies the change.

**2. `claimUnclaimedFees` is the one state-changing governor entrypoint without the reentrancy latch** (src/SyndicateGovernor.sol:1633-1640). To be precise about what fixing that buys: nothing, today. The reentrant path was traced, not assumed — the escrow key is `(vault, msg.sender, token)`, and a reentrant call from batch context resolves `msg.sender == vault`, a slot only populated if a fee recipient literally equals the vault address, which is not a real configuration. CEI is also respected (the slot is zeroed before the external transfer). This is a consistency and defence-in-depth fix, shipped because a lone unguarded entrypoint among guarded siblings is exactly the asymmetry that turns into a bug when the surrounding code changes — not because there is a live hole. The spec and the code comment say so plainly rather than implying a vulnerability was closed.

**Out of scope, deliberately:** issue #118's third lead (`BaseStrategy.execute`/`settle` per-vault-not-per-proposal enabling a *future pending proposal* collision) is **disproven** — `_openProposalCount` enforces exactly one open proposal per vault, so the described race is structurally impossible. The narrow surviving variant (an unrelated *earlier* proposal's batch poisoning a pre-deployed clone's `Executed` ratchet) is filed as **#150** and is not implemented here; see design.md for whether this change subsumes it (short answer: not as scoped) and how to check after landing.

## What Changes

- **`SyndicateVault`**: extract `_guardBatchCalls`'s unconditional privileged-target predicate (target == vault || target == bound queue) into a single internal function, and expose it as a new external view (`isPrivilegedBatchTarget(address)`). `_guardBatchCalls` Part 1 keeps enforcing through the same internal body — one predicate implementation, two consumers, drift impossible by construction.
- **`SyndicateGovernor.propose`**: after the existing input caps (so the loop is bounded by `MAX_CALLS_PER_PROPOSAL`), reject any entry of `executeCalls` **or** `settlementCalls` whose target the vault's predicate flags, reverting `ISyndicateVault.DisallowedBatchTarget(target)` — the same error the execution-time guard uses for the same violation. The predicate is consumed via staticcall and **degrades open** if the vault predates the view (fail-early must never become fail-always; the execution-time guard remains authoritative).
- **Scope of the propose-time check is the unconditional denylist only.** The registry-gated selector half of `_guardBatchCalls` is deliberately NOT evaluated at propose: it depends on mutable state (`_demote` clears allowlist entries, and PR #149 / issue #137 makes `isAdapterAllowed` codehash-aware, so an adapter can flip from allowed to not-allowed with no state write at all). A propose-time pass over that half would prove nothing about settle time and manufacture false completeness. See design.md.
- **`SyndicateGovernor.claimUnclaimedFees`**: add `nonReentrant`; replace the "No `nonReentrant` required" comment (src/SyndicateGovernor.sol:1629-1632) with one stating that CEI remains the primary defense and the latch is uniformity.
- **Emergency paths unchanged**: `emergencySettleWithCalls` stays unvalidated at submission — its calls are already enforced by `_guardBatchCalls` at `finalizeEmergencySettle`, and a rejected emergency batch is recoverable (cancel + re-open with clean calls), not terminal. Argued in design.md.
- **Tests**: new propose-time rejection tests; three tests in `test/audit-fixes/Vault_batchQueueTargets_lifecycle.t.sol` currently pin the gap (they push queue-targeting proposals through `propose` and assert rejection downstream) and move their assertions to propose time; the unit file and the emergency-path test keep working unchanged. Per-site verdicts in design.md.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `syndicate-governor`: "Proposal creation validation" gains the propose-time privileged-target rejection (both call arrays, denylist half only, degrade-open on a predicate-less vault). "Fee distribution waterfall" gains the `claimUnclaimedFees` latch requirement, stated as uniformity rather than a vulnerability fix.
- `syndicate-vault`: "Privileged-target guard on batches" now requires the predicate to be implemented once and exposed as a view, so propose-time and execution-time consumers cannot drift; execution-time enforcement remains authoritative regardless of any earlier check.

## Impact

- `src/SyndicateVault.sol` — extract the Part 1 predicate into an internal function; add the external view. Small bytecode growth: irrelevant on Robinhood Chain 4663 (98,304-byte limit, current vault ~25.6 KB); the legacy Base vault cannot take upgrades anyway and is out of scope.
- `src/interfaces/ISyndicateVault.sol` — new view declaration.
- `src/SyndicateGovernor.sol` — target loop in `propose`; `nonReentrant` on `claimUnclaimedFees`; comment rewrite at :1629-1632.
- `test/audit-fixes/Vault_batchQueueTargets_lifecycle.t.sol` — three tests restructured (design.md, "Test impact").
- No storage layout changes (one new external view, one modifier). No event changes. `propose()`'s signature is untouched — deliberate, see sequencing.

## Sequencing

**#147 lands first** (live `forceApprove` gap in `PortfolioStrategy`), then this change, then **#151** (deletes `selfManagesFees`; also edits `propose`), then **#43** (per-call capital declarations, which changes `propose()`'s signature). The ordering is intentional: this is a small, signature-preserving validation change and must land before the signature change so #43 rebases onto it rather than both churning the same function in flight. No conflict with off-limits #35 (`ExposureLedger`/`StakedWood`) or #45 (`TierRegistry`). PR #149 (codehash-aware `isAdapterAllowed`) merges independently and only strengthens this change's scoping argument; no file overlap with the propose/guard edits here.
