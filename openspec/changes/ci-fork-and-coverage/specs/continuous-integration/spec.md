# continuous-integration (delta)

## ADDED Requirement: Fork tests run on demand, never on PR cadence

The CI pipeline SHALL provide an opt-in job that runs the fork/integration
test set excluded from the PR-cadence test job.

#### Scenario: manual dispatch

- **WHEN** a maintainer triggers the workflow via `workflow_dispatch`
- **THEN** the job runs `forge test --match-path "{test/integration/**,test/WstETHMoonwellStrategy.t.sol}"`
  with RPC endpoints sourced from repository secrets
  (`BASE_RPC_URL`, `ROBINHOOD_RPC_URL`), and reports pass/fail normally.

#### Scenario: scheduled run

- **WHEN** the weekly `schedule` cron fires
- **THEN** the same fork-test job runs, so rot in the fork suites is noticed
  within a week rather than at the next manual run.

#### Scenario: PR opened

- **WHEN** a pull request is opened or updated
- **THEN** the fork-test job does NOT run (PR checks stay deterministic).

#### Scenario: missing secret

- **GIVEN** a required RPC secret is unset and no public fallback is defined
  for that endpoint
- **THEN** the job fails with an explicit message naming the missing secret —
  it does not silently pass or skip.

## ADDED Requirement: Coverage is measured and published as an artifact

#### Scenario: coverage on PR

- **WHEN** a pull request is opened or updated
- **THEN** a coverage job runs `forge coverage` under
  `FOUNDRY_PROFILE=coverage` (the via_ir-off profile in `foundry.toml`),
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
