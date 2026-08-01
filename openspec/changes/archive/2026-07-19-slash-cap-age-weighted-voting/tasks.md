# Tasks — Slash Cap + Age-Weighted Voting + Deterministic Severity

> Historical record; all work merged from branch `feat/slash-cap-age-weighted-voting`. Constants used throughout (deployed defaults): `maxDelegatedSlashBps = 2_000`, `ageFloorBps = 2_500`, `maturationPeriod = 30 days`, `delegatedWeightCapX = 4`, `SUPERMAJORITY_BPS = 6_667`.

## 1. New parameters, InitParams, setters, bound relaxation

- [x] 1.1 Write failing tests in `test/StakedWood.t.sol`: `maxSlashBps = 10_000` now valid at initialize; `maxDelegatedSlashBps = 10_000` or `> maxSlashBps` reverts `InvalidParameter`; setter bounds + `ParameterChangeFinalized` events for all four new params; `setMaxSlashBps` guards `maxDelegatedSlashBps <= maxSlashBps`
- [x] 1.2 Add `PARAM_MAX_DELEGATED_SLASH_BPS` / `PARAM_AGE_FLOOR_BPS` / `PARAM_MATURATION_PERIOD` / `PARAM_DELEGATED_WEIGHT_CAP_X` keys, storage (4 slots, `__gap` 12 → 8), `InitParams` fields, initialize validation (C-2 pool-bricking guard relocated to `maxDelegatedSlashBps < 10_000`), and the four owner setters
- [x] 1.3 Sweep every `StakedWood.InitParams` literal (deploy scripts with new `DEFAULT_*` constants and `maxSlashBps` bumped to 10_000; testnet/robinhood-testnet scripts + `_checkUint` blocks; ~20 test files); invert the old C-2 initialize-revert test in `test/StakedWoodSlashing.t.sol`
- [x] 1.4 Build + run `test/StakedWood*.t.sol`; pre-existing suite green (params exist, nothing reads them yet); commit

## 2. Age factor + aged own weight in vote reads (Part B read path)

- [x] 2.1 Write failing tests in new `test/StakedWoodAgeWeight.t.sol`: floor at stake (25%), linear midpoint (62.5% at 15 d), par at/beyond maturation, past reads compute age to the requested timestamp, totals stay raw
- [x] 2.2 Implement `_ageFactorBps(uint64 stakedAt, uint256 ts)` (linear discount-to-par, saturates to age 0 on `ts < stakedAt` — deflation-only drift) and apply the aged own term in `getPastVotes`; natspec documents raw-denominator quorum conservatism
- [x] 2.3 Repair pre-existing weight assertions (add `skip(30 days)` in setup helpers so guardians vote at par, except young-stake-specific tests); full suite green; commit

## 3. `stakedAt` lifecycle — top-up average + reset on unstake request

- [x] 3.1 Write failing tests: weighted-average age on top-up; whale top-up does not inherit a 1-wei tranche's age (ceil toward `now`); request → cancel round-trip restarts the age clock
- [x] 3.2 Implement in `stakeAsGuardian` (average computed with the OLD stake before writing the new total; ceil-divide toward `now`) and `requestUnstakeGuardian` (`stakedAt = now` — no free age-parking while unvotable)
- [x] 3.3 Full suite green (cancel-flow tests assuming preserved weight repaired); commit

## 4. Delegated-weight cap (Part C)

- [x] 4.1 Write failing tests: inbound capped at `k × agedOwn`; under-cap counts flat; cap base scales with age (delegation cannot bypass maturation)
- [x] 4.2 Final `getPastVotes`: `agedOwn + min(delegated, delegatedWeightCapX × agedOwn)` — cap bounds voting power only, slashable base stays the raw inbound snapshot
- [x] 4.3 Full suite green (delegation-weight expectations updated for the k-cap where inbound was large relative to own); commit

## 5. `_slashOne` rework — raw own basis, C cap, first-loss spill (Part A)

- [x] 5.1 Write failing tests in `test/StakedWoodSlashing.t.sol`: S < C no spill; S > C spill covered by own stake; spill clamped at remaining own stake (sybil shape, own wiped); full 10_000 severity with pools clamped at C and share math alive (relocated C-2 regression); own basis is the RAW checkpoint, not aged weight
- [x] 5.2 Rework `_slashOne`: own slash off the raw own-stake checkpoint at `openedAt` clamped to live; pool legs at `min(S, C)` (live-pool-first, remainder to unbonding, `snapDelegated == 0` fallback preserved at the capped rate); spill `spillBasis × (S − min(S,C)) / 10_000` clamped to remaining own stake; one checkpoint push for both own debits; Sherlock #39 / Run-1 #22 active-delegated adjustment and I-1 unbonding-escrow semantics preserved; `GuardianSlashed.ownSlash` = base + spill
- [x] 5.3 Delete `voteStake` mapping + `recordVoteStake` from StakedWood and the three registry mirror calls (registry's own `_voteStake` stays for Merkl attribution); sweep `MinimalGuardianRegistry` and `MockStakedWood`
- [x] 5.4 Full suite green (few synthetic-`recordVoteStake` tests rewritten against the raw-checkpoint basis); commit

## 6. Deterministic severity (Part D)

- [x] 6.1 Write failing tests in new `test/GuardianRegistrySeverity.t.sol` (RegistryTestHarness scaffold, matured guardians): floor at scraped quorum, ceiling at supermajority, quadratic midpoint, degenerate `quorum >= SUPERMAJORITY_BPS` guard, 3-arg vote works end-to-end
- [x] 6.2 Change `IGuardianRegistry.voteOnProposal` to 3 args; add `SUPERMAJORITY_BPS = 6_667`; delete `blockerSlashBps` + `_weightedMedianSlashBps`; implement pure `_severityBps` (quadratic ramp in block decisiveness, defensive floor, degenerate guard) and call it from `resolveReview`
- [x] 6.3 Sweep `voteOnProposal` to 3 args everywhere (mocks, invariant handlers, registry/governor suites, MinimalGuardianRegistry); delete median-specific tests; recompute median-era severity expectations with the formula
- [x] 6.4 Full suite green; commit

## 7. Invariants, gap comments, fmt, final verification

- [x] 7.1 Add invariants: `invariant_agedWeightBounds` (votes ≤ raw + k × raw; zero stake ⇒ zero votes) and `invariant_poolsNeverZeroWithLiveShares` (relocated C-2: nonzero shares ⇒ nonzero tokens, both pools)
- [x] 7.2 Update `__gap` + storage-history comments (12 → 8; deleted `voteStake` slot documented per the pre-mainnet re-baseline precedent); run storage-parity tooling
- [x] 7.3 `forge build && forge test && forge fmt --check` (fmt with the CI-pinned forge version); invariant suites pass; commit + push
