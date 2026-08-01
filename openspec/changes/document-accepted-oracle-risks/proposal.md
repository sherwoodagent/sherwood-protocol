# Document two accepted v1 oracle risks

## Why

Closes issue #34. PR #22's oracle hardening (stale feeds book nothing, WOOD
fallback haircut on all degraded branches, `woodPriceDetail()` observability)
makes the *remaining* exposure easy to mistake for zero. Two risks were
accepted, not eliminated, and today they live only in source natspec — not
where reviewers and the deploy operator will look.

## What changes

Documentation only. Add an "Accepted v1 oracle risks" section to the deploy
runbook documentation (locate the operative runbook — candidate:
`docs/robinhood-fork-deployment.md`; if a more canonical mainnet runbook
exists, use that and say so in the PR):

1. **Aggregator clamping** — Chainlink aggregators clamp at
   `minAnswer`/`maxAnswer`. A clamped price *understates* coverage
   (anti-conservative): `coverageUsd` returns less than true value, so
   `requireApproveQuorum` demands less collateral than the risk warrants;
   worst at collapse-pins-feed-at-`minAnswer`, exactly when valuation matters
   most. Affects asset feeds via `coverageUsd` and the WOOD feed via
   `woodPriceX8` (haircut helps, does not bound a clamp).
2. **No sequencer-uptime feed on Robinhood 4663** — the standard L2 gate
   (reject reads during sequencer downtime) cannot be built; a
   fresh-looking read may predate an outage.
3. **Operational note**: `woodUsdPriceX8` must keep being MAINTAINED after a
   Chainlink WOOD feed is wired — a stale feed falls back to it instead of
   reverting, so an abandoned manual number silently values every bond.

## Constraints

- Docs only. Do NOT touch any `.sol` file — `script/DeployPlanB.s.sol` is
  concurrently modified by open PR #64 and the in-flight #30 fix; the source
  natspec already names both risks, so no source change is needed.
- No overlap with protected PR #68 (it touches `docs/product/`,
  `docs/specs/2026-07-24-fee-model-design.md`, `docs/superpowers/plans/` —
  avoid those exact files).

## Impact

`docs/` only; zero code, zero tests (forge suite untouched — run
`forge build` once to prove the tree still compiles unchanged).
