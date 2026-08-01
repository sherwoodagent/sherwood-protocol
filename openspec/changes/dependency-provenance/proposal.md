# Dependency provenance: vendor manifest + CI integrity check

## Why

Closes issue #47 (Trail of Bits guidelines gap). `lib/` vendors 2,844 files
across four dependencies (openzeppelin-contracts 5.6.1,
openzeppelin-contracts-upgradeable 5.6.1, forge-std, LayerZero-v2) with no
`.gitmodules`, no manifest, no integrity check. Nothing proves the tree
matches upstream; a one-line edit to an inherited security property
(`Ownable2Step`, `SafeERC20`, `Checkpoints.Trace224` — load-bearing for the
slash basis) would be invisible in any PR diff after import.

## What changes (issue's option 1 — deliberately NOT submodules/soldeer)

1. `lib/VENDOR-MANIFEST.json`: per dependency — upstream repo URL, tag/commit
   SHA, the subset vendored (if pruned), and any *deliberate local
   modifications* (path + reason; expected: none).
2. `script/check-vendor-provenance.sh`: for each manifest entry, shallow-clone
   the pinned upstream commit and `diff -r` against `lib/<dep>` (excluding
   files the manifest lists as locally modified or pruned). Exit non-zero on
   any divergence, printing the differing paths.
3. New workflow `.github/workflows/provenance.yml` running that script.
   Separate file, NOT ci.yml — open PR #72 (mine) edits ci.yml and this must
   not conflict. Triggers: pull_request paths-filtered to `lib/**` +
   `lib/VENDOR-MANIFEST.json` + the script, plus `workflow_dispatch`, plus a
   monthly schedule (provenance rot is slow; weekly is noise).

## Impact

- New files only, except possibly `.gitignore` (clone scratch dir). No
  contract, test, or existing-workflow changes. Zero overlap with #68, #61,
  #64, #72, or in-flight worktrees.
- Establishing the true upstream pins is the hard part: the implementer must
  IDENTIFY the actual vendored versions (diff candidate upstream tags until
  clean, starting from the versions in the issue) rather than assert them.
  If a dependency does NOT match any upstream ref cleanly, STOP and report
  the divergence in the PR body instead of papering over it — that finding
  is the entire point of the issue.
