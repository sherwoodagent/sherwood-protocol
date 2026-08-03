# Bind the proposer-supplied swap adapter to the tier-registry allowlist (issue #147)

## Why

`PortfolioStrategy._initialize` accepts a proposer-supplied `swapAdapter_` and
validates only that it is non-zero (`src/strategies/PortfolioStrategy.sol:232`),
then assigns it (`:283`). There is no allowlist, registry, or provenance check —
`git grep -n "_requireAllowedAdapter"` on `main` returns zero hits. That address
is then handed ERC-20 approvals over the vault's capital at six sites
(`:301`, `:322`, `:402`, `:416`, `:542`, `:565`, all
`forceApprove(address(swapAdapter), ...)`), so a proposer can name a contract
they control, have the strategy approve it the allocation, and spend the
allowance in a later, separate transaction.

`SyndicateVault._guardBatchCalls` (`src/SyndicateVault.sol:590-671`) cannot
catch this. It gates the spender/recipient of value-moving ERC-20 selectors in
the batch's own calldata against `TierRegistry.isAdapterAllowed` — but the
batch call here is `strategy.execute()`, and the `forceApprove` happens inside
the strategy, one frame deeper than anything the guard inspects. PR #104's own
natspec states it: *"the strategy's own re-approval is the hop that bound does
not see."*

Reachability is bounded but real: `propose()` requires
`vault.isAgent(msg.sender)` (`src/SyndicateGovernor.sol:230`), so only an
already-registered agent can reach it. But the entire purpose of the
tier/allowlist system is that agent registration is NOT sufficient authority to
route vault value to an arbitrary address — `_guardBatchCalls` exists precisely
to bound registered agents. Treating "the agent is trusted" as adequate here
would invalidate the reason #93, #115 and #137 were treated as real.

A second, adjacent init gap ships in the same function: `maxSlippageBps_` is
bounded only from above (`MAX_SLIPPAGE_CEILING_BPS`, `:240`). A near-zero value
makes oracle-floored swaps (`rebalanceDelta`) unfillable whenever the tolerance
sits below the venue fee, and the tighten-only rule in `_updateParams`
(`:360-361`) makes a too-low value **irreversible** — slippage can never be
raised again. `_execute` and `_settle` apply `maxSlippageBps` regardless of
lane, so this is Lane-A-independent.

Both fixes already exist on PR #104 (`feat/lane-a-enablement`). Lane A is being
retired from v1 (#54) and that PR will be closed — this change extracts the two
Lane-A-independent hardening pieces so they are not lost with it.

## What changes

1. **`_requireAllowedAdapter` in `PortfolioStrategy`** — a private view check
   called from `_initialize` before any state is written. It walks
   `vault() → governor() → tierRegistry()` with length-checked raw staticcalls
   and requires `isAdapterAllowed(swapAdapter_)` in the resolved registry —
   the SAME `TierRegistry` the vault's batch guard consults. If the walk
   resolves no registry (codeless vault, no `governor()` surface, governor
   without the getter, or `tierRegistry() == 0`) the check is skipped — exactly
   the condition under which `_guardBatchCalls` disables itself, and one the
   proposer cannot steer because no hop of the walk is proposer input. A
   registry that resolves but cannot vouch (revert, malformed return) fails
   CLOSED with `AdapterNotAllowed(swapAdapter, registry)`.

2. **`MIN_SLIPPAGE_BPS = 50`** — a hard floor on `maxSlippageBps`, enforced at
   `_initialize` (replacing the `== 0` check, which the floor subsumes) and in
   `_updateParams`' tighten path. The `newMaxSlippageBps == 0` "keep current"
   sentinel is preserved.

The check is init-time only: `swapAdapter` is immutable after `_initialize`
(the `:283` assignment is its only write; `_updateParams` decodes only weights,
slippage, and routes), and `_execute`/`_settle` deliberately do NOT re-check —
see design.md decision 3 for why a re-check at settle would convert a
mid-flight demotion into stranded LP capital.

## What does NOT change

- **`TierRegistry` itself is untouched.** No new storage, no new surface. The
  tier-policy spec delta only records the second consumer of
  `isAdapterAllowed` and its unchanged one-way demotion coupling.
- **Everything Lane-A-only in PR #104 stays out**: the pricing adapters,
  `MorphoSupplyStrategy`, vendored Morpho libs, `DeployLaneA.s.sol`, the
  feed-to-token binding walk (`_spotFeedRegistry` / `_registeredFeed`),
  `_legMinOut`, `withdrawTo` / instant-exit unwind, and the
  `MAX_SLIPPAGE_CEILING_BPS` natspec rewrite that references `_legMinOut`. The
  extracted natspec must be re-justified against `main` (rebalanceDelta's
  oracle floors + tighten-only irreversibility), not against `_sellForUnwind`.
- **`VeniceInferenceStrategy` is out of scope but has the same gap class**:
  `_initialize` accepts proposer-supplied `aeroRouter` / `sVVV` that later
  receive `forceApprove` / stakes
  (`src/strategies/VeniceInferenceStrategy.sol:150,171`). File as a follow-up
  issue; do not widen this change.

## Impact

- `src/strategies/PortfolioStrategy.sol` — the only production contract touched.
- **Tests that break (they relied on the gap, not pinned correct behavior):**
  `test/integration/strategies/PortfolioIntegration.t.sol` and
  `test/integration/strategies/PortfolioMainnetFork.t.sol`. Both drive a real
  stack via `DeploySherwood.deployCore`, which since `9fafa00` (2026-07-24)
  deploys a `TierRegistry` and wires it into every per-vault governor at
  `createSyndicate` — so the strategy's walk resolves a live registry, and the
  suites' swap adapters (read from `chains/46630.json`, resp. freshly
  constructed) are not allowlisted. Fix: `setAdapterAllowed(swapAdapter, true)`
  in setUp, pranked as the registry owner. Both suites are RPC-gated (they skip
  in CI when the fork URL env is unset).
- **Pre-existing breakage surfaced by this sweep:** those same two fork suites
  already cannot pass `_guardBatchCalls` at head — their execute batches carry
  `asset.approve(strategy, amount)` and nothing allowlists the strategy clone
  (the guard wiring post-dates the suites; RPC gating hid it). The same setUp
  edit should allowlist the clone as well, recorded as a distinct pre-existing
  fix, not an effect of this change.
- **Unaffected:** `test/PortfolioStrategy.t.sol` and
  `test/audit-fixes/Strategy_init_frontrun.t.sol` (vault is a codeless
  `makeAddr` — hop 1 skips; every slippage fixture is 100 bps ≥ floor),
  `test/integration/TierEndToEnd.t.sol` (never initializes a
  PortfolioStrategy), `test/integration/strategies/UniswapAdapterFork.t.sol`
  (adapter-only). No script initializes a PortfolioStrategy
  (`DeployTemplates.s.sol` and both `DeployPortfolioStrategy.s.sol` deploy
  template/adapter bytecode only).
- **Operations:** on a wired stack, onboarding a Portfolio swap adapter now
  requires an explicit owner `setAdapterAllowed(adapter, true)` BEFORE any
  proposer can clone+init against it — the same one-line action class the owner
  already performs so batches can approve the strategy clone. Document in the
  adapter-onboarding runbook.

Closes #147.
