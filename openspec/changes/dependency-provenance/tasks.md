# Tasks

- [ ] 1. Identify true upstream pins: for each of the four deps, determine
  the exact upstream ref the tree matches (start from OZ 5.6.1 / OZ-up 5.6.1
  per remappings + package metadata in lib/; diff to confirm). Record any
  divergence honestly.
- [ ] 2. Write `lib/VENDOR-MANIFEST.json` (repo, ref, sha, pruned paths,
  local modifications).
- [ ] 3. Write `script/check-vendor-provenance.sh` (bash, shallow clone at
  pinned ref into a temp dir, diff -r with exclusions, named output, exit
  codes per spec). Make it runnable locally.
- [ ] 4. Run it locally end-to-end; capture output for the PR body.
- [ ] 5. Add `.github/workflows/provenance.yml` (path-filtered PR trigger +
  workflow_dispatch + monthly off-minute schedule). Validate YAML
  (python3 yaml.safe_load).
- [ ] 6. Commit on `chore/dependency-provenance`, push, open PR
  `chore: vendor manifest + CI provenance check for lib/ (#47)` — body
  "Closes #47", local run evidence, any divergence findings. Do NOT merge.
