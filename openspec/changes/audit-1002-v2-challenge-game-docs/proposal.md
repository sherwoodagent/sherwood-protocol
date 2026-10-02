# Audit 2026-10-02 (post-audit-v2): challenge-game spec and docs match the v2 game

## Why

The challenge-game spec and the guardian docs describe the v2 game in several places it does not
behave. They are the external auditor's requirement baseline for `post-audit-v2`, so they must say
what `src/ChallengeGame.sol` does on this branch.

## What Changes

Documents only. No executable source changes.

- **Admission guard.** `NoVotableStake` at `file` checks that the stake outside the accused cohort is
  at least `challengeQuorumBps` of the base. The spec and docs said it refuses any challenge "no
  conviction could clear". It does not: the base and `votableAtFiling` include stake added after the
  proposal's `snapshotAt` and the stake of the challenger, proposer and co-proposers, none of which can
  vote, while ballots are capped at `snapshotAt`. A filing can be admitted that no set of ballots wins.
- **Price read in `file`.** `unsharedLiabilityUsd` is read inside `try/catch`, and any failure (no WOOD
  price, stale or unconfigured vault-asset feed) reverts `WoodPriceUnset`. The spec said the wrap keeps
  a stale feed from making filing impossible. The filing deadline keeps running during an outage.
- **Deadline.** `executedAt + strategyDuration + challengeWindow`, in `file` and in both reclaim gates
  of `SyndicateGovernor.reclaimProposerBond`; the spec omitted `strategyDuration`.
- **Smaller drift.** Bond default 150 bps; `freezeCoverage` is called on every filing (the refcount
  governs only the unfreeze); the adapter membership test covers execute and settlement calls;
  `setStakedWood` / `setExposureLedger` require the counterpart role (`RoleNotGranted`).
- Docs: `docs/guardian-network.md` (admission guard, early-settle rule, deadline, vote-read bases),
  `docs/papers/guardian-network-economic-security.md` (votable stake and the admission guard),
  `docs/proposal-lifecycle.md` (reclaim deadline). New `docs/audit-scope-and-accepted-risks.md`.

## Capabilities

### Modified Capabilities

- `challenge-game`: filing deadline, challenger bond and price read, freeze on every filing, adapter
  membership over both call legs, the admission guard, wiring role checks, reclaim deadlines.

## Archive order

This change archives cleanly on its own against `openspec/specs/` (checked with
`openspec archive --yes` in a scratch copy). `declared-coverage-locks` also modifies "Challenger bond
sized to the coverage the filing freezes", with text that says the liability read is not wrapped; this
change states what the code does and must be archived after it. "Casting a ballot" is left to
`challenge-ballot-stake-since-propose`, whose text matches the code.

## Impact

`openspec/changes/audit-1002-v2-challenge-game-docs/`, `docs/`. No storage, ABI or behaviour change.
