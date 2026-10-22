# Design

## Decisions

1. **Separate workflow file for fork tests** (`.github/workflows/fork-tests.yml`).
   `workflow_dispatch`/`schedule` triggers on the main `ci.yml` would give every
   job in it those triggers or force `if:` guards on each — a separate file
   keeps the trigger surface honest. Coverage joins `ci.yml` as a sibling job
   (same triggers as the existing ones).
2. **Secrets → env mapping with public fallbacks.** `BASE_RPC_URL` falls back to
   `https://mainnet.base.org`, `ROBINHOOD_RPC_URL` falls back to
   `https://rpc.mainnet.chain.robinhood.com` (both already public knowledge in
   this repo's scripts). `TENDERLY_*` has no public fallback: guard the steps
   that need it with an explicit check that fails with the secret's name.
   Inspect the fork suites (grep `envString|envOr|vm.createSelectFork|rpcUrl`)
   to learn the exact env names tests read — do not guess; mirror what
   `foundry.toml`'s `[rpc_endpoints]` and the test files actually consume.
3. **Weekly cron on an off-minute** (e.g. `23 6 * * 1`), per scheduling
   hygiene; concurrency group separate from the PR group.
4. **Coverage job**: `FOUNDRY_PROFILE=coverage forge coverage --report lcov
   --report summary` with the same `--no-match-path` exclusion as build-test;
   upload `lcov.info` via `actions/upload-artifact@v4` (retention ~14 days);
   `continue-on-error: true` initially (spec's advisory scenario). Own cache
   key (`forge-coverage-…`) — the coverage profile's artifacts differ from the
   default profile's, so sharing the build cache would thrash it.
5. **Timeouts.** Fork job `timeout-minutes: 60`; coverage `timeout-minutes: 45`
   (coverage instrumentation is slow on a suite this size).
6. **Codecov: not wired.** Left as a one-line TODO comment in the workflow.

## Verification (no GH runner locally)

- YAML validity: `actionlint` if available, else `python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" <file>` for each workflow file.
- Command dry-runs locally: `FOUNDRY_PROFILE=coverage forge coverage --report summary
  --no-match-path "{test/integration/**,test/WstETHMoonwellStrategy.t.sol}"`
  must at least start instrumenting (kill after it proves viable if wall-clock
  is prohibitive; record the observation in the PR). `forge test --match-path
  "{test/integration/**,test/WstETHMoonwellStrategy.t.sol}" --list` must list
  the expected suites.
- The main `ci.yml` jobs must be byte-identical except for the added coverage
  job (diff discipline: no drive-by edits).
