# Tasks

- [ ] 1. Recon: read `docs/robinhood-fork-deployment.md` and scan `docs/` for
  any more canonical deploy runbook; pick the operative one (record choice).
- [ ] 2. Add the "Accepted v1 oracle risks" section per the spec delta
  (clamping, no sequencer-uptime feed, `woodUsdPriceX8` maintenance note),
  written for an operator, with the affected read paths named.
- [ ] 3. Verify: docs-only diff (`git diff --stat` shows only `docs/`),
  `forge build` still clean (proves no accidental source touch).
- [ ] 4. Commit on `docs/accepted-oracle-risks`, push, open PR
  `docs: record the two accepted v1 oracle risks (#34)` — body links
  "Closes #34". Do NOT merge.
