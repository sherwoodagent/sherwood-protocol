# Tenderly vnet integration runner — Leveraged Aerodrome CL (PR #388)

`run-leveraged-aero.sh` stands up a Tenderly Virtual TestNet (a Base mainnet fork) and runs the
**leveraged Aerodrome CL strategy's fork suite** against it — the empirical "does the deployed
protocol behave on infrastructure that mirrors mainnet" signal for PR #388.

## Why this shape

The PR's fork suite is **already vnet-aware**: `LeveragedAeroForkBase` reads `TENDERLY_FORK_RPC_URL`,
forks it (unique chainId `9998453`), funds accounts via `vm.rpc("tenderly_setErc20Balance", …)`, and
`LeveragedAeroCL.e2e.fork.t.sol` deploys the **entire protocol** on the fork (governor + factory →
vault → clone + init strategy → propose/vote/execute → deposit / deployIdle / compound / rerange /
deleverage / redeem → settle). So the "vnet harness" here is simply: point that suite at a clean vnet
and run it. This reuses the PR's own comprehensive tests instead of re-deriving the governor-gated
lifecycle as broadcast transactions.

## Usage

```bash
# from the repo root or anywhere:
./contracts/script/tenderly/run-leveraged-aero.sh            # fresh vnet if creds present, else reuse
./contracts/script/tenderly/run-leveraged-aero.sh --reuse    # force reuse TENDERLY_FORK_RPC_URL from .env
./contracts/script/tenderly/run-leveraged-aero.sh --keep     # keep a freshly-created vnet for inspection
./contracts/script/tenderly/run-leveraged-aero.sh --match 'test/integration/strategies/LeveragedAeroCL.e2e.fork.t.sol'
```

Requires `forge`, `cast`, `jq`, `curl`.

## Modes

- **Fresh vnet (default, recommended)** — needs `TENDERLY_ACCESS_KEY` in `contracts/.env`. The runner
  creates a fresh Base-fork vnet (account/project slugs derived from `TENDERLY_FORK_RPC_URL`), runs the
  suite, and deletes the vnet on exit (`--keep` to retain). Deterministic: fresh feeds, no clock drift.
- **Reuse** — needs only `TENDERLY_FORK_RPC_URL`. Runs against the existing vnet. This is the automatic
  fallback when `TENDERLY_ACCESS_KEY` is absent. Add the access key to enable fresh-vnet mode.

## What it covers (52 tests, all green as of this branch)

`LeveragedAeroCL.{deploy,deposit,leverage,redeem,rerange,compound,e2e}.fork.t.sol` +
`LeveragedAeroValuation.fork.t.sol`, including:

- **e2e full lifecycle** — deploy → execute (open the net-short levered book) → deposit → deployIdle →
  compound (AERO → USDC) → rerange (no-swap recenter) → deleverage (adverse move) → redeem → settle.
- **net-short thesis / health** — LTV within target ±bounds, health ≥ min; permissionless `deleverage`
  restores health after an adverse Chainlink move (BTC ×3); oracle floor bites under manipulation.
- **manipulation resistance** — oracle NAV invariant under a pool tick-shove while the naive slot0 NAV
  drifts; calm-gate fails closed on a large shove.
- **fail-closed valuation** — reverts on sequencer-down / stale feed; redeem still works while stale.
- **IL & fees** — settle covers shortfall under impermanent loss; performance fee on compounded yield.

## Notes

- Price moves in the suite: `_shoveTick` (real CL-router swaps move the pool) + `vm.mockCall` on the
  Chainlink feeds (in-process). Because these are in-process fork tests (not broadcast), the mock is
  local to the test process — no on-chain oracle override is needed. Moonwell's oracle and the
  strategy read the same Chainlink feeds, so a mocked move is coherent across both in-process.
- Run logs (`leveraged-aero-harness.log`, `.leveraged-aero-forge.log`) are gitignored.
