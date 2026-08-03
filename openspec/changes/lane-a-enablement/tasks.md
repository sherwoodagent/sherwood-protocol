# Lane A Enablement — Tasks

Groups 2, 3, and 4 are the three parallel workstreams (design D7); each depends only on group 1. Group 5 integrates. Builds on this machine serialize solc (one via_ir build at a time).

## 1. Shared kernel

- [x] 1.1 Add `PositionKinds` library defining `ERC20_SPOT` and `MORPHO_BLUE_SUPPLY` kind constants (design D1)
- [x] 1.2 Add adapter test harness: mock AggregatorV3 (settable answer/updatedAt), mock ERC-20s with configurable decimals, and a `PriceRouter` fixture with registration helpers (existing mocks reused; new `test/helpers/LaneAFixture.sol`)
- [x] 1.3 Verify `forge build` and existing suite green with kernel in place

## 2. Workstream A — ERC20 spot adapter + PortfolioStrategy Lane A

- [x] 2.1 Implement `Erc20SpotAdapter` with governance-owned `token → (aggregator, maxAge)` feed registry; fail-closed on unregistered token, stale/non-positive/incomplete round, undecodable input (spec: erc20-spot-pricing) (+ per-token caps and divergence gate per D9; per-numeraire deployment, numeraire prices at par)
- [x] 2.2 Unit tests: decimal matrix (token 6/8/18 × feed 8/18), staleness boundary, broken-feed catch, unregistered token, wrong-feed adversary blocked by registry (design D2) (43 tests green)
- [x] 2.3 Override `PortfolioStrategy.positions()`: one `ERC20_SPOT` position per basket slot in executed state; empty before execute, after settle, and while rebalance is mid-flight (design D5)
- [x] 2.4 Override `PortfolioStrategy.availableLiquidity()`: idle balance + conservative swap-quote estimate, degrade to idle-only when quoting unavailable (also degrades in Data Streams mode — no on-chain mark)
- [x] 2.5 Override `PortfolioStrategy.withdrawTo()`: idle first, then pro-rata basket sales bounded by `maxSlippageBps`; revert on any shortfall, no partial delivery (design D4)
- [x] 2.6 Integration test: full vault lifecycle — deposit, propose, execute basket, Lane A opens, instant exit pulling shortfall through basket sale, settle; plus Lane-A-closes cases (stale feed, rebalance in flight) (real vault+router+adapter+strategy, governor mocked per sanctioned fallback; 4 tests green + regressions)

## 3. Workstream B — Morpho supply strategy + adapter

- [x] 3.1 Vendor minimal Morpho Blue interfaces + shares/interest math needed for view-side `expectedSupplyAssets` (design D6; no runtime dependency on periphery deployments) (`src/vendor/morpho/`, GPL-2.0-or-later per upstream)
- [x] 3.2 Implement `MorphoSupplyStrategy` (extends `BaseStrategy`): market fixed at init with loan-asset == vault-asset validation; execute supplies, settle fully unwinds; `positions()` returns one `MORPHO_BLUE_SUPPLY` position; `availableLiquidity()` = min(supply value, market unborrowed liquidity); `withdrawTo` same-tx exact delivery (+ `MarketNotCreated` init check)
- [x] 3.3 Implement `MorphoSupplyAdapter`: canonical Morpho address immutable, market id from `ref`, loan-asset check, view accrual valuation; fail-closed on wrong venue/market (+ kind and vault-numeraire mismatch fail-closed)
- [x] 3.4 Unit tests against a mock Morpho (settable market state): valuation with pending interest, utilization-capped liquidity, wrong-venue/wrong-market fail-closed (38 tests green)
- [x] 3.5 Fork test (pinned Robinhood block): supply → accrue → value via router → instant exit → settle against live Morpho `0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010` (block 25,290,555, market `0x0309c0…4114`; NOTE: public RPC prunes state — reruns need archive endpoint)

## 4. Workstream C — Haircut/arbitrage analysis

- [x] 4.1 Enumerate live Chainlink push feeds for tokenized stocks on Robinhood Chain (heartbeat, deviation, decimals) and the DEX pools (Synthra/Uniswap) pairing each candidate token with USDG/WETH; record depth snapshot at a pinned block (block 25,280,017; 34 equity feeds found)
- [x] 4.2 Fork-measure execution price vs oracle mark across an exit-size grid per token; produce slippage curves (TSLA/AAPL/NVDA/AMD)
- [x] 4.3 Model adversary profit per size: oracle-mark payout − unwind proceeds − instant-exit fee; include stale-to-max-age oracle stress (design D8)
- [x] 4.4 Write report in change dir: recommended per-token `instantCap`, instant-exit-fee adequacy verdict, haircut-stays-0 confirmation (design D3), go/no-go on two-sided-quote follow-up (analysis/lane-a-parameters.md; GO conditional on G1–G4)
- [x] 4.5 Encode recommendations as a parameter table consumable by the deploy/ops script in group 5

## 5. Integration, wiring, docs

- [x] 5.1 Deploy/ops script additions: deploy both adapters, register kinds, seed feed registry (feeds + per-token caps + divergence pools per analysis table), set `instantExitFeeBps = 200` on Lane A vaults (design D9 precondition — default 0 is riskless arbitrage), assert `haircutBps == 0` for both kinds, `setLaneAEnabled` last as activation switch (design Migration Plan); cross-check strategy vs adapter feed registries (`script/DeployLaneA.s.sol`)
- [x] 5.2 End-to-end test on testnet-shaped fixture: both strategies through full proposal lifecycle with Lane A entry/exit, degradation ladder exercised (disabled kind, unregistered adapter, stale feed) (`test/integration/LaneAWiring.t.sol`, 21 tests)
- [x] 5.3 Operator docs: Lane A activation runbook, market-hours closure behavior, rollback via `setLaneAEnabled(kind, false)`, parameter table from 4.5 (`docs/lane-a-runbook.md`)
- [x] 5.4 `forge build`, `forge fmt`, full `forge test` green; run `openspec validate --strict` on this change (post-rebase on main: 1680 pass / 9 fail — failures identical to pre-existing main baseline routing set; fmt check clean; validate strict clean)
