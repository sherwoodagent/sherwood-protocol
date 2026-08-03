# fix-ballot-growth-lookback

## Why

Issue #82: the B2 lookback protects the participation floor's denominator but not
the ballot. `TokenCourt.vote` reads weight in a single call —
`getPastVotes(msg.sender, c.snapshotTs)` (src/TokenCourt.sol:428) — and
`StakedWood._ageFactorBps` floors at `ageFloorBps` (deployed 2,500 bps) rather
than zeroing, so WOOD staked one second before the drain's `executedAt` votes at
25% of raw. A never-approving address is outside the accused set, untouched by
`slashVerdict`, and fully recoverable after cooldown — the issue's worked trace
buys a tie (acquittal) for ~7 days of capital lock.

Variant history, because this proposal is the third shape of the same fix:

1. The issue's blanket `min(getPastVotes(snap), getPastVotes(snap −
   FLOOR_LOOKBACK))` was rejected: with the LIVE `stakedAt` anchor the earlier
   read saturates to the age floor for anyone who re-anchored, silencing honest
   re-anchored positions far beyond the intended discount.
2. The narrow raw-stake clamp (`f(snapshotTs) × min(rawNow, rawThen) / 10_000`,
   spec commit f0acfe6) fixed that, but review of that spec surfaced a double
   penalty on honest top-ups: the clamp denies the raw increment AND the top-up
   re-anchors `stakedAt` forward (src/StakedWood.sol:607-624), dragging the age
   factor on the base the guardian already held — worst case ~0.25× the
   pre-top-up weight. Ana declined to ship that (issue #82 thread, NEED INPUT).
3. **DECIDED 2026-08-03 — option 2, this revision: clamp the finished WEIGHT,
   not the raw stake, evaluating the historical side on its HISTORICAL age
   factor**: `weight = min(f_now(snapshotTs) × rawNow, f_then(lookbackTs) ×
   rawThen) / 10_000`. The attack still dies (`rawThen == 0` zeroes
   `weightThen` regardless of any multiplier), and a top-up can no longer drag
   the pre-existing position below what it was already worth a lookback ago —
   the historical side is computed from state a later top-up cannot touch.

Option 2 has a prerequisite the decision did not spell out: **the historical
age factor is not derivable from current on-chain state.** `getPastVotes` reads
the LIVE `_guardians[g].stakedAt` (src/StakedWood.sol:668) — the anchor is not
checkpointed, and reconstructing it from the raw trace is unbounded iteration.
The only sound no-new-state approximation (the existing live-anchor read at
`lookbackTs`) errs low for exactly the top-up voters option 2 exists to
protect, reproducing the 0.25× worst case — see design §2. This change
therefore checkpoints the anchor in `StakedWood` and makes `getPastVotes`
historically exact, which is also the root fix for the documented
"deflation-only drift" wart.

## What Changes

- **`StakedWood`**: a per-guardian anchor checkpoint trace
  (`Checkpoints.Trace224`, one `__gap` slot) pushed at every `stakedAt` write
  (first stake :604, top-up re-anchor :623, unstake request :843).
  `getPastVotes(g, ts)` evaluates `_ageFactorBps` against the anchor AS OF
  `ts` instead of the live one — historical aged reads become exact; live
  reads (`getVotes`) are bit-identical. No `IStakedWood` signature change.
  `script/staked-wood-layout.golden.json` regenerated (gap 4 → 3).
- **`TokenCourt.vote`** clamps the ballot to the smaller of two finished
  weights: `weightNow = getPastVotes(voter, snapshotTs)`, `weightThen =
  getPastVotes(voter, lookbackTs)` with `lookbackTs = snapshotTs >
  FLOOR_LOOKBACK ? snapshotTs - FLOOR_LOOKBACK : 0`;
  `weight = min(weightNow, weightThen)`.
- Bootstrap fallback mirroring `_participationFloor`'s post-#96 keying
  (src/TokenCourt.sol:809): the min is skipped when
  `getPastTotalVotes(lookbackTs) == 0` — keyed on the TOTAL, never per-caller;
  otherwise every case in the chain's first month would be unvotable, a
  guaranteed `Inconclusive`.
- **No TokenCourt storage, struct, or interface change**; no new import (the
  raw variant's `Math.mulDiv` is no longer needed — both operands are already
  floored inside `getPastVotes`, and `min` commutes with flooring).
- Side effect, documented not hidden: `GuardianRegistry` review-vote weights
  (:451, :931) read `getPastVotes` at `openedAt` and become anchor-exact — a
  post-open top-up no longer deflates a frozen review ballot
  (test_voteOnProposal_snapshotsStake_topUpDeflatesNotInflates re-pins to par).
- Natspec: the flash-loan block above `vote` (src/TokenCourt.sol:334-341), the
  present-holdings block (:394-420), `FLOOR_LOOKBACK` (:80-91), `ITokenCourt`
  vote/`NoVotingPower`/`VoteCast` docs (:152, :196, :319), and
  `StakedWood`/`IStakedWood` aged-read docs (the "deflation-only" saturation
  text is deleted with the behaviour). Residuals are documented rather than
  claimed closed.
- Tests: `_caseWithElectorate` (test/TokenCourt.t.sol:1017) models steady
  voters at the lookback instant; new unit tests cover steady-mature /
  young-cohort discount / top-up / shrink / fresh-address / bootstrap; new
  `StakedWoodAgeWeight` tests pin anchor-exact historical reads.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `token-court`: the **Voting** requirement changes — ballot weight is no
  longer the bare `getPastVotes(snapshotTs)` read but the minimum of the aged
  weight at the snapshot and the aged weight one `FLOOR_LOOKBACK` earlier
  (with the bootstrap fallback). `NoVotingPower` now also refuses an address
  whose entire position is younger than the lookback (`weightThen == 0`).
- `guardian-staking`: the **Age-weighted vote weight** requirement changes —
  the `stakedAt` anchor is checkpointed and `getPastVotes` evaluates historical
  reads against the anchor as of the queried timestamp; the live-anchor
  saturation ("deflation-only drift") is removed.

## Impact

- `src/StakedWood.sol` — new trace + 3 push sites + `getPastVotes` body; one
  `__gap` slot (4 → 3, `_liabilityCheckpoints` precedent);
  `script/staked-wood-layout.golden.json` regenerated. Requires a StakedWood
  implementation upgrade/redeploy — legitimate pre-mainnet (no 4663 mainnet
  deployment; testnets redeployable), and existing testnet guardians' empty
  anchor traces read the age floor for pre-upgrade history.
- `src/TokenCourt.sol` — `vote` body (:421-441), natspec (:80-91, :328-420).
- `src/interfaces/ITokenCourt.sol`, `src/interfaces/IStakedWood.sol` — natspec
  only, no ABI change.
- `test/TokenCourt.t.sol` — helper `_caseWithElectorate` and the five B2 floor
  tests that vote under a non-zero lookback total (:1078, :1102, :1124, :1151,
  :1258) would otherwise revert `NoVotingPower`; new vote-weight tests.
- `test/StakedWoodAgeWeight.t.sol` — new anchor-exactness tests.
- `test/GuardianRegistry.t.sol` — `test_voteOnProposal_snapshotsStake_topUpDeflatesNotInflates`
  (:254) pins the removed deflation drift; expected weight changes
  7_499e18 → 10_000e18 and the test is renamed to what it now proves.
- Sequencing: issue #84 (`enforce-floor-invariant-in-setters`, TokenCourt
  setters + `test/mocks/MockStakedWood.sol`) ships FIRST — this change rebases
  on it. PR #144 (issue #83) is open and touches `TokenCourt.sol`
  `_recordAccused`, `ITokenCourt.Case`, and shares `test/TokenCourt.t.sol` —
  disjoint code hunks, coordinate the test file on whichever lands second.
  #96 (PR #120) has MERGED; the ballot fallback mirrors its `earlier == 0`
  keying (src/TokenCourt.sol:809) — re-verified on this base.
