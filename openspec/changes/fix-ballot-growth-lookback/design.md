# Design — fix-ballot-growth-lookback (issue #82, option 2: weight clamp)

Revision of the raw-stake-clamp design (f0acfe6) for the owner's 2026-08-03
decision. Sections carried forward from that design are marked; §2 is new and
is the load-bearing section of this revision.

## 0. Verified premises (file:line, this branch = origin/main cb35df6)

- Ballot weight is a single read at the snapshot:
  `uint256 weight = IStakedWood(stakedWood).getPastVotes(msg.sender, c.snapshotTs);`
  — src/TokenCourt.sol:428; `NoVotingPower` at :429, present-holdings gate at
  :431 (ordering pinned by
  test_vote_bothChecksFail_getsNoVotingPowerNotNoPresentHoldings, :739).
- `StakedWood.getPastVotes(g, ts)` is
  `rawCheckpoint(ts) × _ageFactorBps(_guardians[g].stakedAt, ts) / 10_000`
  (src/StakedWood.sol:666-669). **The anchor is the LIVE stored field, not a
  checkpoint** — this is the fact the whole revision turns on. `_ageFactorBps`
  (:650-656) ramps `ageFloorBps` → 10_000 linearly over `maturationPeriod`,
  returns `ageFloorBps` for `stakedAt_ == 0`, and saturates `ts < stakedAt_`
  to age 0 (the documented "deflation-only drift", :648-649).
- The anchor only ever moves FORWARD. Write sites, exhaustively:
  first stake sets `now` (:604); top-up sets the stake-weighted average of the
  old anchor and `now`, ceil-rounded toward `now` (:617-623); unstake request
  re-anchors to `now` (:843). `cancelUnstakeGuardian` does not touch it;
  `claimUnstakeGuardian` deletes the struct (:922); the slash paths
  (`_slashOne` callers) never write it.
- Raw checkpoints already exist per guardian (`_stakeCheckpoints`, :295) and
  globally (`_totalStakeCheckpoint`, :299), timestamp-keyed
  `Checkpoints.Trace224`. `getPastStake` :700-702, `getPastTotalVotes`
  :706-708.
- Post-#96 `_participationFloor` (src/TokenCourt.sol:778-810): same-instant
  reduction first, then `base = (earlier != 0 && earlier < reduced) ? earlier
  : reduced` (:809) — the bootstrap fallback keys on `earlier == 0`, a TOTAL.
- `FLOOR_LOOKBACK = 30 days`, a constant, src/TokenCourt.sol:91 (rationale
  :80-90 and :683-698 — equals deployed `maturationPeriod`, exceeds a full
  proposal lifecycle, deliberately not a setter).
- `getPastVotes` consumers outside StakedWood: `TokenCourt.vote` (:428) and
  `GuardianRegistry` review/emergency votes at `openedAt`
  (src/GuardianRegistry.sol:451, :931). `SyndicateGovernor`'s `getPastVotes`
  is the VAULT's (IVotes), unrelated.
- CI runs `script/check-layout-goldens.sh`; `script/staked-wood-layout.golden.json`
  pins StakedWood's layout. `__gap` is `uint256[4]` (src/StakedWood.sol:387)
  with a documented shrink convention (`_liabilityCheckpoints` precedent).

## 1. The rule, in arithmetic

```
lookbackTs = snapshotTs > FLOOR_LOOKBACK ? snapshotTs - FLOOR_LOOKBACK : 0
weightNow  = getPastVotes(voter, snapshotTs)   // f(anchor@snap, snapshotTs) × rawNow  / 10_000
weightThen = getPastVotes(voter, lookbackTs)   // f(anchor@lb,   lookbackTs) × rawThen / 10_000
weight     = getPastTotalVotes(lookbackTs) == 0 ? weightNow : min(weightNow, weightThen)
```

where `anchor@ts` is the `stakedAt` value AS OF `ts` — which §2 makes readable.
The min is UNCONDITIONAL (not gated on raw growth): the owner's rule prices
every ballot at "what the position was worth a lookback before the snapshot,
or now, whichever is less". Sketch, in `vote` (replacing :428-429):

```solidity
uint256 weight = IStakedWood(stakedWood).getPastVotes(msg.sender, c.snapshotTs);
uint256 lookbackTs = c.snapshotTs > FLOOR_LOOKBACK ? c.snapshotTs - FLOOR_LOOKBACK : 0;
if (IStakedWood(stakedWood).getPastTotalVotes(lookbackTs) != 0) {
    uint256 weightThen = IStakedWood(stakedWood).getPastVotes(msg.sender, lookbackTs);
    if (weightThen < weight) weight = weightThen;
}
if (weight == 0) revert NoVotingPower();
```

No `mulDiv`, no new import: both operands are single-floored products computed
inside `getPastVotes` exactly as today, and `min` needs no arithmetic. This is
smaller in TokenCourt than the raw variant (~6 lines vs ~8, zero new
multiplications) — the cost moved into StakedWood (§2).

## 2. How `f_then` is obtained — the question this revision stands or falls on

### 2.1 It is NOT derivable from current state

The true historical factor is `_ageFactorBps(anchor-as-of-lookbackTs,
lookbackTs)`. `stakedAt` is a plain live field; no trace of its past values
exists. Reconstructing it from `_stakeCheckpoints` would require classifying
and replaying every checkpoint (stake vs slash vs request/cancel push) —
unbounded iteration, unsound for a hot path.

### 2.2 The no-new-state approximation is sound but self-defeating — REJECTED

The closest existing read is `getPastVotes(voter, lookbackTs)` as implemented
today: `rawThen × f(LIVE anchor, lookbackTs)`. Its error direction is safe:
the anchor only moves forward (§0), so live anchor ≥ historical anchor,
`f(live, lb) ≤ f(hist, lb)`, and the approximation only ever UNDERSTATES
`weightThen` — it can never inflate an attacker's ballot.

But it understates for exactly the voters option 2 exists to protect. A top-up
inside the window moves the live anchor forward, so the historical side is
evaluated with the POST-top-up anchor: for a top-up `A` on base `B`,
`weightThen = f(avgAnchor, lb) × B`, saturating to `ageFloorBps × B / 10_000 =
0.25 B` whenever the averaged anchor lands at or past `lookbackTs`. Worse than
merely failing the goal, it is UNIFORMLY ≤ the raw-stake variant it replaces:
in every growth case the raw clamp paid `f(avgAnchor, snap) × B` and
`f(avgAnchor, lb) ≤ f(avgAnchor, snap)` (same anchor, earlier instant, and the
factor is non-decreasing in the read timestamp). Same 0.25× worst case, easier
to hit. Shipping option 2 on the live-anchor read would re-create the double
penalty the owner rejected — with the min now also taxing steady positions
(§3.4). This approximation is therefore rejected, not adopted.

### 2.3 The fix: checkpoint the anchor (StakedWood change)

Make `anchor@ts` a first-class historical read:

- Storage: `mapping(address => Checkpoints.Trace224) internal
  _anchorCheckpoints;` declared per the gap convention — `__gap` 4 → 3, new
  field immediately below, `_liabilityCheckpoints` precedent; regenerate
  `script/staked-wood-layout.golden.json`.
- Push `uint224(g.stakedAt)` at the three anchor write sites (:604, :623,
  :843), same-transaction with the raw pushes already there. No push at
  `claimUnstakeGuardian`'s struct delete: the raw trace already reads 0 from
  the request instant, so any historical read between claim and a re-stake is
  `0 × f = 0` regardless of anchor, and a re-stake lands in the `wasInactive`
  branch which pushes a fresh anchor. No push on slash: slashes never write
  `stakedAt`.
- `getPastVotes` (:666-669) replaces `_guardians[guardian].stakedAt` with
  `uint64(_anchorCheckpoints[guardian].upperLookupRecent(uint32(timestamp)))`.
  Empty-trace reads (ts before the first stake) return 0 →
  `_ageFactorBps(0, ts) = ageFloorBps`, and the raw trace is 0 there anyway,
  so the product is 0 — consistent. Reads at or after the latest write return
  the live anchor, so `getVotes` (delegating at `block.timestamp`) is
  bit-identical.
- `IStakedWood` is UNCHANGED in ABI — no new getter, no signature change; the
  exactness lives inside `getPastVotes`. Natspec on both contracts drops the
  "saturates to age 0 / deflation-only" text along with the behaviour.

With the trace, `f_then` is **EXACT** with one qualification: `_ageFactorBps`
reads the LIVE `ageFloorBps` / `maturationPeriod` parameters. Historical
evaluations use current parameter values — identical to how every historical
read behaves today, owner-timelocked, and the exposure is not new; documented,
not fixed here.

Consequences beyond the court, stated rather than hidden:
- `GuardianRegistry` review weights (:451, :931) become anchor-exact: a top-up
  AFTER `openReview` no longer deflates the frozen ballot (raw was already
  frozen; now the factor is too).
  `test_voteOnProposal_snapshotsStake_topUpDeflatesNotInflates`
  (test/GuardianRegistry.t.sol:254) pins the drift with an exact 7_499e18
  expectation that becomes 10_000e18 (par) — the test is renamed and re-pins
  "top-up neither inflates nor deflates a frozen review ballot".
- Nothing relied on the drift for safety: it was documented as a tolerated
  wart ("drift is deflation-only", :648-649), never as a defence. Removing it
  only moves historical reads toward the true value, and `weight ≤ raw` still
  holds at every timestamp (factor ≤ 10_000), so every conservative-denominator
  argument survives.
- Upgrade reality: this is a StakedWood implementation change + storage
  append. Legitimate pre-mainnet (no 4663 mainnet deployment; testnets
  redeployable — same licence the 2026-07-26 re-baseline used). On an upgraded
  (not redeployed) testnet instance, pre-upgrade history reads an empty anchor
  trace → `ageFloorBps` for old timestamps; acceptable there, impossible on a
  fresh deploy.

## 3. Properties

### 3.1 PRESERVED — the attack still fails (owner property 1)

Stake bought inside the window — including one second before `executedAt` —
has `rawThen = 0` at `lookbackTs` (the raw trace is empty or zero there), so
`weightThen = rawThen × f_then / 10_000 = 0` REGARDLESS of any age-floor
multiplier: the floor multiplies raw, and zero raw times any factor is zero.
The min pins the ballot to 0 → `NoVotingPower`. The issue's worked attack
(1.2M WOOD staked at `executedAt − 1` voting 300k) is closed outright, and no
anchor-trace subtlety can reopen it — property 1 needs only the RAW side of
`weightThen`.

### 3.2 FIXED — the honest top-up double penalty, with the precise new bound

Setup: base `B` with anchor `a₀ < lookbackTs`, topped up by `A` at
`t ∈ (lookbackTs, snapshotTs]`; write `f_old(ts) = f(a₀, ts)` and
`f_new(ts) = f(avgAnchor, ts)`.

**Lemma (the raw increment always covers the re-anchor at the snapshot):**
`weightNow = f_new(snap) × (B + A) ≥ f_old(snap) × B`. Below the par cap the
ramp is affine, `f(age) = c + k·age` with `c = ageFloorBps`, and the averaged
age is the stake-weighted mean of the tranche ages, so
`f_new(snap)(B + A) = c(B + A) + k(B·age_B + A·age_A) ≥ cB + k·B·age_B
≥ f_old(snap)·B` (the last step because the cap only ever reduces
`f_old`); if the averaged age is ≥ `maturationPeriod` then
`weightNow = B + A ≥ B ≥ f_old(snap)·B`. The ceil-round of the averaged
anchor (:623) costs at most one second of age, direction against the voter —
it cannot break the inequality's intent and never favours an attacker.

**The bound:** `weightThen = f(anchor@lb, lb) × B / 10_000` is computed
entirely from state as of `lookbackTs` — a later top-up cannot touch either
operand. So `weight = min(weightNow, weightThen) = weightThen = ` **exactly
the position's true aged worth at the lookback instant**, because
`weightNow ≥ f_old(snap)·B ≥ f_old(lb)·B = weightThen`. Compared with not
topping up at all (steady: `min(f_old(snap)·B, f_old(lb)·B) = f_old(lb)·B`),
**a top-up changes the ballot by exactly zero** — the double penalty is gone,
and topping up is weight-non-decreasing. The raw variant's 0.25×-of-base worst
case cannot occur: nothing the top-up does reaches `weightThen`.

For an ATTACKER the same fact is defence-positive: a drain-time top-up on an
accomplice base buys nothing (the min stays at the base's month-ago worth),
and doing nothing is exactly as good — drain-time additions remain pointless
rather than punitive.

### 3.3 A reduced or steady position can never exceed its current weight

`weight ≤ weightNow` by construction of `min` — the clamp can only lower. A
position that shrank inside the window votes at most its (smaller) current
aged weight, never the larger historical figure; there is no branch condition
to get backwards (the raw variant needed a directional `rawNow > rawThen`
check; here the min's symmetry does the work). An actual unstake request
pushes a 0 raw checkpoint and zeroes `getVotes`, so a shrunk-to-zero voter is
already refused at :429/:431 before the clamp matters.

### 3.4 NEW COST, owned plainly: the steady sub-60-day cohort is discounted

The min is unconditional, so it binds for any position whose aged worth GREW
over the window — which includes pure aging with no raw change. A steady
guardian who first staked `d` days before the snapshot votes:

- `d ≥ maturationPeriod + FLOOR_LOOKBACK` (~60 days deployed): par at both
  instants — bit-identical to today.
- `FLOOR_LOOKBACK ≤ d < maturationPeriod + FLOOR_LOOKBACK`: `weightThen =
  f(d − 30 days of age)` binds — e.g. a 40-day steady staker votes 50% of raw
  (aged 10 days at the lookback) where today they vote par. Heals linearly,
  gone at 60 days.
- `d < FLOOR_LOOKBACK`: `rawThen = 0` → silenced (`NoVotingPower`) — this is
  the fix itself and is identical in every variant considered.

This REVERSES the narrow variant's headline neutrality for the 30–60-day
steady cohort (the very cost the raw clamp was chosen to avoid). It is the
price of the owner's uniform rule "a ballot is worth the position's month-ago
value", and it buys a real hardening in exchange — §6's dormant-capital
residual is 4× harsher to exploit. Recorded here as the accepted trade of the
2026-08-03 decision; the natspec must state it verbatim rather than absorbing
it. (A growth-gated min — apply the clamp only when `rawNow > rawThen` —
would keep steady positions untouched at the cost of leaving dormant capital
at par after 30 days; noted as the nearest rejected alternative, not adopted,
because it is not the rule the owner specified.)

## 4. Bootstrap fallback

`snapshotTs ≤ FLOOR_LOOKBACK` clamps `lookbackTs` to 0, and any lookback
instant before the first stake ever reads an empty trace. Without a fallback,
`weightThen = 0` for EVERY voter → every case in the protocol's first month
reverts `NoVotingPower` for all comers → guaranteed `Inconclusive`, the denial
mode #96 closed. Mirror `_participationFloor` exactly (post-#96 form, :809 —
`earlier != 0` guards the min): skip the min when
`getPastTotalVotes(lookbackTs) == 0`. Keyed on the TOTAL, which an attacker
cannot zero, never on the caller's own `weightThen` (a per-caller fallback
would re-admit the fresh whale wholesale). The fallback sits OUTSIDE the min —
it decides whether `weightThen` enters the comparison at all; when it fires,
the ballot is the unclamped `weightNow`, exactly today's behaviour. Residual:
during bootstrap the ballot is as exposed as today — same window, same
shrink-to-nothing property, same smallest-TVL argument as the floor's
documented fallback (:699-720).

## 5. Lookback constant

Unchanged from the raw-variant design: reuse `FLOOR_LOOKBACK`. (i) Numerator
and denominator sample the SAME two instants — a divergent pair recreates
#82's asymmetry in miniature. (ii) Every argument on the existing constant
transfers verbatim: 30d equals the deployed `maturationPeriod`, exceeds a full
proposal lifecycle, and MUST stay a constant rather than an owner setter
(:84-90 — a settable lookback is a pre-drain shrink lever). (iii) A second
constant with the same value is a trap for future divergence. The natspec on
`FLOOR_LOOKBACK` (:80-91) gains one sentence: it now bounds the ballot as well
as the floor's base.

## 6. Attacker residual — what option 2 does and does not close

- **Closed**: the fresh-whale ballot (§3.1) and any drain-time inflation of an
  accomplice position (§3.2 — additions inside the window never reach the
  min's binding side).
- **Residual 1 — premeditated dormant capital, now 4× harsher.** Under the raw
  clamp, capital parked exactly `FLOOR_LOOKBACK` early voted at PAR (30-day
  age = deployed maturation). Under option 2 it votes at its month-ago worth:
  parked at `lookbackTs`, `weightThen = ageFloorBps × X = 0.25X` — exactly the
  pre-fix fresh-whale figure, but now costing 30 days of visible idle
  commitment instead of one second. Par requires the anchor to be a full
  `maturationPeriod` BEFORE the lookback instant — ~60 days of dormancy at
  deployed values, twice the raw variant's, or 4× the principal for the same
  ballot at 30 days. The counter-levers are unchanged: the stake is public
  the whole time, and a vote still has to win against honest turnout (unlike
  the floor-denial, which needed no votes).
- **Residual 2 — the touch-stake (endpoint sampling), unchanged.** Stake `X`
  just before `lookbackTs`, unstake after it, re-stake at the drain:
  `weightThen = f(anchor ≈ lb, lb) × X = 0.25X` and
  `weightNow = f(anchor ≈ snap, snap) × X = 0.25X` → ballot `0.25X`, the
  pre-fix fresh-whale figure for two short cooldown locks a month apart.
  Identical in every variant considered; closing it requires a true windowed
  minimum over the trace (gas-unbounded) or new state; out of scope,
  documented.
- **Not addressed, unchanged**: address-splitting by the accused
  (src/TokenCourt.sol:352-377, accepted), the floor's own residuals, and
  everything #96 covers.

## 7. Reads, rounding, and storage — design questions 3–5 resolved

- **Staticcalls per vote**: today 2 (`getPastVotes(snap)`, `getVotes`).
  Option 2 adds 2 — `getPastTotalVotes(lookbackTs)` always, and
  `getPastVotes(lookbackTs)` when the fallback does not fire. The raw variant
  added 3 (`getPastStake` ×2 + the total). Option 2 is one staticcall CHEAPER
  per vote than the variant it replaces; the owner's estimate of "one extra
  `getPastVotes`" undercounts by the fallback read, which the raw variant also
  had.
- **Rounding**: each side is floored once inside `getPastVotes`
  (`raw × f / 10_000`), and `min` commutes with the floor
  (`min(⌊a⌋, ⌊b⌋) = ⌊min(a, b)⌋` since flooring is monotone), so the composed
  weight is the exact clamped value rounded DOWN — at most 1 wei low, never
  up, and strictly tighter than the raw variant's two-stage `mulDiv` (which
  lost up to 1 wei twice). No overflow surface: `uint224 raw × f ≤ 10_000`
  fits in 238 bits, the exact multiplication `getPastVotes` already performs.
  An attacker's ballot can only round toward zero.
- **Storage / struct / interface**: `TokenCourt` — unchanged on all three
  (still true from the raw variant). `StakedWood` — the raw variant's "no
  change anywhere" claim does NOT survive option 2: one new mapping (one
  `__gap` slot), three checkpoint pushes, and a two-line `getPastVotes` body
  change, plus the layout golden. `IStakedWood` and `ITokenCourt` ABIs
  unchanged (natspec only). This is the honest scope delta of the 2026-08-03
  decision.

## 8. Test impact (re-derived for option 2, current line numbers)

Breaks without updating — the five B2 floor tests vote via
`_castFullTurnoutAndCloseWindow` (test/TokenCourt.t.sol:1044) under a NON-zero
lookback total, and voterA/voterB have aged weight set only at `snap`
(:1034-1035), so `weightThen = 0` → `NoVotingPower`. Same membership as the
raw variant (the trigger differs: mock aged-weight-at-lookback of zero, rather
than raw-at-lookback):
- :1078 `test_finalize_floorIgnoresAPreDrainStakeSurge_denialOfQuorumClosed`
- :1102 `test_finalize_floorUnchangedWhenElectorateStable`
- :1124 `test_finalize_belowFloorStillInconclusive_withBothCheckpointsSet`
- :1151 `test_finalize_floorStillInflatableByAMonthOldStake_knownResidual`
- :1258 `test_finalize_floorTakesTheMinNotTheEarlierReadAlone`

Single fix for all five, unchanged in shape from the raw variant:
`_caseWithElectorate` (:1017) additionally sets
`setPastVotes(voterA/voterB, snap - FLOOR_LOOKBACK, same value)` whenever
`totalAtLookback != 0` — under option 2 this models MATURE steady stakers
(equal aged weight at both instants → the min is a no-op), which is what those
tests mean anyway. `MockStakedWood` needs NO change: `vote` no longer reads
`getPastStake` at all, and the mock's `getPastVotes` is already
per-(address, timestamp) programmable — it plays the role of the anchor-exact
real contract for free. (#84 is editing the same mock file — sequencing only,
no overlap in members.)

Stay green (verified fixture by fixture):
- All `_caseWithAccusedWeight` tests (:1300-1325 helper) — the helper never
  sets a lookback total → fallback → unclamped; includes the :1401 dust voter.
- :1483 `test_finalize_floorSurvivesElectorateGrowthPastTheLookback` and the
  reduced-binds test after it — both set non-zero lookback totals but cast NO
  votes.
- :1189 underflow test — `lookbackTs` clamps to 0, total 0 → fallback.
- :1237 fallback test — `totalAtLookback = 0` by construction.
- Vote-section tests :620-:770 (`_referredCase`, no lookback totals) —
  fallback → green; doc-comment touch-ups on :620 and :703 noting they now
  exercise the unclamped bootstrap branch.

End-to-end: only `test/TokenCourtEndToEnd.t.sol` calls `court.vote`; its
lifecycle keeps `lookbackTs` before the first stake, the REAL StakedWood total
trace reads 0 there, every vote lands in the fallback → green unmodified
(consequence: no e2e exercises the active clamp; active-clamp coverage is unit
level). `ChallengeEndToEnd`/`CoverageEndToEnd` never call `court.vote`.

Behavioural test changes OUTSIDE the court (new to option 2):
- test/GuardianRegistry.t.sol:254
  `test_voteOnProposal_snapshotsStake_topUpDeflatesNotInflates` — pins the
  live-anchor deflation with an exact 7_499e18 expectation; under anchor-exact
  reads the weight is 10_000e18 (par). Rename + re-pin: "top-up neither
  inflates nor deflates" (raw frozen AND factor frozen).
- test/StakedWoodAgeWeight.t.sol — existing tests (:48-:161) read live or
  post-write timestamps and stay green; NEW tests pin anchor exactness
  (tasks 3.6-3.8).

New unit tests (TokenCourt.t.sol, vote section; lookback total non-zero so the
min is live unless stated):
1. Steady-mature regression: equal aged weight at both instants → tally and
   `VoteCast` equal `getPastVotes(snap)` bit-exactly.
2. Young-cohort discount (pins §3.4's accepted cost): `weightThen <
   weightNow`, both non-zero → tally equals `weightThen`. Mutation-kills
   dropping the min or gating it on raw growth.
3. Top-up bound: fixture with `weightNow > weightThen` from raw growth →
   weight is exactly the month-ago figure, and is NOT reduced further by any
   snapshot-side factor (kills a live-anchor-style implementation).
4. Cannot-exceed-now: `weightThen > weightNow` (shrunk position) → weight is
   the unclamped `weightNow`.
5. Fresh-address attack regression (#82): non-zero snap weight, zero lookback
   weight, non-zero lookback total → `NoVotingPower`, tally untouched.
   Mutation-kills reverting to the bare :428 read.
6. Bootstrap: lookback total 0 → weight unclamped.

## 9. Coordination flags

- **#84** (`enforce-floor-invariant-in-setters`) is in flight NOW on
  `TokenCourt.sol` setters and `test/mocks/MockStakedWood.sol`, and ships
  FIRST. This change rebases on it; expected overlap is zero code lines
  (setters vs `vote`) and zero mock members, but the mock FILE is shared.
- **PR #144** (issue #83) is OPEN: `TokenCourt.sol` `_recordAccused`,
  `ITokenCourt.Case`, shared `test/TokenCourt.t.sol`. Code hunks disjoint from
  `vote`; whichever lands second re-runs the court suite and re-checks this
  spec's line references.
- **#96 (PR #120) has MERGED** — the prior revision's "merge #96 first"
  constraint is satisfied; the ballot fallback mirrors its `earlier == 0`
  keying (:809), re-verified on cb35df6.
- This change now touches `StakedWood` — no open PR does (checked #104, #88 at
  f0acfe6 time; re-check at implementation).
- PR targets `main` (stacked PRs get no CI in this repo).

## 10. Implementation file list

- `src/StakedWood.sol` — `_anchorCheckpoints` (+ gap 4 → 3), pushes at :604,
  :623, :843, `getPastVotes` body (:666-669), natspec (:644-669 and the
  deflation-drift mentions).
- `script/staked-wood-layout.golden.json` — regenerated.
- `src/TokenCourt.sol` — `vote` (:421-441), natspec :328-420 and :80-91.
- `src/interfaces/IStakedWood.sol`, `src/interfaces/ITokenCourt.sol` — natspec
  only (:101-111 aged-read doc; :152/:196/:319).
- `test/TokenCourt.t.sol` — `_caseWithElectorate` (:1017-1036), doc touch-ups
  (:620, :703), six new tests.
- `test/StakedWoodAgeWeight.t.sol` — anchor-exactness tests.
- `test/GuardianRegistry.t.sol` — :254 rename + re-pin.
- No other source, interface, mock, or script files.
