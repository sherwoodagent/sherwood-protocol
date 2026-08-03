# Design — fix-ballot-growth-lookback (issue #82, option 2b: growth-gated weight clamp)

Revision of the option-2a design (085ac39) for the owner's 2026-08-03 decision
round 2: the unconditional weight min re-taxed the steady 30–60-day cohort (2a
§3.4 owned it as a cost; the owner rejected paying it — it is the same
honest-voter cost that sank the issue's blanket variant). Option 2b gates the
clamp on RAW GROWTH over the window, so the clamp prices suspicious capital
and never touches a position that merely aged. Sections carried forward from
2a are marked; §1, §3 and §7 are re-derived, and §2 (the anchor checkpoint)
carries forward intact — it is still what makes the clamp's historical side
honest for top-up voters.

## 0. Verified premises (file:line, this branch = origin/main e34526c)

- Ballot weight is a single read at the snapshot:
  `uint256 weight = IStakedWood(stakedWood).getPastVotes(msg.sender, c.snapshotTs);`
  — src/TokenCourt.sol:428; `NoVotingPower` at :429, present-holdings gate at
  :431 (ordering pinned by
  test_vote_bothChecksFail_getsNoVotingPowerNotNoPresentHoldings,
  test/TokenCourt.t.sol:887).
- `StakedWood.getPastVotes(g, ts)` is
  `rawCheckpoint(ts) × _ageFactorBps(_guardians[g].stakedAt, ts) / 10_000`
  (src/StakedWood.sol:666-669). **The anchor is the LIVE stored field, not a
  checkpoint** — the fact §2 turns on. `_ageFactorBps` (:650-656) ramps
  `ageFloorBps` → 10_000 linearly over `maturationPeriod`, returns
  `ageFloorBps` for `stakedAt_ == 0`, and saturates `ts < stakedAt_` to age 0
  (the documented "deflation-only drift", :648-649).
- The anchor only ever moves FORWARD. Write sites, exhaustively:
  first stake sets `now` (:604); top-up sets the stake-weighted average of the
  old anchor and `now`, ceil-rounded toward `now` (:617-623); unstake request
  re-anchors to `now` (:843). `cancelUnstakeGuardian` does not touch it;
  `claimUnstakeGuardian` deletes the struct; the slash paths never write it.
- RAW reads already exist for both sides of the gate: `getPastStake(g, ts)`
  (src/StakedWood.sol:700-702) reads the SAME `_stakeCheckpoints` trace that
  `getPastVotes` multiplies the age factor into — zeroed by an unstake
  request on both measures, so gate and clamp agree on what "position" means.
  Totals: `getPastTotalVotes` :706-708. All three are on `IStakedWood`
  already (:110, :117, :122) — the gate needs NO new interface member.
- Post-#96 `_participationFloor` (src/TokenCourt.sol:778-811): same-instant
  reduction first, then `base = (earlier != 0 && earlier < reduced) ? earlier
  : reduced` (:809) — the bootstrap fallback keys on `earlier == 0`, a TOTAL.
- `FLOOR_LOOKBACK = 30 days`, a constant, src/TokenCourt.sol:91 (rationale
  :80-90 — equals deployed `maturationPeriod`, exceeds a full proposal
  lifecycle, deliberately not a setter).
- `getPastVotes` consumers outside StakedWood: `TokenCourt.vote` (:428) and
  `GuardianRegistry` review/emergency votes at `openedAt`
  (src/GuardianRegistry.sol:451, :931). `SyndicateGovernor`'s `getPastVotes`
  is the VAULT's (IVotes), unrelated.
- **StakedWood storage is NOT free.** StakedWood is UUPS, deployed on
  testnets (46630 / 9994663), custodies every WOOD bond in the protocol, and
  is golden-pinned in CI — `script/check-layout-goldens.sh:229` checks
  `script/staked-wood-layout.golden.json`, and the comment above it (:223-228)
  calls it the highest-consequence layout in the repo (review N7; Plan B
  carved `exposureLedger` out of the `__gap`, Plan C carved
  `authorizedSlasher` and `_verdictSlashed`). Current golden: `__gap` is
  `uint256[4]` at slots 17-20 (src/StakedWood.sol:387), `approvedBindVault`
  at slot 21 and everything after it fixed. The gap's own doc (:367-386)
  states the pre-mainnet convention: shrink comes off the END of the gap, the
  new field is declared immediately below `__gap`, and every field after it
  keeps its slot.

## 1. The rule, in arithmetic

```
lookbackTs = snapshotTs > FLOOR_LOOKBACK ? snapshotTs - FLOOR_LOOKBACK : 0
rawNow     = getPastStake(voter, snapshotTs)
rawThen    = getPastStake(voter, lookbackTs)
weightNow  = getPastVotes(voter, snapshotTs)   // f(anchor@snap, snapshotTs) × rawNow  / 10_000
weightThen = getPastVotes(voter, lookbackTs)   // f(anchor@lb,   lookbackTs) × rawThen / 10_000
weight     = (rawNow > rawThen && getPastTotalVotes(lookbackTs) != 0)
                 ? min(weightNow, weightThen)
                 : weightNow
```

where `anchor@ts` is the `stakedAt` value AS OF `ts` — which §2 makes
readable. The min is GATED on raw growth over the window, strict `>`: the
clamp prices capital that arrived inside the window, and never evaluates for
a position whose raw stake held or shrank. Sketch, in `vote` (replacing
:428-429):

```solidity
IStakedWood swood = IStakedWood(stakedWood);
uint256 weight = swood.getPastVotes(msg.sender, c.snapshotTs);
uint256 lookbackTs = c.snapshotTs > FLOOR_LOOKBACK ? c.snapshotTs - FLOOR_LOOKBACK : 0;
if (
    swood.getPastStake(msg.sender, c.snapshotTs) > swood.getPastStake(msg.sender, lookbackTs)
        && swood.getPastTotalVotes(lookbackTs) != 0
) {
    uint256 weightThen = swood.getPastVotes(msg.sender, lookbackTs);
    if (weightThen < weight) weight = weightThen;
}
if (weight == 0) revert NoVotingPower();
```

Gate FIRST, fallback second, deliberately: `&&` short-circuits, so the
`getPastTotalVotes` read is skipped for every non-growth voter — the
perpetual steady majority — and the ordering is semantically free (the two
conditions are independent pure reads; the clamp applies iff both hold). No
`mulDiv`, no new import, no TokenCourt storage.

### 1.1 Design question: gate on raw, or gate on weight?

The rule gates on RAW (`rawNow > rawThen`) but clamps WEIGHTS. That
asymmetry is deliberate and, we argue, the only coherent choice:

- **Raw held, weight grew** (pure aging — the common honest case): the gate
  is false and the ballot is the unclamped `weightNow`, bit-identical to
  today. Gating on weight growth instead (`weightNow > weightThen`) would
  fire here — pure aging always grows weight below par — and the rule would
  collapse back into 2a's unconditional min, re-taxing the steady 30–60-day
  cohort. Weight growth conflates age (legitimate, cannot be acquired inside
  the window without capital that was ALREADY there a full lookback ago) with
  capital (the attack vector). Raw is the only observable that separates
  them. Security on this path: `rawNow ≤ rawThen` means every wei of the
  ballot's backing was committed at or before `lookbackTs`, and
  `weightNow ≤ rawNow ≤ rawThen`, so the ballot is bounded by capital a full
  lookback old — exactly the dormant-capital residual (§6), accepted.
- **Raw grew, weight grew** (fresh stake, top-up): gate true, clamp binds to
  `weightThen` — §3.1 and §3.2.
- **Raw grew, weight FELL** — this exists: a top-up's forward re-anchor, or
  an unstake-request-then-cancel (request re-anchors :843, cancel restores
  raw without restoring age), can drop `f` enough that
  `weightNow < weightThen` despite `rawNow > rawThen`. The gate is true, and
  `min` resolves it correctly: the ballot is `weightNow`, the smaller — a
  voter never pays MORE than their genuine current worth, and never collects
  the larger historical figure either. This is why the clamp is a `min` and
  not an unconditional `weightThen` assignment on the growth path.
- **Raw shrank** (whatever weight did): gate false, ballot is `weightNow`.
  Strict `>` is what closes the shrink case — see §3.3.

There is no case where gating on raw admits a ballot that gating on weight
would have caught: any weight acquired inside the window that is not pure
aging requires raw growth, and pure aging requires pre-window capital. So
gate-on-raw dominates gate-on-weight on both axes (honest cost AND security),
and the rule is coherent as specified.

## 2. How `f_then` is obtained — carried forward from 2a intact

The clamp's historical side is only read on the growth path now, but when it
IS read it must still be honest — the top-up voters §3.2 protects are all ON
the growth path, so everything in this section remains load-bearing.

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

But it understates for exactly the voters the clamp's min exists to bound
fairly, and they are all on the gated path: a top-up inside the window moves
the live anchor forward, so the historical side is evaluated with the
POST-top-up anchor — for a top-up `A` on base `B`,
`weightThen = f(avgAnchor, lb) × B`, saturating to `ageFloorBps × B / 10_000
= 0.25 B` whenever the averaged anchor lands at or past `lookbackTs`. That
re-creates the double penalty the owner rejected, gated or not — every
top-up voter passes the gate and hits it. This approximation is therefore
rejected, not adopted.

### 2.3 The fix: checkpoint the anchor (StakedWood change)

Make `anchor@ts` a first-class historical read:

- Storage — **an append against the highest-consequence layout in the repo**
  (§0), executed per the gap doc's own convention (:367-386, the
  `_liabilityCheckpoints` / `approvedBindVault` precedent):
  `mapping(address => Checkpoints.Trace224) internal _anchorCheckpoints;`
  declared IMMEDIATELY BELOW `__gap`, gap shrunk `uint256[4]` → `uint256[3]`
  — the new mapping takes slot 20 (the freed END slot of the 17-20 gap), and
  every field from `approvedBindVault` (slot 21) on keeps its slot. Extend
  the gap's doc comment with this entry. Regenerate
  `script/staked-wood-layout.golden.json` with `UPDATE_GOLDEN=1
  ./script/check-layout-goldens.sh`, and REVIEW THE GOLDEN DIFF as a review
  artifact — the expected diff is exactly two lines of change (gap
  `4_storage` → `3_storage` at slot 17) plus one added entry
  (`_anchorCheckpoints`, slot 20, `t_mapping(t_address,t_struct(Trace224)...)`);
  anything else moving means the append was done wrong. The golden gate
  exists so a human sees what moved; regenerating it blind defeats it.
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
not fixed here. Interaction with **#84** (ships first, §9): #84 guards the
floor/age parameter pair against the deadlocking configuration; §3.4 shows
that same invariant is what keeps the 2b clamp from opening a
floor deadlock — the sequencing is load-bearing, not just file-contention
hygiene.

Consequences beyond the court, stated rather than hidden:
- `GuardianRegistry` review weights (:451, :931) become anchor-exact: a top-up
  AFTER `openReview` no longer deflates the frozen ballot (raw was already
  frozen; now the factor is too).
  `test_voteOnProposal_snapshotsStake_topUpDeflatesNotInflates`
  (test/GuardianRegistry.t.sol:254) pins the drift with an exact 7_499e18
  expectation (:273) that becomes 10_000e18 (par) — the test is renamed and
  re-pins "top-up neither inflates nor deflates a frozen review ballot".
  This breakage is caused by the StakedWood change alone and is UNCHANGED by
  the gate.
- Nothing relied on the drift for safety: it was documented as a tolerated
  wart ("drift is deflation-only", :648-649), never as a defence. Removing it
  only moves historical reads toward the true value, and `weight ≤ raw` still
  holds at every timestamp (factor ≤ 10_000), so every conservative-denominator
  argument survives.
- Upgrade reality: this is a StakedWood implementation change + storage
  append against a LIVE (testnet) UUPS proxy lineage. Legitimate pre-mainnet
  — no 4663 mainnet deployment, and the append-only gap-carve convention is
  exactly what the golden gate polices — but it is an upgrade with state
  consequences, not a free redeploy: on an upgraded (not redeployed) testnet
  instance, pre-upgrade history reads an empty anchor trace → `ageFloorBps`
  for old timestamps. Acceptable there, impossible on a fresh deploy.

## 3. Properties — the three the decision requires, PROVEN

### 3.1 The attack is still pinned to zero (owner property 1)

**Fresh address:** stake bought inside the window — including one second
before `executedAt` — has `rawThen = 0` and `rawNow > 0`, so the gate
(`rawNow > rawThen`) is TRUE with no way to be false, and
`weightThen = 0 × f_then / 10_000 = 0` REGARDLESS of any age-floor
multiplier: the floor multiplies raw, and zero raw times any factor is zero.
`min(weightNow, 0) = 0` → `NoVotingPower`. The issue's worked attack (1.2M
WOOD staked at `executedAt − 1` voting 300k) is closed outright.

**Partial pre-existing position:** an attacker who already held `P` at
`lookbackTs` and tops up `X` at the drain has `rawThen = P`,
`rawNow = P + X > P` — the gate is still strictly true for ANY `X > 0` —
and `weightThen = f(anchor@lb, lb) × P / 10_000`, computed entirely from
state as of `lookbackTs`. The ballot is `min(weightNow, weightThen) ≤
weightThen ≤ P`: the fresh `X` contributes exactly nothing, and the
pre-existing `P` votes at most its month-ago aged worth — which is what it
could have voted by doing nothing (§3.2 makes this exact). Drain-time
additions are pointless, not merely discounted, at every base size including
zero. Note property 1 needs only the RAW side of `weightThen` plus the
strict gate — no anchor-trace subtlety can reopen it, because `rawThen` is
an existing checkpointed read.

### 3.2 Honest top-ups are no longer double-penalized — the precise bound

Setup: base `B` with anchor `a₀ ≤ lookbackTs`, topped up by `A` at
`t ∈ (lookbackTs, snapshotTs]`; write `f_old(ts) = f(a₀, ts)` and
`f_new(ts) = f(avgAnchor, ts)`. The gate is true (`rawNow = B + A > B =
rawThen`).

**Lemma (the raw increment always covers the re-anchor at the snapshot):**
`weightNow = f_new(snap) × (B + A) ≥ f_old(snap) × B`. Below the par cap the
ramp is affine, `f(age) = c + k·age` with `c = ageFloorBps`, and the averaged
age is the stake-weighted mean of the tranche ages, so
`f_new(snap)(B + A) = c(B + A) + k(B·age_B + A·age_A) ≥ cB + k·B·age_B
≥ f_old(snap)·B` (the last step because the cap only ever reduces
`f_old`); if the averaged age is ≥ `maturationPeriod` then
`weightNow = B + A ≥ B ≥ f_old(snap)·B`. The ceil-round of the averaged
anchor (:623) costs at most one second of age, direction against the voter —
it cannot break the inequality and never favours an attacker.

**The bound:** `weightThen = f_old(lb) × B / 10_000` is computed entirely
from state as of `lookbackTs` — a later top-up cannot touch either operand
(that is §2.3's whole job). By the lemma,
`weightNow ≥ f_old(snap)·B ≥ f_old(lb)·B = weightThen`, so
`weight = min(weightNow, weightThen) = weightThen` — **exactly the
pre-existing position's true aged worth at the lookback instant, never a wei
below it.** The rejected raw-variant's failure mode (the top-up's re-anchor
dragging the base to `ageFloorBps` of itself, worst case 0.25×) cannot
occur: nothing the top-up does reaches `weightThen`'s operands.

**Owned honestly, because 2b makes it visible where 2a hid it:** the
counterfactual changed. Under 2a a non-topping young steady staker was ALSO
clamped to `f_old(lb)·B`, so "a top-up changes the ballot by exactly zero"
was true against that (already-taxed) baseline. Under 2b the non-topping
staker votes the unclamped `f_old(snap)·B` — so a top-up inside the window
forfeits the WINDOW'S AGING ON THE BASE, `(f_old(snap) − f_old(lb))·B`,
relative to doing nothing. That forfeit is ZERO for any base at par by the
lookback instant (`a₀ ≤ lb − maturationPeriod`; at deployed values, any base
older than ~60 days at the snapshot), and at most `0.75·B` in the worst case
(`a₀ = lb` exactly). The floor of the bound is unconditional — never below
the month-ago worth — which is the property the decision asked for; the
forfeit-vs-counterfactual is the honest print of what "min against a month
ago" means for a still-maturing base, and the natspec must state it rather
than reclaiming 2a's "exactly zero" line.

### 3.3 Steady positions are bit-identical to today; shrinkers get no gift

**Steady (owner property 2), as a testable invariant:** for every voter with
`rawNow ≤ rawThen`, the gate is false, the clamp NEVER EVALUATES (neither
`weightThen` nor the lookback total is even read on the short-circuit
ordering), and the recorded weight is bit-identical to the single
`getPastVotes(snapshotTs)` read the contract performs today — at EVERY age.
A 40-day steady staker votes par-track exactly as today (f(40d) = par at
deployed values), a 35-day one likewise; 2a's 50%-of-raw discount on that
cohort is gone, which is the point of the gate. The invariant is
mutation-testable: any implementation that clamps a non-growth voter
(unconditional min, `>=` in the gate, weight-based gate) breaks it.

**Shrink (strict `>` is load-bearing):** a position that REDUCED over the
window (`rawNow < rawThen`) has the gate false and votes `weightNow` — its
(smaller) current aged worth, never the larger historical figure. With `>=`
the gate would still be false here, but with the comparison INVERTED
(`rawThen > rawNow` gating a `max`, say) or with the clamp unconditionally
assigning `weightThen`, a shrinker would collect its pre-shrink weight —
strict `>` on growth plus `min` on weights forecloses both mistakes. The
equality case (`rawNow == rawThen`) lands with the steady cohort at
`weightNow`, which for an untouched position is the correct par-track read.
A shrunk-to-zero voter (`rawNow = 0`) has `weightNow = 0` and is refused at
:429, before the present-holdings gate, exactly as today.

### 3.4 The clamp cannot deadlock the participation floor (interaction with #84)

The floor's base is raw (`min(total(snap) − accused, total(lb))`,
:778-811) while clamped ballots are aged. For an electorate present at both
instants (no churn), every unaccused voter's clamped weight is
`≥ ageFloorBps/10⁴ × min(rawNow, rawThen)` on every branch of the rule, so
full honest turnout is `≥ ageFloorBps/10⁴ × base`, and #84's setter invariant
(`participationFloorBps < ageFloorBps`) keeps `floor = participationFloorBps/10⁴
× base` strictly below that. The invariant that already made aged turnout
able to clear a raw floor transfers to the clamped regime intact — one more
reason #84 ships first (§9). The exception is an electorate substantially
CHURNED inside the window (positions present at only one instant): fully
rotated capital is silenced by the gate (`rawThen = 0`) while still counted
in `total(lb)`'s complement — a forced `Inconclusive` until the new cohort
ages past the lookback. That is the fix operating as specified (identical
under 2a), and `Inconclusive` is the protocol's stated fail-safe verdict;
noted, not fixed.

## 4. Bootstrap fallback

`snapshotTs ≤ FLOOR_LOOKBACK` clamps `lookbackTs` to 0, and any lookback
instant before the first stake ever reads an empty trace. Without a fallback,
every voter in the protocol's first month has `rawThen = 0` → gate true →
`weightThen = 0` → `NoVotingPower` for ALL comers → guaranteed
`Inconclusive`, the denial mode #96 closed. The fallback carries forward from
2a unchanged in kind and keying: skip the clamp when
`getPastTotalVotes(lookbackTs) == 0`, mirroring `_participationFloor`'s
post-#96 `earlier == 0` keying (:809). Keyed on the TOTAL, which an attacker
cannot zero, never on the caller's own `rawThen` or `weightThen` (a
per-caller fallback would re-admit the fresh whale wholesale — the gate's
own `rawThen == 0` is the ATTACK signature, so it is exactly the wrong
fallback key).

**Where it sits relative to the gate and the min:** the fallback and the gate
are the two conjuncts guarding the clamp — the min applies iff
`rawNow > rawThen` AND `total(lookbackTs) != 0`; when either fails the ballot
is the unclamped `weightNow`, today's behaviour exactly. The two conditions
are independent pure reads, so their evaluation order is semantically free;
the implementation puts the gate first for the short-circuit saving (§7).
Residual: during bootstrap the ballot is as exposed as today — same window,
same shrink-to-nothing property, same smallest-TVL argument as the floor's
documented fallback.

## 5. Lookback constant

Unchanged from prior variants: reuse `FLOOR_LOOKBACK`. (i) Numerator and
denominator sample the SAME two instants — a divergent pair recreates #82's
asymmetry in miniature. (ii) Every argument on the existing constant
transfers verbatim: 30d equals the deployed `maturationPeriod`, exceeds a
full proposal lifecycle, and MUST stay a constant rather than an owner setter
(:84-90 — a settable lookback is a pre-drain shrink lever). (iii) A second
constant with the same value is a trap for future divergence. The natspec on
`FLOOR_LOOKBACK` (:80-91) gains one sentence: it now bounds the ballot as
well as the floor's base.

## 6. Attacker residual — what 2b does and does not close

- **Closed**: the fresh-whale ballot and drain-time inflation of any
  position, partial bases included (§3.1/§3.2 — additions inside the window
  never reach the clamp's binding side).
- **Residual 1 — premeditated dormant capital: 2b RETURNS to the raw
  variant's price, surrendering 2a's hardening.** Capital parked at or before
  `lookbackTs` has `rawNow ≤ rawThen` → gate false → it votes its UNCLAMPED
  aged snapshot weight. Parked exactly at `lookbackTs`, at deployed values
  (maturation = lookback = 30d) that is PAR at the snapshot. Under 2a the
  same capital voted `ageFloorBps × X = 0.25X` and needed ~60 days of
  dormancy for par ("4× harsher"); 2b trades that hardening away — it is the
  direct price of un-taxing the steady cohort, since the gate cannot tell
  premeditated month-old capital from an honest month-old guardian (they are
  on-chain identical). Counter-levers unchanged: the stake is public and
  idle for a full month before the drain it exists to protect, and a ballot
  still has to WIN against honest turnout (unlike the floor-denial, which
  needed no votes).
- **Residual 1a — the boundary cliff, new print under 2b.** One second
  decides the whole discount: parked at `lookbackTs` → par ballot; parked at
  `lookbackTs + 1` → `rawThen = 0` → gate true → zero ballot. (Under 2a the
  same cliff ran 0.25X → 0.) A cliff at the lookback is inherent to any
  two-point rule — smoothing it needs a windowed minimum over the trace,
  same closure as residual 2 — and it cuts AGAINST the attacker (the
  expensive side is the early side); documented so nobody reads the
  discontinuity as a bug.
- **Residual 2 — the touch-stake (endpoint sampling), unchanged.** Stake `X`
  just before `lookbackTs`, unstake after it, re-stake at the drain: the
  re-stake makes `rawNow = X > 0 = …` — no: `rawThen = X` (staked before
  `lookbackTs`, still staked AT it), and after the mid-window unstake and
  drain-time re-stake `rawNow = X = rawThen` → gate FALSE → ballot is
  `weightNow = f(anchor ≈ snap, snap) × X = 0.25X`, the pre-fix fresh-whale
  figure for two short cooldown locks a month apart. Identical figure in
  every variant considered (2a reached it through the min; 2b through the
  unclamped now-read — the re-stake's re-anchor does the discounting);
  closing it requires a true windowed minimum over the trace (gas-unbounded)
  or new state; out of scope, documented.
- **Not addressed, unchanged**: address-splitting by the accused
  (src/TokenCourt.sol:352-377, accepted), the floor's own residuals, and
  everything #96 covers.

## 7. Reads, rounding, and storage

- **Staticcalls per vote** (today: 2 — `getPastVotes(snap)`, `getVotes`).
  With the gate-first, short-circuiting order of §1:
  - **Non-growth branch** (gate false — steady, shrunk, dormant; the
    perpetual majority): 4 staticcalls — the two raw `getPastStake` reads are
    added, the lookback total and `weightThen` are never read. +2 vs today.
  - **Growth branch** (gate true, electorate exists): 6 staticcalls —
    `getPastStake` ×2, `getPastTotalVotes(lookbackTs)`,
    `getPastVotes(lookbackTs)`. +4 vs today.
  - Growth branch during bootstrap (total == 0): 5 — the `weightThen` read
    is skipped. +3 vs today.
  **Correction to the decision's cost assumption, printed rather than
  buried:** 2b is NOT strictly cheaper than 2a. 2a cost 4 flat (3 in
  bootstrap); 2b costs the SAME 4 on the non-growth path — the gate's two
  raw reads exactly replace the total + `weightThen` pair — and 6 on the
  growth path. What the gate buys is not fewer reads but a different
  incidence: the extra cost lands on window-growers (top-ups and fresh
  stakes, who trigger the clamp) instead of uniformly, and the steady
  majority's overhead never grows past +2. The "extra reads only on the
  growth path" framing is true only of the total/`weightThen` pair; the two
  `getPastStake` reads are paid by everyone, because the gate cannot be
  evaluated without them.
- **Rounding — an attacker's ballot cannot round upward, shown per
  component.** (i) The GATE compares two raw checkpoint integers: no
  arithmetic, no rounding, no direction to bias. (ii) Each clamp side is a
  single floored product computed inside `getPastVotes` (`raw × f / 10_000`,
  238-bit max, no overflow), exactly as today; the two multiplications the
  rule composes are floored independently and `min` commutes with the floor
  (`min(⌊a⌋, ⌊b⌋) = ⌊min(a, b)⌋`, flooring being monotone), so the composed
  weight is the true clamped value rounded DOWN — at most 1 wei low, never
  up. (iii) The attacker's side specifically: `weightThen = ⌊0 × f /
  10_000⌋ = 0` exactly — a zero raw cannot round to anything; and on the
  gate-false path no clamp arithmetic runs at all, so there is no new
  rounding surface there. (iv) The one ceiling in the system, the top-up
  anchor average (:623), rounds AGE DOWN (toward `now`) — against the
  voter, never for the attacker.
- **Storage / struct / interface**: `TokenCourt` — unchanged on all three.
  `StakedWood` — one new mapping carved off the END of the `__gap` per §2.3
  (slot 20; gap 4 → 3; golden regenerated AND ITS DIFF REVIEWED — this is
  the highest-consequence layout in the repo and the gate exists so a human
  sees the move). `IStakedWood` and `ITokenCourt` ABIs unchanged (natspec
  only); the gate's `getPastStake` reads use an interface member TokenCourt
  already imports for `_recordAccused`.

## 8. Test impact (re-derived for 2b against e34526c — NOT copied from 2a)

The question the gate raises: do the five B2 breakages survive it? **Yes —
all five still break, but the mechanism is subtler than 2a's and worth
recording, because it lives in the mock, not the contract.**
`MockStakedWood.getPastStake` DEFAULTS to the `getPastVotes` fixture value
when no explicit `setPastStake` was recorded (test/mocks/MockStakedWood.sol
— the F17 raw/aged split). The five fixtures set voterA/voterB weight at
`snap` only (`_caseWithElectorate`, test/TokenCourt.t.sol:1165-1184), so the
mock reads `rawNow = 300e18/200e18` (defaulted from the aged fixture) and
`rawThen = 0` → the GATE IS TRUE, the lookback total is non-zero in all
five, `weightThen = 0` → `NoVotingPower`:

- :1226 `test_finalize_floorIgnoresAPreDrainStakeSurge_denialOfQuorumClosed`
- :1250 `test_finalize_floorUnchangedWhenElectorateStable`
- :1272 `test_finalize_belowFloorStillInconclusive_withBothCheckpointsSet`
- :1299 `test_finalize_floorStillInflatableByAMonthOldStake_knownResidual`
- :1406 `test_finalize_floorTakesTheMinNotTheEarlierReadAlone`

(The 2a spec predicted the same five for a different reason — zero aged
weight at the lookback feeding an unconditional min. Under 2b the trigger is
the mock's raw-defaults-to-aged inference manufacturing apparent raw growth.
Same membership, different mechanism; none is spared by the gate.)

Single fix for all five, same shape as 2a's: `_caseWithElectorate`
additionally sets `setPastVotes(voterA/voterB, snap - FLOOR_LOOKBACK, same
value)` whenever `totalAtLookback != 0`. Under 2b this works through the
gate: the mock's `getPastStake` default then reads equal raw at both instants
→ gate false → clamp never evaluates — modelling MATURE STEADY stakers,
which is what those tests mean anyway, and the recorded weights are
bit-identical to today per §3.3. `MockStakedWood` needs NO member change:
`setPastStake` (explicit raw) and per-(address, timestamp) `setPastVotes`
already express every fixture the new tests need — explicit `setPastStake`
is how the new gate tests decouple raw from aged weight (§8 new-tests list).
(The mock FILE is contended three ways — #84 adds `ageFloorBps` to it, PR
#152 adds `_slashableStakeAt` members — but this change adds NOTHING to it;
sequencing only, §9.)

Stay green (verified fixture by fixture on e34526c):
- Vote-section tests :768-:919 (`_referredCase` :754 — no lookback total →
  fallback → unclamped): green; doc touch-ups on :768
  `test_vote_tallies_agedWeight` and :851
  `test_vote_acceptsACurrentHolderWithHistoricWeight` noting they exercise
  the unclamped bootstrap branch.
- :1337 underflow test — `lookbackTs` clamps to 0; gate is true (defaulted
  `rawNow > 0 = rawThen`) but the total at 0 is empty → fallback → green.
- :1385 fallback test — `totalAtLookback = 0` by construction → green.
- `_caseWithAccusedWeight` family (:1446 helper; :1516, :1545, :1574) — the
  helper never sets a lookback total → fallback; :1545's dust voter votes
  through it, :1516/:1574 never call `vote` at all → green.
- :1631 `test_finalize_floorSurvivesElectorateGrowthPastTheLookback` and
  :1695 `test_finalize_floorPinsTheReducedTermWhenItBindsBeforeTheLookback`
  — both set non-zero lookback totals but cast NO votes → green.

End-to-end: only `test/TokenCourtEndToEnd.t.sol` calls `court.vote`; its
lifecycle keeps `lookbackTs` before the first stake, the REAL StakedWood
total trace reads 0 there, every vote lands in the fallback → green
unmodified (consequence: no e2e exercises the active clamp; active-clamp
coverage is unit level).

Behavioural test changes OUTSIDE the court (caused by §2.3, not by the gate):
- test/GuardianRegistry.t.sol:254
  `test_voteOnProposal_snapshotsStake_topUpDeflatesNotInflates` — pins the
  live-anchor deflation with an exact 7_499e18 expectation (:273); under
  anchor-exact reads the weight is 10_000e18 (par). Rename + re-pin: "top-up
  neither inflates nor deflates" (raw frozen AND factor frozen). STILL
  BREAKS under 2b — the gate lives in TokenCourt and cannot reach a
  GuardianRegistry read.
- test/StakedWoodAgeWeight.t.sol — existing tests (:48-:161) read live or
  post-write timestamps and stay green; NEW tests pin anchor exactness.

New unit tests (TokenCourt.t.sol, vote section; explicit `setPastStake` used
wherever the gate must be steered independently of aged weight):
1. Steady-mature regression: equal raw and equal aged weight at both
   instants → gate false → tally and `VoteCast` equal `getPastVotes(snap)`
   bit-exactly.
2. **Young steady staker at par (THE 2b test — kills 2a):** equal raw at
   both instants, `weightThen < weightNow` (aged weight grew over the
   window) → tally equals the UNCLAMPED `weightNow`. Mutation-kills the
   unconditional min and any weight-based gate.
3. Top-up bound: `rawNow > rawThen > 0`, `weightThen` non-zero → tally is
   exactly `weightThen`, and is NOT reduced by any snapshot-side factor
   (kills a live-anchor-style implementation).
4. Gate-true, weight-fell coherence (§1.1): `rawNow > rawThen` with
   `weightNow < weightThen` (re-anchored fixture) → tally is `weightNow` —
   the min pays no more than current worth even on the growth path.
5. Shrink: `rawNow < rawThen`, `weightThen > weightNow` → tally is
   `weightNow`; mutation-kills `>=`-gating and any rule that hands a
   shrinker the historical figure.
6. Fresh-address attack regression (#82): `rawThen = 0`, non-zero snap
   weight, non-zero lookback total → `NoVotingPower`, tally untouched.
   Mutation-kills reverting to the bare :428 read.
7. Partial-position attacker (§3.1): `rawThen = P`, drain-time top-up →
   tally is exactly the base's month-ago worth, unmoved by the top-up size.
8. Bootstrap: lookback total 0, gate true → weight unclamped.

## 9. Coordination flags (re-verified on e34526c, 2026-08-03)

- **#84** (`enforce-floor-invariant-in-setters`) ships FIRST — implemented
  and committed at `d81d02a` on `fix/issue-84-floor-invariant-guard`,
  awaiting build validation; this change rebases on its merge. It edits
  `TokenCourt.sol` setters + natspec, `ITokenCourt`, `DeployTokenCourt`,
  adds `ageFloorBps`/`setAgeFloorBps` to `test/mocks/MockStakedWood.sol`,
  and rewrites large parts of `test/TokenCourt.t.sol` (~248 lines) — **this
  spec's TokenCourt.t.sol line references WILL shift at that rebase and must
  be re-verified then.** Beyond file hygiene the sequencing is semantic:
  §3.5's no-deadlock argument leans on #84's setter invariant.
- **PR #144 (issue #83) has MERGED** (5fda5be, in this base) — 2a's "open
  PR, coordinate the test file" flag is retired; line refs here are already
  post-#83.
- **PR #152 (issue #35, `anchor-coverage-at-execution`) is OPEN and
  off-limits** — do not touch its worktree or branch. Verified against its
  actual diff, not its description: it adds VIEW functions
  (`slashableStakeAt`/`_slashableAt`) to `src/StakedWood.sol`, a member to
  `IStakedWood`, and `_slashableStakeAt`/`_slashableStakeAtSet` mappings to
  the TEST MOCK only — **zero storage in `src/StakedWood.sol`, no golden
  file touched** (its own proposal pins "all four layout goldens
  byte-identical"). This change's `_anchorCheckpoints` is therefore the
  FIRST StakedWood storage append of the two, but both changes edit
  `src/StakedWood.sol`, `src/interfaces/IStakedWood.sol` and
  `test/mocks/MockStakedWood.sol`, so textual conflicts are likely: merge
  order must be EXPLICIT, the layout golden is regenerated (and its diff
  re-reviewed) after whichever lands SECOND, and it is THIS branch that
  rebases and adjusts — never theirs.
- **#96 (PR #120) has MERGED** — the ballot fallback mirrors its
  `earlier == 0` keying (:809), re-verified on e34526c.
- PR targets `main` (stacked PRs get no CI in this repo).

## 10. Implementation file list

- `src/StakedWood.sol` — `_anchorCheckpoints` (gap 4 → 3, slot 20, gap doc
  extended), pushes at :604, :623, :843, `getPastVotes` body (:666-669),
  natspec (:644-669 and the deflation-drift mentions).
- `script/staked-wood-layout.golden.json` — regenerated via `UPDATE_GOLDEN=1`,
  diff reviewed (expected: gap 4→3 + one `_anchorCheckpoints` entry at slot
  20, nothing else moves).
- `src/TokenCourt.sol` — `vote` (:421-441), natspec :328-420 and :80-91.
- `src/interfaces/IStakedWood.sol`, `src/interfaces/ITokenCourt.sol` — natspec
  only (IStakedWood :101-117 aged/raw read docs; ITokenCourt :157 / :199 /
  :319-327).
- `test/TokenCourt.t.sol` — `_caseWithElectorate` (:1165-1184), doc touch-ups
  (:768, :851), eight new tests (§8).
- `test/StakedWoodAgeWeight.t.sol` — anchor-exactness tests.
- `test/GuardianRegistry.t.sol` — :254 rename + re-pin.
- No other source, interface, mock, or script files. In particular
  `test/mocks/MockStakedWood.sol` is deliberately untouched (three-way
  contention, §9).
