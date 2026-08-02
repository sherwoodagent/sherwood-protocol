# Design — fix-ballot-growth-lookback (issue #82, narrow variant)

## 0. Verified premises (file:line, this branch = origin/main b8b6d0d)

- Ballot weight is a single read at the snapshot:
  `uint256 weight = IStakedWood(stakedWood).getPastVotes(msg.sender, c.snapshotTs);`
  — src/TokenCourt.sol:420.
- `StakedWood._ageFactorBps` returns `ageFloorBps` at age 0 and saturates
  `ts < stakedAt_` to age 0 (src/StakedWood.sol:594-600); `getPastVotes` is the
  raw checkpoint times that factor, and — load-bearing below — the factor is
  computed from the LIVE stored `_guardians[g].stakedAt`, not a historical one
  (src/StakedWood.sol:610-613). Deployed `ageFloorBps` = 2,500, so one-second-old
  stake votes at 25% of raw.
- The B2 `min` exists only in `_participationFloor` (src/TokenCourt.sol:725-740;
  the min itself at :737, fallback condition `earlier != 0` at :733-737).
  Denominator protected, ballot not.
- Present-holdings gate is binary at src/TokenCourt.sol:423; its natspec
  (:386-412) concedes the 25%-of-historic-weight residual and bounds it by
  `minGuardianStake` — but the fresh-whale variant of #82 is unbounded (weight
  scales with the stake bought) and fully recoverable.
- `FLOOR_LOOKBACK = 30 days`, a constant, src/TokenCourt.sol:91 (rationale
  :80-90).
- `IStakedWood` already exposes everything needed: `getPastVotes` (:97),
  `getPastStake` (:104, raw own-stake checkpoint), `getPastTotalVotes` (:109)
  — src/interfaces/IStakedWood.sol.
- Top-ups re-anchor `stakedAt` to the stake-weighted average of the old anchor
  and now (src/StakedWood.sol:561-567) and push a raw checkpoint
  (src/StakedWood.sol:573).

## 1. The rule, in arithmetic

Definitions, all reads against the live `stakedWood`:

```
lookbackTs = snapshotTs > FLOOR_LOOKBACK ? snapshotTs - FLOOR_LOOKBACK : 0
rawNow     = getPastStake(voter, snapshotTs)      // raw own checkpoint
rawThen    = getPastStake(voter, lookbackTs)      // raw own checkpoint
f          = ageFactorBps evaluated at snapshotTs  // implicit in getPastVotes
```

Rule (with the bootstrap fallback of §4):

```
weight = f * min(rawNow, rawThen) / 10_000
```

Implemented without exposing `f`, using only existing getters — note
`getPastVotes(voter, snapshotTs) == rawNow * f / 10_000`:

```solidity
uint256 weight = IStakedWood(stakedWood).getPastVotes(msg.sender, c.snapshotTs);
if (electorateAtLookback != 0 && rawNow > rawThen) {
    // rawNow > rawThen >= 0 implies rawNow > 0: the division is safe.
    weight = Math.mulDiv(weight, rawThen, rawNow);
}
if (weight == 0) revert NoVotingPower();
```

`Math.mulDiv` (OpenZeppelin, new import) because checkpoints are `uint224` and
`weight * rawThen` can exceed 2^256 in principle; `mulDiv` floors, which is the
conservative direction (never over-weights). Precision: the composed value is
`floor(floor(rawNow*f/1e4) * rawThen / rawNow) <= floor(rawThen*f/1e4)`, i.e. at
most 1 wei below the exact clamped weight.

This is deliberately NOT the issue's blanket
`min(getPastVotes(snap), getPastVotes(snap - FLOOR_LOOKBACK))`: both operands
there pass through the age factor at their respective query instants, so the
earlier read is doubly reduced (younger age AND — because `_ageFactorBps` reads
the LIVE `stakedAt` — saturated to the age floor for anyone who re-anchored).
The narrow rule takes the min over RAW checkpoints only and applies the age
factor once, at the snapshot.

### Proof (a): a steady staker's weight is unchanged

"Steady over the window" means the raw checkpoint trace is constant on
`[lookbackTs, snapshotTs]`, so `rawNow == rawThen`. The `rawNow > rawThen`
branch is not taken and `weight` is the untouched
`getPastVotes(msg.sender, c.snapshotTs)` — bit-identical to src/TokenCourt.sol:420
today, at every age. In particular a guardian who first staked 31 days before
the snapshot votes at full par-ramped weight, where the blanket min would have
paid them `f(age 1 day) ≈ 27.5%`. This is the property Ana chose the narrow
variant for.

### Proof (b): stake ADDED right before the drain is discounted to (at most) the prior level

Growth inside the window means `rawNow > rawThen`, so
`weight = f_snap * rawThen / 1e4`: the raw basis is exactly the pre-growth
level; the increment `rawNow - rawThen` carries zero ballot. Two sub-cases:

- Fresh address (`rawThen == 0`): weight = 0 → `NoVotingPower`. The issue's
  worked attack (1.2M WOOD staked at `executedAt - 1` voting 300k) is closed
  outright.
- Top-up on an existing base `B` by `A`: weight `= f_snap * B / 1e4`. Note
  `f_snap` is computed from the POST-top-up re-anchored `stakedAt`
  (src/StakedWood.sol:561-567), which only moves forward, so
  `f_snap <= f_pre-top-up` and the result is `<=` the weight the voter had
  before topping up. The discount is to at most the prior level — see §2 for
  the honest-cost quantification of the "below prior level" slack, and §3 for
  why this slack is defence-positive against an attacker (a drain-time top-up
  actively shrinks the attacker's own pre-existing ballot).

### Proof (c): a REDUCED position is not rewarded with the higher historical figure

Shrinkage means `rawNow < rawThen`. The branch condition `rawNow > rawThen` is
false, so `weight = getPastVotes(snapshotTs) = f_snap * rawNow / 1e4` — the
weight of the SMALLER current checkpoint. `min(rawNow, rawThen) == rawNow`
here, so the "min" formulation and the branch are the same function; there is
no path on which `rawThen > rawNow` enters the weight. The obvious wrong
implementation — `weight = f * rawThen` whenever the two differ — would hand an
exiting whale its historical ballot; the branch direction (`>` strictly, clamp
DOWN only) excludes it. Additionally, an actual unstake request pushes a 0 raw
checkpoint and zeroes `getVotes` from the request instant, so a shrunk-to-zero
voter is already refused by :421/:423 before the clamp matters.

## 2. Age-factor interaction — does the ~60-day cost leak back in?

For single-stake guardians, no, and exactly: the narrow rule touches only
positions whose raw trace moved inside the window, and a single stake older
than `FLOOR_LOOKBACK` has a flat trace, so cohort 30-60 days (the cohort the
blanket min silently taxed through the earlier read's smaller age factor) is
bit-identical to today. This was the point of the variant, and it holds.

Two honest costs remain, and they are real; stated plainly:

1. **Guardians younger than 30 days are zeroed.** First stake inside the
   window → `rawThen = 0` → `NoVotingPower`. Today they vote at
   `f(age) ∈ [25%, 100%)`. This is not a leak of the 60-day cost — it is the
   fix itself: near-drain stake IS what the rule discounts, and no
   endpoint-sampled rule can distinguish an innocent 10-day-old guardian from
   the attacker's 10-day-old ballot. Identical under the blanket variant
   (whose `then`-read is also 0 there). Bounded by the window: heals at stake
   age 30 days.
2. **Honest top-ups temporarily vote BELOW their pre-top-up level, not just at
   it.** The clamp pins the raw basis to `rawThen = B`, but the top-up itself
   re-anchored `stakedAt` forward, so `f_snap < f_pre` whenever the
   stake-weighted average age falls below `maturationPeriod`. Quantified at
   deployed defaults (floor 2,500 bps, maturation 30 days): a guardian with
   base `B` at age `a_0` topping up `A` at time `t` before the snapshot has
   average age `(B*a_0 + A*t')/(B+A)` at the snapshot (`t'` = increment age);
   e.g. `A = B`, `a_0 = 40d`, top-up at the snapshot → avg age 20d →
   `f = 7,500` → votes `0.75 B` vs `1.0 B` before. Worst case is a huge
   top-up on a barely-mature base: `f → ageFloorBps`, i.e. down to `0.25 B`.
   If `a_0` is large enough that the average stays ≥ 30d (e.g. `A = B`,
   `a_0 >= 60d`), the cost is exactly zero. This under-shoot is the EXISTING
   StakedWood re-anchor mechanic (src/StakedWood.sol:561-567) showing through
   — the clamp inherits it rather than creating it — but under current code
   the raw increment compensated (`f_new*(B+A) >= f_old*B` typically) and
   under the clamp it cannot, so a top-up becomes weakly weight-DECREASING for
   up to `maturationPeriod`. This is the one place the narrow rule costs an
   honest grower something the current code did not; it is transient, bounded
   by `(1 - f_new/f_old) <= 75%` of the base, applies only to the base (the
   increment's silence is cost 1), and must go in the natspec verbatim rather
   than being absorbed.

## 3. Attacker residual — what the narrow rule does NOT close

Honest accounting; the natspec must claim pricing, not elimination:

- **Closed**: the fresh-whale ballot (issue #82's headline). `rawThen = 0` →
  zero weight. Also closed: inflating an existing accomplice position at the
  drain — the clamp pins it to `rawThen`, and the re-anchor drags `f_snap`
  toward the floor, so a drain-time top-up strictly SHRINKS the attacker's
  pre-existing ballot (from `f_old * B` toward `0.25 B`). Doing nothing beats
  topping up; the rule makes drain-time additions self-defeating.
- **Residual 1 — premeditated dormant capital.** Stake `X` at least
  `FLOOR_LOOKBACK` before the drain and hold: `rawThen = rawNow = X`, steady,
  full aged weight (par at deployed maturation = 30d = the lookback). The
  never-approving address is not accused, not slashable
  (`slashVerdict` touches only approvers), and exits after cooldown. What
  changed is price and posture: the capital must be committed a month early —
  before the proposal is even FILED (`FLOOR_LOOKBACK` exceeds a full
  `SyndicateGovernor` lifecycle, the :643-646 argument) — sitting visible and
  idle. And the required principal is SMALLER than the fresh-whale variant's
  (par instead of 25%: the issue's tie needs ~300k parked instead of 1.2M
  fresh), so for a patient attacker the fix trades a 4x principal discount for
  a 30-day commitment made before the outcome is knowable. This is the same
  shape and the same honesty as the floor's own pinned residual
  (test_finalize_floorStillInflatableByAMonthOldStake_knownResidual,
  test/TokenCourt.t.sol:1150); the counter-levers are likewise the same:
  the stake is public for a month, and the accused-set / challenge machinery
  operates on the merits regardless of one large voter (a vote still has to
  win against honest turnout, unlike the floor-denial which needed no votes).
- **Residual 2 — the touch-stake (endpoint sampling).** The rule samples the
  raw trace at exactly two instants. An attacker who knows `executedAt` in
  advance (their own drain) can stake `X` just before `lookbackTs`, unstake
  after it (capital locked only `coolDownPeriod`, floor 1 day), and re-stake
  `X` at the drain: `rawThen = rawNow = X` → steady → clamp is a no-op. The
  age factor still bites — the re-stake makes `stakedAt` fresh, so the ballot
  is `ageFloorBps * X = 0.25 X`, exactly the pre-fix fresh-whale figure — but
  the capital cost drops from 30 idle days to two short locks a month apart.
  NOTE: the blanket `min` has this hole identically (its `then`-read is
  `raw * f(live stakedAt saturated to 0) = 0.25 X` too, because
  `_ageFactorBps` uses the live anchor), so this residual is not a cost of
  choosing the narrow variant. Closing it would require a true windowed
  minimum over the checkpoint trace (gas-unbounded iteration) or new state;
  out of scope, documented.
- **Not addressed, unchanged**: address-splitting by the accused
  (src/TokenCourt.sol:351-369, accepted), the floor's own residuals, and
  everything #96 covers.

## 4. Bootstrap fallback

`snapshotTs <= FLOOR_LOOKBACK` clamps `lookbackTs` to 0, and any lookback
instant before the first stake ever reads an empty trace. Without a fallback,
`rawThen = 0` for EVERY voter → every case in the protocol's first month
reverts `NoVotingPower` for all comers → guaranteed `Inconclusive`, which is
the denial mode #96 exists to close. Mirror `_participationFloor` exactly
(src/TokenCourt.sol:733-737): skip the clamp when
`getPastTotalVotes(lookbackTs) == 0`. Keyed on the TOTAL, which an attacker
cannot zero, never on the caller's own `rawThen` (a per-caller fallback would
re-admit the fresh whale wholesale). Residual: during bootstrap the ballot is
exactly as exposed as today — same window, same shrink-to-nothing property,
same smallest-TVL argument as the floor's documented fallback (:651-672).

## 5. Lookback constant

Reuse `FLOOR_LOOKBACK`. (i) Numerator and denominator then sample the SAME two
instants — a divergent pair recreates #82's asymmetry in miniature (a band of
stake that votes but is excluded from the base, or vice versa). (ii) Every
argument on the existing constant transfers verbatim: 30d equals the deployed
`maturationPeriod` (the aging horizon the numerator already uses), exceeds a
full proposal lifecycle, and MUST stay a constant rather than an owner setter
(:84-90 — a settable lookback is a pre-drain shrink lever). (iii) A second
constant with the same value is a trap for future divergence. The natspec on
`FLOOR_LOOKBACK` (:80-91) gains one sentence: it now bounds the ballot's raw
basis as well as the floor's base.

## 6. No storage change — confirmed

`Case` struct untouched; no new storage variables; no `StakedWood` or interface
change (`getPastStake` :104 and `getPastTotalVotes` :109 already in
`IStakedWood`); no new error (reuse `NoVotingPower`). Delta vs the issue's
claim: not a one-line ternary (that was the blanket variant) but ~8 lines in
`vote` plus one import (`Math` for `mulDiv`). Cost per vote: 3 extra
staticcalls (2× `getPastStake`, 1× `getPastTotalVotes`) and one `mulDiv` on the
grew path.

Deliberate non-alternatives:
- A `StakedWood.getPastVotesLookback(...)` or an exposed age-factor getter
  would be cleaner arithmetic but expands scope to `StakedWood` + interface +
  redeploy of a second contract; rejected for blast radius.
- Raw `weight * rawThen / rawNow` without `mulDiv` risks (theoretical)
  overflow at uint224-scale checkpoints; rejected.

## 7. Test impact (exact, current line numbers)

Breaks without updating — all five B2 floor tests vote via
`_castFullTurnoutAndCloseWindow` (test/TokenCourt.t.sol:1043) under a NON-zero
lookback total, so the clamp activates and voterA/voterB (weights set only at
`snap`) hit `rawThen = 0` → `NoVotingPower`:
- test/TokenCourt.t.sol:1077 `test_finalize_floorIgnoresAPreDrainStakeSurge_denialOfQuorumClosed`
- test/TokenCourt.t.sol:1101 `test_finalize_floorUnchangedWhenElectorateStable`
- test/TokenCourt.t.sol:1123 `test_finalize_belowFloorStillInconclusive_withBothCheckpointsSet`
- test/TokenCourt.t.sol:1150 `test_finalize_floorStillInflatableByAMonthOldStake_knownResidual`
- test/TokenCourt.t.sol:1257 `test_finalize_floorTakesTheMinNotTheEarlierReadAlone`

Single fix for all five: `_caseWithElectorate` (test/TokenCourt.t.sol:1016,
weight wiring at :1031-1034) additionally sets voterA/voterB weight at
`snap - FLOOR_LOOKBACK` whenever `totalAtLookback != 0` — modelling the voters
as steady stakers, which is what those tests mean anyway.
`MockStakedWood.getPastStake` defaults to the `setPastVotes` value
(test/mocks/MockStakedWood.sol:110-112), so `setPastVotes(voter, lookbackTs,
sameWeight)` suffices; `setPastStake` (:105) is available where a test needs
the raw/aged gap.

Stay green but PIN the semantics being changed (they pass through the
bootstrap fallback because the mock's lookback TOTAL is unset — doc-comment
touch-ups only, no assertion changes):
- test/TokenCourt.t.sol:619 `test_vote_tallies_agedWeight` (single-read wording)
- test/TokenCourt.t.sol:632 `test_vote_emitsWeight`
- test/TokenCourt.t.sol:702 `test_vote_acceptsACurrentHolderWithHistoricWeight`
  (":707 weight is still the SNAPSHOT figure" — true only via fallback now)
- test/TokenCourt.t.sol:669/:691/:722/:738 (exit/cooldown/NoVotingPower
  ordering) — unaffected logic, green.
- test/TokenCourt.t.sol:1188 underflow test — `lookbackTs` clamps to 0, total
  there is 0 → fallback → green.

End-to-end: only `test/TokenCourtEndToEnd.t.sol` calls `court.vote`
(:480, :483, :594, :756, :796, :983, :1006). Its guardians stake in `setUp`
(:317) and the lifecycle advances hours-to-days, so `lookbackTs` predates the
first stake, the REAL StakedWood's total trace reads 0 there, and every vote
lands in the bootstrap fallback → suite green unmodified. (Consequence: no
existing e2e exercises the active clamp; the new coverage lives at the unit
level against the mock.) `ChallengeEndToEnd` / `CoverageEndToEnd` never call
`court.vote`. `StakedWoodAgeWeight.t.sol` tests StakedWood itself — untouched.

New tests (unit, TokenCourt.t.sol, vote section — all with lookback total set
non-zero so the clamp is live):
1. Steady staker regression: identical raw at both instants → weight equals
   `getPastVotes(snap)` exactly (assert against the mock value, bit-exact).
2. Grew: `rawNow > rawThen` with an aged/raw gap (use `setPastStake` for raws,
   `setPastVotes` for the aged snap figure) → tally and `VoteCast` equal
   `mulDiv(aged, rawThen, rawNow)`.
3. Shrank: `rawNow < rawThen` → weight equals the unclamped
   `getPastVotes(snap)` (not the historical figure).
4. Fresh address: snap weight non-zero, `rawThen = 0`, lookback total non-zero
   → `NoVotingPower` (the #82 attack regression, mutation-kills reverting the
   clamp).
5. Bootstrap: lookback total 0 → weight unclamped (pins the fallback and keeps
   the guaranteed-Inconclusive month closed).

## 8. Coordination flags

- **#96 sibling branch** `fix/issue-96-participation-floor` (local worktree
  issue-96-court, 82b4cc2): its TokenCourt.sol hunks are @@358 (natspec
  :360-365 area), @@566-614 (`_participationFloor` natspec + body, :569-586,
  :735-745) and it adds 159 lines to test/TokenCourt.t.sol. This change's code
  hunk (:413-433) is disjoint, but its natspec edits at :333-340 (flash-loan
  block) and :386-412 sit directly above/below #96's @@358 hunk in the same
  @dev run above `vote` — textual conflicts are likely on merge, and whichever
  lands second must re-verify that the ballot fallback here still mirrors
  whatever #96 made of `_participationFloor`'s `earlier == 0` branch (:737 is
  inside #96's third hunk). Merge #96 first, then rebase this.
- **PR #104** (`feat/lane-a-enablement`): no `src/TokenCourt.sol` or
  `src/StakedWood.sol` changes — no overlap.
- **PR #88** (`spec/wood-twap-ceiling`): touches `test/TokenCourtEndToEnd.t.sol`
  only in `setUp` oracle wiring (+8 lines near :212-220) — no overlap with this
  change (which does not modify that file).
- **#81 is CLOSED won't-fix** — nothing here bars challengers/funders from
  voting; this change ships alone.

## 9. Implementation file list

- `src/TokenCourt.sol` — `vote` (:413-433), natspec :327-412 and :80-91,
  `Math` import.
- `test/TokenCourt.t.sol` — `_caseWithElectorate` (:1016-1034), five B2 test
  fixtures via the helper, doc touch-ups (:619, :702), five new tests.
- No other source, interface, mock, or script files.
