# Slash Cap + Age-Weighted Voting + Deterministic Severity

> Migrated from docs/superpowers/plans/2026-07-19-slash-cap-age-weighted-voting.md + docs/superpowers/specs/2026-07-19-slash-cap-age-weighted-voting-design.md (superpowers workflow) on 2026-08-01.

## Why

Three problems in the staking/slashing surface blocked launch:

1. **Delegator over-exposure.** Delegators were slashed at the same blocker-voted severity as their guardian — up to `maxSlashBps` (deployed 9,999 = 99.99%). An industry survey (Cosmos, Polkadot, EigenLayer, Symbiotic, Chainlink, The Graph, Livepeer, Rocket Pool, Lido, Babylon) found no protocol exposing delegators to near-total loss; Sherwood was an outlier, making delegation economically irrational — and delegation had to ship enabled at launch.
2. **Flash-stake voting.** Vote weight was instant at stake time: fresh capital staked just before a snapshot wielded full weight with a 7-day exit.
3. **Adversarially-voted severity.** Slash severity was the stake-weighted median of the *blockers'* proposed `slashBps` — the winning side of a dispute picked the losers' penalty per-incident, with no industry precedent; a whale blocker could dominate the median.

A naive delegated-slash cap alone opens a sybil hole (Livepeer LIP-10 rationale): stake `minGuardianStake` from wallet A, delegate the rest from wallet B, keep full vote weight while capping most exposure. The design closes this with a first-loss spill onto the guardian's own stake plus a delegated-weight cap keyed to the guardian's **aged** own weight.

## What Changes

- **Part A — delegated-slash cap + first-loss spill** (`StakedWood._slashOne`). New `maxDelegatedSlashBps` (C, default 2,000 = 20%, strictly < 10,000 — the relocated C-2 pool-bricking guard): pool legs are sized by `min(S, C)`; the uncovered delegated remainder spills onto the approver's own remaining stake (Rocket Pool first-loss-bond pattern), clamped at what is left. `maxSlashBps` relaxed to a full 10,000 (own stake is a plain integer, no share math). Own-slash basis switched to the raw own-stake checkpoint at `openedAt` (age discounts voting power, not liability); `voteStake`/`recordVoteStake` deleted.
- **Part B — age-weighted own-stake voting.** Linear discount-to-par read-time age factor: weight ramps from `ageFloorBps` (default 2,500 = 25%) at age 0 to par at `maturationPeriod` (default 30 days), then plateaus. `stakedAt` lifecycle: weighted-average re-anchor on top-up (ceil toward `now` — rounding never grants age), reset on `requestUnstakeGuardian` (no free age-parking), untouched on slash.
- **Part C — delegated-weight cap.** `getPastVotes = agedOwn + min(delegatedInbound, k × agedOwn)` with `delegatedWeightCapX` (k, default 4). Cap base is *aged* own weight so delegation cannot bypass maturation. Quorum denominators stay raw (conservative). The cap bounds voting power only — the pool's slashable base stays the raw inbound snapshot.
- **Part D — deterministic slash severity** (`GuardianRegistry`). `voteOnProposal` drops the `slashBps` argument; `blockerSlashBps` and the O(n²) `_weightedMedianSlashBps` are deleted, replaced by pure `_severityBps`: a quadratic ramp in block-side decisiveness from `minSlashBps` at the at-open block quorum to `maxSlashBps` at `SUPERMAJORITY_BPS = 6_667` (2/3), with a degenerate-quorum guard.
- Four new owner-set protocol-global parameters with `InitParams` fields, bounds validation, `PARAM_*` keys and `ParameterChangeFinalized` events; `__gap` 12 → 8; deploy scripts updated; ~20 test files swept (`InitParams` literals, `voteOnProposal` arity); new invariants (aged-weight bounds, relocated C-2 pool guard). `StakedWoodDelegation.sol` untouched.

## Capabilities

- guardian-staking

## Impact

- `src/StakedWood.sol` — 4 new params + setters + `InitParams` fields; `maxSlashBps` bound relaxed to `<= 10_000`; `_ageFactorBps` helper; aged/capped `getPastVotes`; top-up `stakedAt` average; reset on `requestUnstakeGuardian`; `_slashOne` rework (raw own basis, C cap, spill); `voteStake`/`recordVoteStake` deleted; `__gap` 12 → 8
- `src/GuardianRegistry.sol` — `slashBps` dropped from `voteOnProposal`; `blockerSlashBps` + `_weightedMedianSlashBps` deleted; `SUPERMAJORITY_BPS` + `_severityBps` added; `recordVoteStake` mirror calls removed (registry's own `_voteStake` stays — Merkl attribution reads it)
- `src/interfaces/IGuardianRegistry.sol` — `voteOnProposal` signature change (3 args)
- `script/Deploy.s.sol`, `script/testnet/Deploy.s.sol`, `script/robinhood-testnet/Deploy.s.sol` — new `InitParams` fields + defaults, `maxSlashBps` 10,000
- `test/StakedWoodAgeWeight.t.sol` (new), `test/GuardianRegistrySeverity.t.sol` (new), `test/StakedWoodSlashing.t.sol` (cap/spill matrix), invariant suites, ~20 mechanical sweep files
- Note: post-archive, DPoS delegation was removed entirely (decision 2026-07-26, see `openspec/changes/archive/2026-07-22-guardian-econ-security-A-execution-safety/design.md` §3.3) — the delegated-slash-cap and delegated-weight-cap surfaces of this change no longer exist in current code; the age-weighting, raw-own slash basis, and deterministic severity survive
