# Tasks

## 1. Challenge-game spec

- [x] 1.1 Filing deadline and reclaim gates include `strategyDuration`.
- [x] 1.2 Challenger bond: `unsharedLiabilityUsd` under `try/catch`, every failure reverts `WoodPriceUnset`; default 150 bps.
- [x] 1.3 `freezeCoverage` on every filing; adapter membership over execute and settlement calls; wiring role checks.
- [x] 1.4 The `NoVotableStake` guard: what it checks, and the stake in the base that cannot vote.

## 2. Docs

- [x] 2.1 `docs/guardian-network.md`, `docs/papers/guardian-network-economic-security.md`, `docs/proposal-lifecycle.md`.
- [x] 2.2 Vote-read bases on v2: which getter each vote path reads; no contract reads `getPastVotes`.
- [x] 2.3 `docs/audit-scope-and-accepted-risks.md`.
