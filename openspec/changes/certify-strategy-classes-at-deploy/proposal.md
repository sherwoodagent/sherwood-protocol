# Certify strategy classes as part of the deploy ceremony

## Why

A protocol deployed by the documented ceremony prices every strategy proposal at
FULL NOTIONAL.

`SyndicateGovernor._scanCalls` resolves each call through
`ITierRegistry.tierOf(target, selector)` and accumulates
`cap_i * boundBps / 10_000` as required guardian coverage. An uncertified target
answers `(TIER_ARBITRARY, FULL_NOTIONAL_BPS)`, so the whole declared cap of
every leg has to be covered — and the per-call `Tier2CallCapExceedsCeiling`
ceiling applies on top, because `_scanCalls` enforces it exactly when a call
resolves to tier 2.

Every strategy proposal names a freshly minted ERC-1167 clone, whose address
nobody can certify ahead of time. `TierRegistry` already carries the mechanism
that fixes this once rather than once per proposal: clones of one template share
an `EXTCODEHASH`, so a CLASS grant covers every clone that will ever exist.
Nothing in `script/` performs it —
`grep -rln "proposeClassCertification\|certifyClass" script` returns nothing.

This is NOT a liveness gap. `StrategyFactory.cloneAndInit` records
`cloneTemplate[clone]` and `SyndicateVault._guardBatchCalls` admits any target
the factory registers, so an uncertified clone is callable and fundable today.
What it is not is *cheap*: the coverage the governor demands is the full
notional of the proposal.

The grant is announce-then-execute with `certifyDelay` (default 3 days, floor
1 day) between the two, so it cannot live inside a single deploy transaction and
needs its own two-phase script with its own slot in the runbook.

## What Changes

- **New `script/CertifyStrategyClasses.s.sol`** with two entrypoints.
  `propose()` announces a class certification for each eligible template against
  both selectors a governor batch names (`execute()`, `settle()`), pinning the
  template's live codehash. `finalize()`, run after `certifyDelay`, executes the
  grants. `propose()` skips with a RUNBOOK line when the deployer no longer owns
  the registry; `finalize()` carries no such guard, because `certifyClass` is
  permissionless without a submitter bond. Both phases are re-runnable.
- **Risk parameters are stated, not derived.** `tier` and `extractableBoundBps`
  are what the governor turns into required coverage, so they sit in a named
  constant block with their rationale, overridable by env. `_scanCalls`
  accumulates PER CALL, so `execute()` and `settle()` are already two
  contributions — a bound sized for "the entry and exit legs of one proposal"
  would double-count. Portfolio's `2_000` is 2x the ≤1_000 bps a single call can
  reach (`PortfolioStrategy.MAX_SLIPPAGE_CEILING_BPS`), which is the whole
  in-batch surface: `_initialize` binds the swap adapter, every price feed and
  each token↔feed pairing through the registry. No bound prices
  `PortfolioStrategy.rebalanceDelta()` — `onlyProposer`, called on the clone
  rather than through a governor batch, and this branch carries no lifetime
  decay budget, so repeats are unbounded.
- **Only `PortfolioStrategy` is certified.** Certification here buys a coverage
  discount and nothing else, so a template whose loss surface its own
  `_initialize` does not bound keeps paying full notional — which costs the
  protocol nothing, because those clones are callable either way.
  - `ConcentratedLiquidityStrategy` is excluded. Its levered path binds
    `swapAdapter`, `positionManager`, `uniswapFactory`, `morpho` and
    `marketParams.collateralToken` to the registry, but NOT
    `marketParams.oracle`, `.irm` or `.lltv`. The only market check is
    `IMorpho(p.morpho).market(id).lastUpdate == 0`, which is permissionlessly
    false for any params tuple on Morpho Blue once created, and the LTV buffer
    test prices collateral off the strategy's own feed rather than the market
    oracle. A proposer can therefore point a levered clone at a market with an
    attacker-authored oracle and lose the whole collateral. Full-notional
    coverage is the honest price for that. (The unlevered mode added by
    `unlevered-cl-lp` names no Morpho surface at all, but tier and bound are
    per-CLASS, not per-initialization, so the levered mode sets the price.)
  - `MorphoSupplyStrategy` is excluded for the same reason: it decodes
    `MarketParams` straight out of init data and binds none of
    `mp.oracle/irm/lltv`. Its Morpho singleton IS registry-bound
    (`MorphoSupplyStrategy.sol:82`), so the justification in
    `docs/adapter-onboarding-checklist.md` §4b — that it validates its Morpho
    address by asking that address — is stale and SHALL NOT be relied on.
- **`Deploy.s.sol` gains one RUNBOOK line** naming the step and the delay, so
  the ceremony is discoverable from the deploy output.

**BREAKING**: none. No `src/` change; the script is additive.

## Capabilities

### Modified Capabilities

- `deployment-docs` — the ceremony order requirement enumerates the scripts an
  operator runs. Running exactly those produces a protocol that prices every
  proposal at full notional, so the class ceremony is added as a step with its
  delay stated.
