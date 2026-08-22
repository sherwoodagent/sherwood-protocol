# Tasks

- [x] 1. Recon: read `.github/workflows/ci.yml`, `foundry.toml`
  (`[rpc_endpoints]`, `[profile.coverage]`), and grep the fork suites for the
  env vars / RPC aliases they actually consume.
- [x] 2. Add `.github/workflows/fork-tests.yml`: `workflow_dispatch` +
  weekly `schedule` (off-minute), foundry toolchain pinned to the same
  `FOUNDRY_VERSION` as ci.yml, secrets→env with the fallbacks from design.md
  decision 2, explicit fail-with-name on missing non-fallback secrets,
  `forge test --match-path "{test/integration/**,test/WstETHMoonwellStrategy.t.sol}" -vv`,
  `timeout-minutes: 60`.
- [x] 3. Add `coverage` job to `.github/workflows/ci.yml`:
  `FOUNDRY_PROFILE=coverage forge coverage --report lcov --report summary`
  with the standard fork exclusion, artifact upload of `lcov.info`,
  `continue-on-error: true`, own cache key, `timeout-minutes: 45`, TODO
  comment re Codecov.
- [x] 4. Validate: actionlint or python-yaml both files; run the `--list`
  dry-run and start the local coverage run per design.md; confirm ci.yml diff
  touches only the new job.
- [x] 5. Commit on `feat/ci-fork-and-coverage`, push, open PR
  `ci: opt-in fork-test workflow + coverage artifact (#63)` — body links
  "Closes #63", records the sink decision (artifact-only, Codecov TODO) and
  local verification evidence. Do NOT merge.
