# Certify strategy classes as part of the deploy ceremony

## Why

A protocol deployed by the documented ceremony cannot execute a single strategy
proposal.

`SyndicateVault._guardBatchCalls` gates every governor batch on two registry
axes, and a strategy clone satisfies neither out of the box:

- callee axis — `ITierRegistry.isCallableTarget(target)` (`src/SyndicateVault.sol:1221`),
  refusing the clone as a batch target with `DisallowedBatchCallee`;
- funds axis — `ITierRegistry.isAdapterAllowed(to)` (`:1278`, `:1317`), refusing
  the clone as a recipient of vault capital with `DisallowedTransferTarget`.

`TierRegistry` already carries the mechanism that fixes this once rather than
once per proposal: clones of one template share an `EXTCODEHASH`, so a CLASS
grant covers every clone that will ever exist. Nothing in `script/` performs it
— `grep -rln "proposeClassCertification\|certifyClass\|setClassAllowed" script`
returns nothing, and only two test files exercise the API. So every deployment
to date ships with every strategy class uncertified, and the failure surfaces a
governance cycle later as a vault-level revert naming a clone address rather
than the missing deploy step.

The gap is not a missing line in an existing script. The grant is announce-then-
execute with a `certifyDelay` (default 3 days, floor 1 day) between the two, so
it cannot live inside a single deploy transaction and needs its own two-phase
script with its own slot in the runbook.

## What Changes

- **New `script/CertifyStrategyClasses.s.sol`** with two entrypoints. `propose()`
  announces a class certification for each eligible template against both
  selectors a governor batch names (`execute()`, `settle()`), pinning the
  template's live codehash. `finalize()`, run after `certifyDelay`, executes the
  grants and calls `setClassAllowed(template, true)` — the write that opens BOTH
  axes. Both phases skip cleanly with a RUNBOOK line when the deployer no longer
  owns the registry, and `finalize()` is re-runnable.
- **Risk parameters are stated, not derived.** `tier` and `extractableBoundBps`
  are what the governor turns into required guardian coverage, so they sit in a
  named constant block per template with their rationale, overridable by env,
  rather than being a number buried in a loop. `SyndicateGovernor._scanCalls`
  accumulates `cap_i * boundBps / 10_000` PER CALL, so `execute()` and
  `settle()` are already two contributions — a bound sized for "the entry and
  exit legs of one proposal" would be double-counting. Portfolio's `2_000` is
  2x the ≤1_000 bps ceiling one call can reach
  (`MAX_SLIPPAGE_CEILING_BPS`). No bound prices
  `PortfolioStrategy.rebalance()` / `rebalanceDelta()` (both `onlyProposer`,
  called on the clone rather than through a governor batch, up to
  `MAX_CUMULATIVE_DECAY_BPS` = 2_000 lifetime decay) or the permissionless
  `ConcentratedLiquidityStrategy.rerange()`.
- **`ConcentratedLiquidityStrategy` is certified at `9_999` bps, not `2_000`.**
  Its `_initialize` binds `swapAdapter`, `positionManager`, `uniswapFactory`,
  `morpho` and `marketParams.collateralToken` to the registry, but NOT
  `marketParams.oracle`, `.irm` or `.lltv`. The only market check is
  `market(id).lastUpdate != 0`, which is permissionlessly true of any params
  tuple on Morpho Blue, and check (4)'s LTV test never consults the market
  oracle for a vault-asset collateral. A proposer can therefore create a market
  with an attacker-authored oracle and have the posted collateral seized:
  reachable loss is ~100% of it, not 20%. `9_999` is the maximum
  `proposeClassCertification` accepts (`>= FULL_NOTIONAL_BPS` reverts
  `BoundRequired`), so certifying buys callability without buying a 5x coverage
  discount. Dropping the template from the set instead is not the alternative —
  that leaves its clones failing `isCallableTarget`, i.e. this change's own
  defect unfixed for CL.
  **NEEDS RATIFICATION:** certifying below tier 2 also removes the per-call
  `Tier2CallCapExceedsCeiling` ceiling (`_scanCalls`), which the ceiling applies
  only when a call resolves to tier 2. No choice of `extractableBoundBps`
  restores it. Accepting that trade is a human decision.
- **`MorphoSupplyStrategy` is excluded by construction.** Its
  `marketParams.oracle`, `.irm` and `.lltv` are proposer-chosen and bound to
  nothing, so no class bound holds over every initialization — the same gap CL
  has on its levered path. (The earlier justification, that it validates its
  Morpho address by asking that address, is stale: `MorphoSupplyStrategy.sol:190`
  binds `morpho_` through `_isAdapterAllowed` before any call into it.) Calling
  it "address-certifiable" overstates the remedy: a clone's address does not
  exist until the proposal that creates it, so the address path costs two owner
  transactions plus a 3-day delay PER PROPOSAL. In practice this template has no
  usable path until its market parameters are bound.
- **`Deploy.s.sol` gains one RUNBOOK line** naming the step and the delay, so the
  ceremony is discoverable from the deploy output.

**BREAKING**: none. No `src/` change; the script is additive.

## Capabilities

### Modified Capabilities

- `deployment-docs` — the ceremony order requirement enumerates the scripts an
  operator runs. Running exactly those produces a protocol that cannot execute a
  proposal, so the class ceremony is added as a step with its delay stated.
