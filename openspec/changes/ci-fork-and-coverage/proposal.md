# CI follow-ups: opt-in fork-test job + coverage reporting

## Why

Closes issue #63 — the two follow-ups deferred from the initial CI pipeline
(#62). Today the fork/integration suites (`test/integration/**`,
`test/WstETHMoonwellStrategy.t.sol`) never run in CI at all, and there is no
coverage signal despite `foundry.toml` already carrying a
`[profile.coverage]` (via_ir off) prepared for exactly this.

## What changes

Two new jobs in `.github/workflows/ci.yml` (or a sibling workflow file if
separation is cleaner — implementer's call, documented in design.md):

1. **Fork tests (opt-in).** Triggered by `workflow_dispatch` and a weekly
   `schedule` cron only — never on PR/push cadence (public-RPC forks are
   rate-limited and nondeterministic). Runs exactly the test set the main job
   excludes. RPC endpoints come from repository secrets with sensible
   fallbacks; the job must fail visibly, not silently skip, when a required
   secret is absent.
2. **Coverage (artifact-only sink).** Runs
   `FOUNDRY_PROFILE=coverage forge coverage` on PR/push alongside the existing
   jobs, uploads the lcov report as a workflow artifact, and prints the
   summary table to the job log. Codecov is deliberately NOT wired: it needs a
   token decision (repo secret) — left as an explicit follow-up note, so the
   sink choice in issue #63 is resolved as "artifact-only now".

## Impact

- Files: `.github/workflows/ci.yml` (and possibly one new workflow file).
  No Solidity, no tests, no deploy scripts — zero overlap with protected PR
  #68 and with the in-flight #69 branch.
- Existing jobs (build-test, fmt, storage-layout, contract-size) unchanged.
