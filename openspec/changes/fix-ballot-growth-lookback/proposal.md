# fix-ballot-growth-lookback

## Why

Issue #82: the B2 lookback protects the participation floor's denominator but not
the ballot. `TokenCourt.vote` reads weight in a single call —
`getPastVotes(msg.sender, c.snapshotTs)` (src/TokenCourt.sol:420) — and
`StakedWood._ageFactorBps` floors at `ageFloorBps` (deployed 2,500 bps) rather
than zeroing, so WOOD staked one second before the drain's `executedAt` votes at
25% of raw. A never-approving address is outside the accused set, untouched by
`slashVerdict`, and fully recoverable after cooldown — the issue's worked trace
buys a tie (acquittal) for ~7 days of capital lock.

The issue's proposed blanket fix — `min(getPastVotes(snap),
getPastVotes(snap − FLOOR_LOOKBACK))` — was **rejected by the owner**: the
earlier read re-evaluates the age factor at the earlier instant, so it discounts
(and for < 30-day stakers, silences) every honest guardian whose stake is
younger than roughly `maturationPeriod + FLOOR_LOOKBACK` (~60 days at deployed
defaults). Shrinking the honest electorate worsens the exact `Inconclusive`
denial mode #96 is closing. The chosen variant is **narrow**: discount only the
stake that GREW inside the lookback window; a steady or shrinking position keeps
its full snapshot weight, bit-identical to today.

## What Changes

- `TokenCourt.vote` clamps the ballot's raw basis to its level one
  `FLOOR_LOOKBACK` before the snapshot, keeping the age factor evaluated once at
  `snapshotTs`:
  `weight = ageFactor(snapshotTs) × min(rawNow, rawThen) / 10_000`, implemented
  as `mulDiv(getPastVotes(snap), rawThen, rawNow)` applied only when
  `rawNow > rawThen`.
- Bootstrap fallback mirroring `_participationFloor` (src/TokenCourt.sol:733-737):
  the clamp is skipped when `getPastTotalVotes(lookbackTs) == 0` — no electorate
  existed a lookback ago, so there is nothing to compare against; otherwise every
  case in the chain's first month would be unvotable, a guaranteed
  `Inconclusive`.
- No storage, struct, interface, or `StakedWood` change. All inputs already
  exist: `Case.snapshotTs`, `FLOOR_LOOKBACK`, and `IStakedWood.getPastStake` /
  `getPastTotalVotes`. One new import (OpenZeppelin `Math`) for overflow-safe
  `mulDiv`.
- Natspec: the flash-loan block above `vote` (src/TokenCourt.sol:333-340) is
  extended for the clamp; the present-holdings residual text (:386-412) and the
  `FLOOR_LOOKBACK` doc (:80-91) are updated; residuals (dormant capital,
  touch-stake, endpoint sampling) are documented rather than claimed closed.
- Tests: `_caseWithElectorate` (test/TokenCourt.t.sol:1016) models steady
  voters at the lookback instant; new tests cover steady / grew / shrank /
  fresh-address / bootstrap cases.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `token-court`: the **Voting** requirement changes — ballot weight is no longer
  the bare `getPastVotes(snapshotTs)` read; stake growth inside the
  `FLOOR_LOOKBACK` window preceding the snapshot is excluded from the ballot's
  raw basis (with the bootstrap fallback), and `NoVotingPower` now also refuses
  an address whose entire position is younger than the lookback (clamped weight
  zero).

## Impact

- `src/TokenCourt.sol` — `vote` body (:413-433), natspec blocks (:327-412,
  :80-91), new `Math` import. Disjoint from #96's code hunk at
  `_participationFloor` (:738), but #96's natspec hunks (@@358, @@566) sit
  adjacent to this change's natspec edits — merge-order coordination needed.
- `test/TokenCourt.t.sol` — helper `_caseWithElectorate` and the five B2 floor
  tests that vote under a non-zero lookback total would otherwise revert
  `NoVotingPower`; new vote-weight tests added.
- No deployment-wiring, interface, or cross-contract impact. Open PRs #104 and
  #88 do not touch `src/TokenCourt.sol` (#88 touches
  `test/TokenCourtEndToEnd.t.sol` setup lines only — no conflict with this
  change's test edits).
