# Delete the `selfManagesFees` mechanism

Issue: #151. Owner decision (recorded there): **delete** the flag rather than
guard it. No governor is deployed, so the storage field is removed outright,
with no placeholder.

## Why

`SyndicateGovernor.propose` takes the strategy's word for whether it handles
its own fees:

```solidity
p.selfManagesFees = strategy != address(0) && IStrategy(strategy).selfManagesFees();
```

(`src/SyndicateGovernor.sol:278`.) There is no provenance check on `strategy`,
so a registered agent can point a proposal at any contract that returns `true`
and skip the performance-fee leg at settlement (`:1327`). A revenue leak
available to a trusted party — bounded, but structural.

Three facts make deletion, not guarding, the right call:

1. **The flag is a workaround for a profit-measurement defect, not a fee
   feature.** `SyndicateGovernor.sol:1312-1322`: a custody-model strategy
   crystallises its own fees; the governor's float-delta PnL would misread net
   deposits as profit and double-charge. The flag papers over that
   mismeasurement by exempting the performance leg entirely.
2. **Nothing implements it.** `BaseStrategy.selfManagesFees()` returns `false`
   and is the only in-tree implementation. The code says so twice
   (`BaseStrategy.sol:135-138`, `SyndicateGovernor.sol:1408-1409`). Only test
   mocks ever return `true`, via `vm.mockCall` / a test setter.
3. **It ships an obligation the chain never checks.** `BaseStrategy.sol:135-138`:
   a self-fee'd strategy "MUST self-collect the protocol fee itself or the
   protocol earns nothing" — an honor-system protocol-fee leg.

Deleting the mechanism closes #151's leak completely: there is no flag left to
lie about.

## What Changes

- **`src/interfaces/IStrategy.sol:66`** — delete `selfManagesFees()` from the
  interface.
- **`src/strategies/BaseStrategy.sol:135-141`** — delete the default
  implementation and its natspec.
- **`src/interfaces/ISyndicateGovernor.sol:116-120`** — delete the
  `StrategyProposal.selfManagesFees` field. Outright removal (later members
  shift down) is safe **only** because no governor is deployed — the struct's
  own natspec forbids this for deployed lineages. This is the last moment the
  field can be removed this cheaply.
- **`src/SyndicateGovernor.sol:278`** — delete the propose-time snapshot. This
  removes the only external call `propose()` makes into an agent-supplied
  address (see design.md D2 for both side effects of that).
- **`src/SyndicateGovernor.sol:1327`** — `_chargePerformanceFee(...)` is now
  called with `chargeNew = true` (literal). **The `chargeNew` parameter itself
  is retained** — its natspec (`:1492-1498`) records a second, independent
  reason the function must run on every settle: fees already crystallized from
  instant exiters must be released and paid, or they are stranded in the vault
  forever, excluded from `totalAssets()` and lost to depositors. That reason
  belongs to the Lane A crystallization system being retired separately under
  #54; whether `chargeNew` becomes vacuous is **#54's determination**, not
  this change's. See design.md D1.
- **`script/syndicate-governor-layout.golden.json`** — regenerate
  (`./script/check-layout-goldens.sh --update-golden`); the field currently
  sits at slot 18 offset 20 (`:437`) and every later member shifts.
- **Tests** — the mechanism's tests are deleted **with** the mechanism, not
  weakened; one is repurposed and one is replaced by its inverse. Per-test
  disposition in design.md D3.
- **ABI note** — `getProposal()` returns `StrategyProposal`; removing the
  field changes the tuple shape. In-repo search found no off-chain consumer;
  any external indexer decoding `getProposal` must update.

## Non-goals

- **No guard, re-check, or provenance validation is added here.** Strategy
  provenance (the #58 clone-registry direction) remains open; #118 adds
  propose-time call-target validation on its own track.
- **The stale "entire fee waterfall" language** in the main
  `syndicate-governor` spec (the waterfall requirement still describes the
  pre-two-number fee model) is not rewritten here; only the self-managed
  clauses are touched. Syncing the waterfall text to the shipped two-number
  model is separate debt.
- **`chargeNew` is not removed** (see above and design.md D1).

## If a custody-model strategy is ever built

The underlying defect returns: float-delta PnL misreads custody deposits as
profit. The correct fix at that point is to **measure PnL correctly for that
strategy shape** (e.g. price the strategy's positions, as `positions()` +
PriceRouter already anticipate), **not** to reintroduce a self-reported
exemption. A strategy attesting "don't charge me" is the pattern #151 exists
to kill. Recorded in design.md D4.

## Sequencing

Chain of changes touching `SyndicateGovernor.propose`:
**#147 → #118 → this (#151) → #43**. #118 (propose-time call-target
validation) is specced in parallel; #43 changes `propose()`'s signature and
lands after this. No overlap with #35 or #45. #54 (Lane A retirement) is
independent except for the `chargeNew` follow-up recorded in design.md D1.

## Impact

- Specs: `syndicate-governor` (two requirements modified — proposal-creation
  snapshot list, fee-waterfall exemption clause + scenario).
- Code: `src/interfaces/IStrategy.sol`, `src/strategies/BaseStrategy.sol`,
  `src/interfaces/ISyndicateGovernor.sol`, `src/SyndicateGovernor.sol`,
  `script/syndicate-governor-layout.golden.json`,
  `test/SyndicateGovernor.t.sol`, `test/mocks/MockStrategyAdapter.sol`.
- Behavior: the only externally observable changes are (a) settlement can no
  longer skip the performance leg on a strategy's say-so, and (b) `propose()`
  no longer reverts for a codeless `strategy` address (design.md D2).
