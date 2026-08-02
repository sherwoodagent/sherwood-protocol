# Lane A Enablement — Design

## Context

See proposal.md for motivation. Current state that shapes the approach:

- `PriceRouter` is deployed-ready and fail-closed everywhere; its `setHaircutBps` natspec documents a known **one-sided haircut asymmetry**: the haircut conservatively marks `totalAssets()`, which is correct for redemptions but inverts for Lane A deposits (mints against understated NAV). In-tree guidance: haircut stays 0 for any `laneAEnabled` kind until a two-sided quote exists.
- `BaseStrategy.positions()` defaults to empty (Lane B); `availableLiquidity()`/`withdrawTo()` default to zero/no-op. Strategies opt in by overriding all three.
- `PortfolioStrategy` already holds per-slot Chainlink push-feed wiring (`_feedIds[i]` packs aggregator address + max-age in the upper 96 bits) and a swap-adapter path (Synthra/Uniswap) used by execute/settle/rebalance, with a `maxSlippageBps` bound.
- The vault's instant-exit path pulls exactly the shortfall via `IStrategy.withdrawTo` and verifies delivery by balance difference, reverting `UnwindShortfall` on under-delivery.
- Instant exits already crystallize an instant-exit fee (see `openspec/specs/instant-exit-fees/`), which is a second lever (besides haircut) for covering unwind slippage.
- Morpho Blue is live on Robinhood Chain at `0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010`; loan side is USDG. Tokenized stocks are plain ERC-20s.

## Goals / Non-Goals

**Goals:**
- First production `IPriceAdapter`s and first Lane-A-capable strategies, conforming to the three new capability specs.
- Parameter recommendations (haircut, instant cap, exit-fee sizing) backed by measured Robinhood DEX depth and an explicit adversary-cost model.
- Three workstreams implementable in parallel with a small shared kernel (kind constants, adapter test harness).

**Non-Goals:**
- No changes to `PriceRouter`, `SyndicateVault`, or governor bytecode. The two-sided quote interface change stays a follow-up proposal if the analysis shows it is needed.
- No perps or LP-token pricing; no changes to Lane B queue mechanics.

## Decisions

**D1 — Position kinds.** `keccak256("ERC20_SPOT")` and `keccak256("MORPHO_BLUE_SUPPLY")`, defined once in a shared `PositionKinds` library so adapters, strategies, tests, and deploy scripts agree. Alternative (inline literals per contract) rejected: silent kind mismatch is exactly the failure the fail-closed router would mask as "Lane A mysteriously never opens".

**D2 — Feed selection lives in the adapter, not the position.** `Erc20SpotAdapter` keeps an owner-maintained `token → (aggregator, maxAge)` registry; `Position.ref` cannot choose the feed. Rationale: a strategy controls its `positions()` output, so a `ref`-borne feed locator would let a malicious proposer price token X with token Y's feed (real balance, wrong price). Guardian review of strategy code is the outer defense; the registry makes the adapter safe even against an unreviewed strategy. Cost: duplicate feed config (strategy for rebalancing, adapter for NAV) — acceptable; they serve different trust domains and both are governance-set. Alternative (trust `ref`, rely on guardian review) rejected as single-layered.

**D3 — Haircut stays 0; slippage is covered by instant cap + instant-exit fee.** Per the router's own asymmetry note, a nonzero haircut on a Lane-A-enabled kind is a wealth transfer to depositors. Instead: `instantCap` bounds the single-position size Lane A will price (sized from measured DEX depth so a full instant unwind stays inside the strategy's `maxSlippageBps`), and the existing instant-exit fee is checked (workstream 3) against the worst-case oracle-vs-execution gap. If the analysis finds the fee lever insufficient, the follow-up is the two-sided-quote router change — not a nonzero haircut.

**D4 — `withdrawTo` unwind order: idle balance, then pro-rata basket sales.** Pro-rata (by current value) rather than cheapest-first keeps basket weights unchanged by exits, so an instant exit does not silently re-tilt the remaining LPs' portfolio. Each sale enforces the strategy's existing `maxSlippageBps` against the Chainlink mark; any leg failing the bound reverts the whole withdrawal (spec: no partial delivery). Reuses the existing swap-adapter path and per-token `swapExtraData` routes frozen at proposal review.

**D5 — Rebalance-in-progress closes Lane A.** `positions()` returns empty while a rebalance is mid-flight. A transiently distorted basket (sell leg done, buy leg pending) would price wrong; fail-closed is one flag check. The vault degrades to float-only NAV for the duration — consistent with the epoch-nav spec's degradation ladder.

**D6 — Morpho valuation via view interest accrual.** `MorphoSupplyAdapter` pins the canonical Morpho address as an immutable, takes the market id from `Position.ref`, verifies the market's loan asset matches the vault asset being valued, and computes `supplyShares → assets` with view-side interest accrual (the `expectedSupplyAssets` pattern from Morpho's periphery libs, reimplemented locally — no new external dependency at runtime, vendored math only). Alternative (call a deployed Morpho lens) rejected: extra live dependency for math we can compute from `market()` state.

**D7 — Parallelization plan.** Shared kernel first (kinds library + adapter test harness), then three independent tracks: (A) `Erc20SpotAdapter` + `PortfolioStrategy` overrides, (B) `MorphoSupplyStrategy` + `MorphoSupplyAdapter`, (C) fork-pinned analysis. A and B touch disjoint files after the kernel; C is read-only against a pinned Robinhood fork. Builds on this machine must be serialized (single `via_ir` solc at a time — known OOM constraint), so "parallel" means independent agents/branches, foreground builds, one at a time.

**D8 — Analysis method (workstream 3).** On a pinned Robinhood Chain fork: (1) enumerate DEX pools for each candidate tokenized stock and USDG; (2) measure execution price for exit sizes across a grid (1k → pool-depth USD) via on-fork swap quotes; (3) compute adversary profit per size: oracle-mark payout − real unwind proceeds − instant-exit fee; (4) recommended `instantCap` = largest size where adversary profit ≤ 0 with margin, per token; (5) stress with oracle price staled to the max age bound. Deliverable: a report in the change dir + concrete `setInstantCap`/fee parameters + go/no-go on whether the two-sided quote change is required before mainnet enablement.

**D9 — Post-analysis addendum (workstream C results, block 25,280,017).** Chainlink equity feeds exist on 4663 (34 "Robinhood <TICKER>/USD" push feeds, 8-dec, 24h heartbeat, 0.5% deviation) — no feed blocker. Four consequences bind implementation: (a) `SyndicateVault.instantExitFeeBps` defaults to 0 and no deploy path sets it — `setInstantExitFeeBps(200)` (the cap) is a hard precondition for enablement; at fee 0 Lane A is riskless arbitrage (oracle sat ~40bps over pool at rest). (b) Per-token instant caps live in the adapter registry, not the router (router caps are per-kind; token depths differ 13×). (c) The adapter carries an oracle-vs-pool divergence gate (reference pool + ≤100bps bound) — the fee ceiling cannot cover stale-mark regimes (weekend hold-last-price). (d) Recommended params (b=100bps design point): NVDA $100k, AAPL $25k, TSLA $7.5k, AMD excluded; MORPHO_BLUE_SUPPLY $250k ops bound; `maxSlippageBps = 150`. GO without the two-sided-quote router change, conditional on G1–G4 (fee=200, haircut=0, staleness ≤24h, divergence ≤100bps). Full report: `analysis/lane-a-parameters.md`.

## Risks / Trade-offs

- [Oracle-vs-pool divergence arb: exit at fresh oracle mark, vault unwinds into a thinner/worse pool] → instantCap sized from measured depth (D8), instant-exit fee as the pricing wedge, `maxSlippageBps` reverts the worst cases outright.
- [Lane A deposit-side inversion if any haircut is ever set] → D3 pins haircut to 0 for these kinds; deploy script asserts it; operator docs state the invariant and its adversary.
- [Equity feeds freeze outside market hours → Lane A closes nights/weekends] → accepted by design (fail-closed); documented for operators and LPs so it reads as intended behavior, not an outage.
- [Morpho utilization spikes between `availableLiquidity()` read and `withdrawTo` execution] → same-tx revert on under-delivery (vault's balance-difference check); no stale-quote window survives.
- [Pro-rata multi-leg unwind gas: N swaps in one exit tx] → bounded by the existing basket size cap (`TooManyTokens`); measured in fork tests; instantCap keeps single exits small anyway.
- [Duplicate feed config (strategy vs adapter) drifting apart] → deploy script cross-checks both registries at wiring time; drift only degrades to Lane B, never misprices.

## Migration Plan

1. Merge contracts + tests (no live effect: kinds unregistered, Lane A disabled — router is fail-closed by default).
2. Testnet (46630): deploy adapters, register kinds, seed feed registry, enable Lane A, run a full proposal lifecycle with instant entry/exit.
3. Analysis report reviewed; parameters chosen.
4. Mainnet (4663): register adapters, set instantCaps and feed registry per report, `setLaneAEnabled` last (the activation switch). Rollback = `setLaneAEnabled(kind, false)` — instant, reversible, degrades every vault to Lane B with no stranded state.

## Open Questions

- Which tokenized stocks have live Chainlink push feeds on Robinhood Chain, and their heartbeat/deviation configs — enumerated during workstream 3; gates the initial basket allowlist, not the design.
- Whether USDG needs its own feed entry or is treated as the unit of account (if vault asset = USDG, its "price" is 1 by definition) — resolve in workstream A implementation against the actual vault asset choice.
