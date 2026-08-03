# Design — portfolio-swap-adapter-allowlist

Six questions were posed at scoping. Each is resolved here against source read
at `origin/main` `e34526c` and PR #104's diff (read-only).

## 1. Is `TierRegistry.isAdapterAllowed` the right authority?

**Yes — it is the same permission class, not an overload.**

The permission the strategy grants with `forceApprove(swapAdapter, …)` is
exactly what the allowlist already encodes. The registry's own storage comment
(`src/TierRegistry.sol:68-74`) defines the axis as "may appear as the
spender/recipient of value-moving ERC20 calls … this list bounds WHERE vault
funds may be approved or sent at all". A strategy-internal
`forceApprove(adapter, allocation)` on capital pulled from the vault is
semantically identical to a batch-level `approve(adapter, allocation)` — the
only difference is the call frame, which is precisely the hole being closed.
Reusing the registry means:

- **One authority, one owner action.** No second allowlist to drift from the
  first; onboarding stays "certify + allowlist" as already established by
  `TierEndToEnd`'s `_wireTierRegistry`.
- **Demotion hygiene comes free.** `_demote` clears the allowlist entry (the
  #77 fix, spec'd in tier-policy "Three demotion paths converging on one
  effect"), so a convicted or code-swapped adapter is refused at the next
  strategy init with no extra plumbing.
- **#137 strengthens this check automatically.** When `isAdapterAllowed`
  becomes codehash-aware, the same read this check performs starts returning
  `false` for a metamorphically-swapped adapter. The external signature
  `isAdapterAllowed(address) → bool` is unchanged by #137, so there is no
  coupling or ordering constraint between the two changes.

Alternatives considered and rejected: the `StrategyFactory` template allowlist
(wrong axis — it vouches for strategy TEMPLATE bytecode, not for fund
destinations, and nothing forces `propose()`'s strategy through the factory at
all, per `StrategyFactory.sol:44-46`); a new strategy-side registry (a second
list with a second owner surface, guaranteed to drift); a governor parameter
(no existing surface, same drift problem).

The tier-policy spec text currently scopes the allowlist to "inside governor
batches (consumed by `SyndicateVault._guardBatchCalls`)". This change MODIFIES
that requirement to name the second consumer rather than silently generalizing
it — the meaning becomes "vault funds, wherever they are approved or sent on
the vault's behalf", which is what the mechanism was always for.

## 2. The walk, hop by hop, and failure semantics

The walk is `vault() → governor() → tierRegistry() → isAdapterAllowed(adapter)`.
`vault()` is BaseStrategy state, set before `_initialize` runs and guaranteed
non-zero (`BaseStrategy.initialize` reverts `ZeroAddress`); it is not proposer
calldata. Every subsequent hop is a raw staticcall guarded by
`code.length != 0`, a return-length check, and a dirty-upper-bits check
(PR #104's `_readAddress` helper), so a codeless or hostile target reads as
"unresolved" rather than reverting with an unrelated error.

| Hop | Failure | Behavior | Why |
|---|---|---|---|
| `vault()` codeless (unit-test fixtures, mock stacks) | unresolved | **skip** | No governor exists to have wired a registry. |
| `vault().governor()` missing/reverts/returns 0 or junk | unresolved | **skip** | Pre-governor vault; nothing to consult. |
| `governor.tierRegistry()` missing/reverts/returns 0 or junk | unresolved | **skip** | Registry deliberately unwired. |
| Registry resolved, `isAdapterAllowed` reverts/malformed | — | **fail closed** (`AdapterNotAllowed`) | A registry that cannot vouch has not vouched. |
| Registry resolved, returns `false` | — | **fail closed** (`AdapterNotAllowed`) | The gap being fixed. |

**Why skip-on-unresolved is safe and not attacker-forcible:** the skip
condition is exactly the condition under which `_guardBatchCalls` disables
itself (its documented "UNSET REGISTRY" degrade — `SyndicateVault.sol:580-589`,
`:646-649`). With no registry, a governor batch can already approve vault funds
to any address, so the strategy's internal re-approval grants nothing not
already granted; hard-reverting there would brick every mock-stack test and
every pre-registry deployment while protecting nothing. And no hop of the walk
reads proposer input — the proposer supplies `swapAdapter_` (the thing being
judged) but cannot steer WHERE the judgment happens, because the walk starts at
`vault()`, which the factory/agent flow fixes before init.

**No legitimate-init brick.** On a wired stack (post-`9fafa00`
`DeploySherwood.deployCore` wires the factory's TierRegistry into every
per-vault governor at `createSyndicate`), the check is hard — and that is an
onboarding-ORDER requirement, not a liveness hazard: strategy clones are
created and initialized by the proposer before `propose()`, in their own
transaction; if the owner has not yet allowlisted the adapter, init reverts
`AdapterNotAllowed` and can simply be retried after the one-line
`setAdapterAllowed`. Nothing time-critical or capital-bearing sits behind a
strategy init. Gas cost is three staticcalls plus code-size probes, once per
clone lifetime, in an already six-figure-gas init — negligible.

## 3. Init-time only, or re-checked at execute/settle?

**Init-time only.** Three reasons, in descending force:

1. **A settle-time re-check is a capital hostage.** After `_execute`, the
   vault's capital lives in the strategy as basket tokens. If a demotion (which
   clears the allowlist — #77) landed mid-flight and `_settle` re-checked, the
   settle would revert and the capital would be recoverable only through the
   owner+guardian emergency path. The existing design already treats "settle
   must not gain revert paths" as load-bearing (`RoutesFrozen` keeps
   `rebalanceDelta` alive precisely so settlement paths stay unfrozen; PR #104
   adds a quote-unavailable fallback to `_settle` for the same reason).
   A demotion's remedy against an in-flight strategy is the emergency
   machinery, not a strategy-side brick.
2. **The exposed window is already governed.** Between init and execute sit
   voting, the guardian review, and the governor's own execute-time tier
   re-resolution (`TierRegressed` fail-safe) on the batch's targets. A demotion
   in that window is visible to guardians and vetoable; the marginal value of a
   strategy-side re-check at `_execute` is one narrow race (demotion lands
   after review, before execute, and nobody vetoes) against a permanent gas and
   liveness dependency on registry reads in every execute.
3. **The threat model is provenance, and provenance is fixed at init.**
   `swapAdapter` is immutable after `_initialize` (see decision 4), so what the
   check certifies — "governance vouched for this address at the time the
   strategy bound to it" — is decided exactly once. Re-checking does not
   re-decide it; it only converts later registry state changes into new revert
   surfaces.

**Interaction with #137:** #137 makes `isAdapterAllowed` codehash-aware on the
read side. Since this check reads at init, a code swap BEFORE init is caught
once #137 lands (same read, no changes here). A code swap AFTER init is not
caught by this check — that residual belongs to the demotion machinery
(`poke` persists the mismatch, clearing the allowlist for the NEXT strategy)
and to the emergency path for the in-flight one. This is the same residual the
batch guard has between batches, and #137 changes no signature this change
depends on: **no ordering constraint either way.**

## 4. Does `_updateParams` need the same guard?

**No.** `swapAdapter` is written exactly once, at
`PortfolioStrategy.sol:283` inside `_initialize`. `_updateParams` (`:336-371`)
decodes only `(newWeightsBps, newMaxSlippageBps, newSwapExtraData)`; there is
no adapter setter anywhere in the contract, `BaseStrategy` exposes none, and
routes (`swapExtraData`) are frozen post-execute (`RoutesFrozen`) so the
adapter cannot even be steered indirectly through new route bytes. Verified by
reading every write site of `swapAdapter` — the init assignment is the only
one. The spec pins this with a requirement ("the swap adapter binding is
immutable after initialization") so a future setter cannot be added without
tripping the spec.

## 5. `MIN_SLIPPAGE_BPS = 50` — value sanity

**50 bps is sound; keep PR #104's value.**

- **Band check:** `[MIN_SLIPPAGE_BPS, MAX_SLIPPAGE_CEILING_BPS] = [50, 1000]`
  is non-empty and wide; live baskets run 100-500 bps per the ceiling's own
  natspec, comfortably inside.
- **Why a floor at all, on `main` without Lane A:** `rebalanceDelta` floors
  `minOut` against signed oracle marks, so the tolerance must absorb the venue
  fee plus oracle-vs-pool basis; a value below the pool fee (30 bps is the
  common tier used throughout the fork tests) makes every delta swap
  structurally unfillable. `_quoteMinOut` paths degrade too (quote/execution
  discrepancies, multi-hop rounding). 50 ≥ 30 + rounding headroom.
- **Interaction with the tighten-only rule — no unreachable state.** The
  monotonic-decrease guard (`:360-361`) previously bottomed at 1; it now
  bottoms at 50. A strategy initialized at exactly 50 can no longer tighten
  (only re-assert 50, since `==` passes the `>` check) — a bottomed floor, not
  a trap: no sequence of valid updates can enter a state from which no valid
  update exists. The `newMaxSlippageBps == 0` sentinel ("keep current") MUST
  stay outside the floor check, as in PR #104 (`if (newMaxSlippageBps > 0)`
  wraps both bounds) — floor-checking the sentinel would break every
  weights-only update.
- **Irreversibility is the sharp edge being removed:** today a proposer can
  `updateParams` slippage to 1 bp and the tighten-only rule makes that
  permanent, bricking `rebalanceDelta` for the strategy's lifetime while
  `_execute`/`_settle` limp on quotes. The floor turns that from a permanent
  self-brick into a rejected input.
- **"Existing strategy below the new floor" cannot arise.** Strategies are
  per-proposal ERC-1167 clones of an immutable template; this change ships as
  new template bytecode (deployed + approved via `StrategyFactory`), and
  existing clones keep the old template's code and semantics forever. There is
  no in-place upgrade path that could strand a live sub-floor strategy under
  new rules, so no migration or grandfathering clause is needed.
- The init check `maxSlippageBps_ == 0 || … > CEILING` becomes
  `< MIN_SLIPPAGE_BPS || … > CEILING`; the zero case is subsumed (0 < 50) and
  the error stays `InvalidSlippage`, so existing revert-expectation tests hold.

## 6. Test and fixture blast radius

Full sweep of `test/` and `script/` for PortfolioStrategy initializations
(method: `grep -rln PortfolioStrategy test/ script/`, then per-file reading of
the vault fixture, the walk's resolvability, and the slippage argument).

**Break (walk resolves a wired registry; adapter not allowlisted):**

| File | Stack | Verdict |
|---|---|---|
| `test/integration/strategies/PortfolioIntegration.t.sol` | testnet-46630 fork; `deployCore` + `createSyndicate` → per-vault governor has the fresh TierRegistry; adapter = live `UNISWAP_SWAP_ADAPTER` from `chains/46630.json`, never allowlisted | **Relied on the gap.** Add owner-pranked `setAdapterAllowed(swapAdapter, true)` in setUp. |
| `test/integration/strategies/PortfolioMainnetFork.t.sol` | mainnet-4663 fork; same core wiring; adapter freshly `new UniswapSwapAdapter(...)`, never allowlisted | **Relied on the gap.** Same fix. |

Both are RPC-gated (`vm.envOr(..., "")` → `vm.skip(true)`), so CI is green
either way; the breakage is real for local/scheduled fork runs.
**Pre-existing and independent:** at head these suites' execute batches
(`asset.approve(strategy, amount)`) already violate `_guardBatchCalls` for the
same wiring reason (guard+wiring landed `9fafa00` 2026-07-24; suites landed
`a53d040` 2026-07-09) — the strategy CLONE also needs allowlisting for the
batch to pass. Fix in the same setUp edit, but record it as pre-existing.

**Do not break:**

- `test/PortfolioStrategy.t.sol` — `vault = makeAddr("vault")` is codeless →
  hop-1 skip; every init/tighten slippage fixture is 100 bps (the one
  exception, `MAX_SLIPPAGE_CEILING_BPS + 1` at `:648`, still reverts
  `InvalidSlippage` as asserted). The tighten test lands at 99 ≥ 50.
- `test/audit-fixes/Strategy_init_frontrun.t.sol` — codeless `makeAddr` vault,
  slippage 100.
- `test/integration/TierEndToEnd.t.sol` — proposals use `strategy = address(0)`
  with a mock fund-moving adapter; no PortfolioStrategy is ever initialized.
- `test/integration/strategies/UniswapAdapterFork.t.sol` — exercises the
  adapter directly; mentions PortfolioStrategy only in comments.
- `script/` — `DeployTemplates.s.sol` and both `DeployPortfolioStrategy.s.sol`
  deploy template/adapter bytecode without calling `initialize` (the template
  constructor self-locks); `RedeployShimAdapter.s.sol` patches addresses only.

**New tests this change owes** (unit, mock walk — no fork dependency):
non-allowlisted adapter refused at init; allowlisted adapter accepted;
unresolved walk (codeless vault / getterless governor / zero registry) skips;
resolved-but-unreadable registry fails closed; init below the floor refused;
tighten below the floor refused; zero sentinel still means keep-current;
demotion after init does not affect an executed strategy's settle.
