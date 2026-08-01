# supply-chain (delta)

## ADDED Requirement: Vendored dependencies are provably upstream

#### Scenario: clean tree

- **WHEN** `script/check-vendor-provenance.sh` runs on a tree where every
  `lib/` dependency matches its manifest pin
- **THEN** it exits 0 and prints one OK line per dependency with the pinned
  ref.

#### Scenario: tampered dependency

- **GIVEN** any file under `lib/<dep>/` differs from the pinned upstream
  (and is not listed in the manifest as a deliberate local modification)
- **WHEN** the script runs
- **THEN** it exits non-zero and names every differing path.

#### Scenario: CI trigger surface

- **WHEN** a PR touches `lib/**`, the manifest, or the script
- **THEN** the provenance workflow runs on that PR; it also runs on manual
  dispatch and on a monthly schedule (off-minute cron). It does NOT run on
  unrelated PRs (path filter).

#### Scenario: unverifiable pin

- **GIVEN** the implementer cannot find an upstream ref that matches a
  vendored dependency cleanly
- **THEN** the manifest records the closest ref plus the divergence list,
  the PR body reports it prominently as a finding, and the script treats the
  recorded divergence as expected (still failing on anything beyond it).
