# Supply Chain Specification

## Purpose

Requirements on provenance verification for vendored dependencies under `lib/`, so a compromised or silently-modified upstream dependency is caught by CI rather than trusted implicitly.

## Requirements

### Requirement: Vendored dependencies are provably upstream
`script/check-vendor-provenance.sh` SHALL verify every `lib/` dependency against a pinned-ref manifest (`lib/VENDOR-MANIFEST.json`), exiting 0 only when every dependency matches its pinned upstream ref exactly (or matches a manifest-recorded deliberate local modification). A CI workflow SHALL run this check on PRs touching `lib/**`, the manifest, or the script itself, plus manual dispatch and a monthly off-minute cron schedule, and SHALL NOT run on unrelated PRs.

#### Scenario: Clean tree
- **WHEN** `script/check-vendor-provenance.sh` runs on a tree where every `lib/` dependency matches its manifest pin
- **THEN** it exits 0 and prints one OK line per dependency with the pinned ref

#### Scenario: Tampered dependency
- **GIVEN** any file under `lib/<dep>/` differs from the pinned upstream (and is not listed in the manifest as a deliberate local modification)
- **WHEN** the script runs
- **THEN** it exits non-zero and names every differing path

#### Scenario: CI trigger surface
- **WHEN** a PR touches `lib/**`, the manifest, or the script
- **THEN** the provenance workflow runs on that PR; it also runs on manual dispatch and on a monthly schedule
- **AND** it does NOT run on unrelated PRs

#### Scenario: Unverifiable pin
- **GIVEN** a vendored dependency has no upstream ref that matches it cleanly
- **THEN** the manifest records the closest ref plus the divergence list, and the script treats the recorded divergence as expected — still failing on anything beyond it
