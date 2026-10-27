# Design — delete `selfManagesFees`

All file:line references are against `origin/main` = `e34526c`.

## D1 — `_chargePerformanceFee` with `chargeNew` hardwired `true` is correct; the parameter stays

**Trace.** `_chargePerformanceFee` (`SyndicateGovernor.sol:1498`) has exactly
one call site, `:1327`:

```solidity
_chargePerformanceFee(proposalId, vault, asset, proposal.proposer, !proposal.selfManagesFees);
```

`proposal.selfManagesFees == true` was the **only** way `chargeNew = false`
ever reached the function. Inside, the flag gates a single expression:

```solidity
uint256 base = chargeNew ? ISyndicateVault(vault).aboveHighWaterMark() : 0;
```

Everything downstream of `base` runs identically on both branches:

- `perfFee += ISyndicateVault(vault).consumeCrystallizedPerf()` — always runs;
- the four-way `snapshotPerfSplit` division, the zero-sum-split escape, the
  unconfigured-recipient folds, `_payFee` escrow-on-revert, the
  `GuardianFeeAccrued` delivery gate — all driven by `perfFee`, not by
  `chargeNew`;
- `ratchetHighWaterMark()` — always runs, on both branches and on the
  zero-sum early return.

So the `false` branch did exactly one thing: suppress the *new* above-HWM
charge for the self-managed case. No other path depended on it. Hardwiring
`true` is behavior-identical for every proposal that exists today (all in-tree
strategies return `false`; only mocks ever returned `true`).

**Why the parameter survives its last caller.** The natspec at `:1492-1498`
records a second, independent reason the function must run on every settle:

> fees already crystallized from instant exiters must be released and paid —
> skipping the call entirely would strand them in the vault forever,
> permanently excluded from `totalAssets()` and therefore lost to depositors.

That reason belongs to the Lane A crystallization system
(`consumeCrystallizedPerf`), which is being retired separately under **#54**
(spec in progress in parallel). Deleting `chargeNew` here on the assumption
that #54 lands would couple two independent deletions — if #54 slips or
changes shape, this change would have silently removed the documented seam
that protects crystallized exit fees. So:

- this change keeps `chargeNew`, passes literal `true` at `:1327`, and
  rewrites the `@param` natspec to drop the `selfManagesFees` sentence while
  keeping the crystallized-fees sentence verbatim;
- **follow-up, recorded here for #54**: once #54 removes
  `consumeCrystallizedPerf`, re-evaluate `chargeNew` — at that point it is
  plausibly vacuous and removable, but that is #54's (or a successor's)
  determination against #54's final shape, not this change's.

## D2 — the removed snapshot was the only untrusted external call in `propose()`; two side effects

The `selfManagesFees` snapshot was snapshotted at propose deliberately: a live
settle-time read had a TOCTOU flip (strategy reports `false` at propose,
`true` at settle, skipping fees) and a brick vector (a strategy whose
`selfManagesFees()` reverts would strand normal AND emergency settlement).
Does removing it weaken anything else in `propose()` that leaned on the same
protection?

**Survey of external calls remaining in `propose()`** (`:220-320`):
`ISyndicateVault.isAgent`, `IGuardianRegistry.reviewPeriod`,
`ISyndicateVault.agentFeeBps`, ProtocolConfig reads via `_snapshotFeeConfig`,
TierRegistry via `_snapshotTierAndGate`, WOOD `lockBond`. Every one targets a
**trusted protocol contract** wired by the owner/factory, not an
agent-supplied address, and each value that must be settle-stable is already
independently snapshotted into the proposal (`performanceFeeBps`, fee
recipients/splits, tier, Draft `votingPeriod`/`executionWindow`). None of them
relied on the `selfManagesFees` snapshot's protection. The removed call at
`:278` was the **only** external call `propose()` made into an address the
agent chooses.

Two side effects of removing it, one loss and one gain — both must be owned:

1. **Loss: the incidental EOA fail-fast.** The call to
   `IStrategy(strategy).selfManagesFees()` was the only code-existence probe
   on `strategy`; `test_propose_eoaStrategyRevertsAtPropose`
   (`test/SyndicateGovernor.t.sol:723`) pins exactly that. After removal,
   `propose()` accepts an EOA/codeless `strategy` address. This is
   acceptable because (a) nothing in the settle path reads the strategy for
   fee purposes anymore, and (b) strategy provenance is already an open,
   owned problem — #58's clone registry, with #118 adding propose-time
   call-target validation on the adjacent surface. A junk strategy address is
   a proposal-quality problem for voters/guardians, not a fee-integrity
   problem, once the flag is gone. The delta spec pins the new behavior
   explicitly so it reads as decided, not forgotten.
2. **Gain: no attacker-controlled code runs mid-propose.** `propose()` no
   longer executes any external call into agent-supplied code. The
   reentrancy-ordering comment around `collaborationDeadline` (`:295-305`)
   shows how seriously mid-propose reentrancy is taken for `lockBond` (a WOOD
   transfer hook); deleting the strategy call removes an entire
   attacker-chosen reentry point from that frame.

## D3 — test disposition, per test

The snapshot-semantics tests (`:672`, `:700`) pin **correct behavior for a
mechanism that is being removed**. They are deleted **with** the mechanism,
not weakened: after this change the governor makes *no* strategy call for fee
purposes at propose or settle, so the TOCTOU and brick vectors those tests
guard are structurally unreachable — a stronger guarantee than the tests
could express. A reviewer reading the diff should read their deletion as the
mechanism leaving, not as coverage dropping.

| Test / artifact | Lines | Verdict |
|---|---|---|
| `_createAndExecuteProposalWithStrategy` helper | `test/SyndicateGovernor.t.sol:199-215` | **Retain, re-comment.** Its docstring says it exists for tests "which need a non-zero strategy whose `selfManagesFees()` the governor reads at settle" — rewrite to: pins proposals carrying a real strategy address. Still used by the repurposed and replacement tests below. |
| `test_settlement_selfManagedStrategy_skipsPerformanceButPaysManagement` | `:625-644` | **Delete.** Tests the opt-out itself; the behavior no longer exists. |
| `test_settlement_nonSelfManagedStrategy_chargesNormalFees` | `:646-665` | **Repurpose (rename, keep body).** Its assertion — a proposal with a non-zero strategy address distributes fees normally — is exactly the post-change universal rule and directly pins the modified waterfall requirement ("no strategy self-report can exempt a proposal"). Drop the "control for the flag" framing from name and comment, e.g. `test_settlement_strategyProposal_chargesNormalFees`. |
| `test_settlement_selfManagesFeesSnapshot_revertAfterProposeDoesNotBrickSettle` | `:666-693` | **Delete (with the mechanism, not weakened).** Pinned snapshot-at-propose closing the settle-brick vector. Post-change, settle performs no strategy read at all — the vector is unreachable by construction. |
| `test_settlement_selfManagesFeesSnapshot_toctouFlipIgnored` | `:700-722` | **Delete (with the mechanism, not weakened).** Pinned snapshot-at-propose closing the TOCTOU flip. Post-change nothing reads the flag, so there is nothing to flip. |
| `test_propose_eoaStrategyRevertsAtPropose` | `:723-740` | **Delete and replace with its inverse.** The EOA revert was an incidental byproduct of the snapshot call (D2 side effect 1). New test: `propose()` with a codeless `strategy` address **succeeds**, pinning the "strategy address is not probed at propose" scenario so the behavior change is a decided, tested fact. |
| `MockStrategyAdapter.selfFee` / `revertOnSelfManagesFees` / both setters / `selfManagesFees()` | `test/mocks/MockStrategyAdapter.sol:13-26, 55-61` | **Strip.** The interface method is gone; the mock cannot keep implementing it (`IStrategy` conformance) and nothing consumes the toggles once the tests above are gone. Rest of the mock is untouched (used by `GovernorAdapterBinding.t.sol` as a plain strategy address). |
| `vm.mockCall` on `IStrategy.selfManagesFees.selector` | `test/SyndicateGovernor.t.sol:635` | **Deleted with its test** (`:633`). Listed so the selector-level grep comes back clean after implementation. |

## D4 — if a custody-model strategy is ever built

The defect the flag papered over returns the moment a strategy holds
LP-facing custody: float-delta PnL misreads its net deposits as profit. The
recorded position of this change: fix the **measurement**, not the fee. The
shape already exists in-tree — `IStrategy.positions()` reports WHERE/WHAT the
strategy holds, "never a self-reported value", and the vault prices positions
via the PriceRouter (`IStrategy.sol:55-62`). A custody strategy's PnL should
be derived from priced positions the same way, so the performance fee is
charged on true profit. What must **not** come back is a strategy-attested
exemption: any self-reported "skip my fees" bit recreates #151 verbatim,
whatever it is named.

## Storage / layout

`StrategyProposal.selfManagesFees` sits at slot 18 offset 20 (packed behind
`snapshotGuardiansFeeRecipient`; `script/syndicate-governor-layout.golden.json:437`).
The struct natspec (`ISyndicateGovernor.sol:105-113`) forbids removing members
for deployed lineages because `_proposals` is laid out by member index behind
a `BeaconProxy`. The owner confirmed **no governor is deployed**, so outright
removal is safe now and only now; the golden regenerates via
`./script/check-layout-goldens.sh --update-golden` and CI's layout guard pins
the new shape.

## Spec debt noted, not taken

The main spec's waterfall requirement and its "Self-managed fees opt out"
scenario say the flag "skips the **entire** governor fee waterfall"
(`openspec/specs/syndicate-governor/spec.md:141,156`). The code it describes
was superseded by the two-number model (management is charged regardless;
only the performance leg was exempt — `SyndicateGovernor.sol:1318-1322`,
archived change `2026-07-24-fee-mechanism` D3). This change deletes the
exemption clauses from both requirements but leaves the rest of the stale
waterfall text as-is — rewriting it to the two-number model is a separate
sync, out of scope here.
