# continuous-integration (delta)

## ADDED Requirements

### Requirement: Fork tests run on demand, never on PR cadence

The CI pipeline SHALL provide an opt-in job that runs the fork/integration
suites (`test/integration/**`) that the PR-cadence test job excludes.

#### Scenario: manual dispatch

- **WHEN** a maintainer triggers the workflow via `workflow_dispatch`
- **THEN** the job runs `forge test --fork-url "$BASE_RPC_URL" --match-path "{test/integration/**,test/WstETHMoonwellStrategy.t.sol}"`
  with RPC endpoints sourced from repository secrets
  (`BASE_RPC_URL`, `ROBINHOOD_RPC_URL`), and reports pass/fail normally.
  (`test/WstETHMoonwellStrategy.t.sol` no longer exists; the glob keeps the
  two path filters complementary.)

#### Scenario: scheduled run

- **WHEN** the weekly `schedule` cron fires
- **THEN** the same fork-test job runs, so rot in the fork suites is noticed
  within a week rather than at the next manual run.

#### Scenario: PR opened

- **WHEN** a pull request is opened or updated
- **THEN** the fork-test job does NOT run (PR checks stay deterministic).

#### Scenario: unset secret

- **GIVEN** an RPC secret is unset
- **THEN** the job uses that endpoint's public fallback
  (`https://mainnet.base.org` for `BASE_RPC_URL`,
  `https://rpc.mainnet.chain.robinhood.com` for `ROBINHOOD_RPC_URL`), so a
  dispatch works before any secret is configured.

### Requirement: Coverage is measured and published as an artifact

The CI pipeline SHALL measure coverage on every pull request and publish the
lcov report as a workflow artifact. The job MAY be advisory rather than
blocking, but its status SHALL remain visible in the checks list.

#### Scenario: coverage on PR

- **WHEN** a pull request is opened or updated
- **THEN** a coverage job runs `forge coverage` under
  `FOUNDRY_PROFILE=coverage` (the profile in `foundry.toml` that turns via_ir
  off by default and keeps the contracts too large for legacy codegen on the
  IR pipeline through per-file `compilation_restrictions`),
  excluding the same fork-test paths the main test job excludes, prints the
  summary table in the job log, and uploads the lcov report as a workflow
  artifact.

#### Scenario: coverage failure is visible but advisory

- **GIVEN** the coverage tool crashes (forge coverage is the least stable
  forge subcommand)
- **THEN** the coverage job may be marked non-blocking (`continue-on-error`)
  so it cannot hold PRs hostage — but its failure status is still visible in
  the checks list. Whether to make it blocking is revisited once it proves
  stable.
