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

Variant history, because this proposal is the fourth shape of the same fix:

1. The issue's blanket `min(getPastVotes(snap), getPastVotes(snap −
   FLOOR_LOOKBACK))` was rejected: with the LIVE `stakedAt` anchor the earlier
   read saturates to the age floor for anyone who re-anchored, silencing honest
   re-anchored positions far beyond the intended discount.
2. The narrow raw-stake clamp (`f(snapshotTs) × min(rawNow, rawThen) / 10_000`,
   spec commit f0acfe6) fixed that, but review surfaced a double penalty on
   honest top-ups: the clamp denies the raw increment AND the top-up re-anchors
   `stakedAt` forward (src/StakedWood.sol:607-624), dragging the age factor on
   the base the guardian already held — worst case ~0.25× the pre-top-up
   weight. Ana declined to ship that.
3. Option 2a (spec commit 085ac39) clamped the finished WEIGHT
   unconditionally — `min(weightNow, weightThen)`, the historical side on its
   historical age factor. It fixed the top-up penalty but re-taxed the steady
   30–60-day cohort: a 40-day staker who did nothing voted at 50% of raw
   instead of par — the same honest-voter cost that sank variant 1. Rejected
   2026-08-03.
4. **DECIDED 2026-08-03 — option 2b, this revision: gate the weight clamp on
   RAW GROWTH over the window.** `weight = (rawNow > rawThen) ?
   min(weightNow, weightThen) : weightNow`, each weight evaluated on its own
   instant's state. The attack still dies (`rawThen == 0` forces the gate
   true and zeroes `weightThen` regardless of any multiplier); a steady or
   shrunken position never has the clamp evaluate at all — bit-identical to
   today at every age; and a top-up can no longer drag the pre-existing
   position below what it was already worth a lookback ago (the historical
   side is computed from state a later top-up cannot touch).

Option 2b keeps 2a's prerequisite: **the historical age factor is not
derivable from current on-chain state.** `getPastVotes` reads the LIVE
`_guardians[g].stakedAt` (src/StakedWood.sol:668) — the anchor is not
checkpointed, and reconstructing it from the raw trace is unbounded iteration.
The only sound no-new-state approximation (the existing live-anchor read at
`lookbackTs`) errs low for exactly the top-up voters the clamp must price
fairly — they are all on the gated growth path — reproducing the 0.25× worst
case; see design §2. This change therefore checkpoints the anchor in
`StakedWood` and makes `getPastVotes` historically exact, which is also the
root fix for the documented "deflation-only drift" wart.

## What Changes

- **`StakedWood`**: a per-guardian anchor checkpoint trace
  (`Checkpoints.Trace224`) pushed at every `stakedAt` write (first stake
  :604, top-up re-anchor :623, unstake request :843). `getPastVotes(g, ts)`
  evaluates `_ageFactorBps` against the anchor AS OF `ts` instead of the live
  one — historical aged reads become exact; live reads (`getVotes`) are
  bit-identical. No `IStakedWood` signature change. **This is a storage
  append against a live, golden-pinned UUPS layout — the highest-consequence
  layout in the repo** (script/check-layout-goldens.sh:223-229; StakedWood
  custodies every WOOD bond): the mapping is carved off the END of the
  `__gap` per the documented convention (gap `uint256[4]` → `uint256[3]`,
  new field declared immediately below, taking freed slot 20; every field
  from `approvedBindVault` slot 21 on unmoved), and
  `script/staked-wood-layout.golden.json` is regenerated with the diff
  REVIEWED as a review artifact, not blind-regenerated.
- **`TokenCourt.vote`** clamps the ballot only on raw growth over the
  window: with `lookbackTs = snapshotTs > FLOOR_LOOKBACK ? snapshotTs -
  FLOOR_LOOKBACK : 0`, when `getPastStake(voter, snapshotTs) >
  getPastStake(voter, lookbackTs)` (strict — a shrunken position is never
  handed the higher historical figure) the weight is
  `min(getPastVotes(voter, snapshotTs), getPastVotes(voter, lookbackTs))`;
  otherwise it is today's single `getPastVotes(voter, snapshotTs)` read,
  bit-identical.
- Bootstrap fallback mirroring `_participationFloor`'s post-#96 keying
  (src/TokenCourt.sol:809): the clamp is also skipped when
  `getPastTotalVotes(lookbackTs) == 0` — keyed on the TOTAL, never
  per-caller; otherwise every case in the chain's first month would be
  unvotable, a guaranteed `Inconclusive`.
- **No TokenCourt storage, struct, or interface change**; no new import
  (`getPastStake` is already on `IStakedWood` and already imported for
  `_recordAccused`; both clamp operands are floored inside `getPastVotes`,
  and `min` commutes with flooring).
- Side effect, documented not hidden: `GuardianRegistry` review-vote weights
  (:451, :931) read `getPastVotes` at `openedAt` and become anchor-exact — a
  post-open top-up no longer deflates a frozen review ballot
  (test_voteOnProposal_snapshotsStake_topUpDeflatesNotInflates re-pins to par).
- Natspec: the flash-loan block above `vote` (src/TokenCourt.sol:334-341), the
  present-holdings block (:394-420), `FLOOR_LOOKBACK` (:80-91), `ITokenCourt`
  vote/`NoVotingPower`/`VoteCast` docs (:157, :199, :319-327), and
  `StakedWood`/`IStakedWood` aged-read docs (the "deflation-only" saturation
  text is deleted with the behaviour). Residuals are documented rather than
  claimed closed — including the one 2b REOPENS relative to 2a: dormant
  capital parked a full lookback early votes at par again (design §6).
- Tests: `_caseWithElectorate` (test/TokenCourt.t.sol:1165) models steady
  voters at the lookback instant; new unit tests cover steady-mature /
  young-steady-at-par / top-up bound / gate-true-weight-fell / shrink /
  fresh-address / partial-position attacker / bootstrap; new
  `StakedWoodAgeWeight` tests pin anchor-exact historical reads.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `token-court`: the **Voting** requirement changes — ballot weight is the
  bare `getPastVotes(snapshotTs)` read UNLESS the caller's raw stake grew
  over the `FLOOR_LOOKBACK` window (and an electorate existed at the
  lookback), in which case it is the minimum of the aged weight at the
  snapshot and the aged weight at the lookback instant. `NoVotingPower` now
  also refuses an address whose entire position is younger than the lookback
  (`rawThen == 0` forces the gate true and `weightThen == 0`).
- `guardian-staking`: the **Age-weighted vote weight** requirement changes —
  the `stakedAt` anchor is checkpointed and `getPastVotes` evaluates historical
  reads against the anchor as of the queried timestamp; the live-anchor
  saturation ("deflation-only drift") is removed.

## Impact

- `src/StakedWood.sol` — new trace + 3 push sites + `getPastVotes` body; one
  `__gap` slot (4 → 3, END-of-gap carve, `_liabilityCheckpoints` precedent);
  `script/staked-wood-layout.golden.json` regenerated AND the diff reviewed.
  Requires a StakedWood implementation upgrade against the live testnet UUPS
  lineage (46630 / 9994663; no 4663 mainnet deployment exists) — pre-mainnet
  legitimate, but NOT free: existing testnet guardians' empty anchor traces
  read the age floor for pre-upgrade history unless redeployed.
- `src/TokenCourt.sol` — `vote` body (:421-441), natspec (:80-91, :328-420).
- `src/interfaces/ITokenCourt.sol`, `src/interfaces/IStakedWood.sol` — natspec
  only, no ABI change.
- `test/TokenCourt.t.sol` — helper `_caseWithElectorate` (:1165) and the five
  B2 floor tests that vote under a non-zero lookback total (:1226, :1250,
  :1272, :1299, :1406) would otherwise revert `NoVotingPower` (re-derived
  under the gate — all five still break, via the mock's raw-defaults-to-aged
  inference; design §8); new vote-weight tests.
- `test/StakedWoodAgeWeight.t.sol` — new anchor-exactness tests.
- `test/GuardianRegistry.t.sol` — `test_voteOnProposal_snapshotsStake_topUpDeflatesNotInflates`
  (:254) pins the removed deflation drift; expected weight changes
  7_499e18 → 10_000e18 and the test is renamed to what it now proves. This
  breakage comes from the StakedWood change, not the gate.
- Sequencing: issue #84 (`enforce-floor-invariant-in-setters`, d81d02a on
  `fix/issue-84-floor-invariant-guard`) ships FIRST — this change rebases on
  it, re-verifying test line references (its TokenCourt.t.sol edits shift
  them). PR #144 (issue #83) has MERGED into this base. PR #152 (issue #35,
  off-limits) is OPEN and shares `src/StakedWood.sol` /
  `src/interfaces/IStakedWood.sol` / `test/mocks/MockStakedWood.sol` — it
  adds NO StakedWood storage and touches no golden (verified against its
  diff), so this change's anchor trace is the first storage append; merge
  order must be explicit, the layout golden regenerated after whichever
  lands second, and THIS branch adjusts, never theirs. #96 (PR #120) has
  MERGED; the ballot fallback mirrors its `earlier == 0` keying
  (src/TokenCourt.sol:809) — re-verified on e34526c.
