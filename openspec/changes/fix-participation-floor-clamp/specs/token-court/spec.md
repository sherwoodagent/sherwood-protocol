## MODIFIED Requirements

### Requirement: Participation floor

The participation floor SHALL be `participationFloorBps × base / 10_000` where the base is computed in two steps, both at `finalize` time:

1. **Same-instant accused reduction, clamped at zero**: `reduced = total(snapshotTs) > accusedWeight ? total(snapshotTs) - accusedWeight : 0`. `accusedWeight` sums the same raw-stake basis as `total(snapshotTs)` over a subset of the same addresses (the accused set), read at the same instant, so `accusedWeight <= total(snapshotTs)` holds structurally under one consistently-wired electorate source and the clamp exists only as defence-in-depth for an out-of-band `setStakedWood` re-point. Because the subtraction is same-instant, staking more by an accused address raises `total(snapshotTs)` and `accusedWeight` together and leaves `reduced` unchanged — there is no lever by which the accused can buy a higher floor by staking. The floor SHALL be monotone non-increasing as a function of WHICH addresses are named accused: naming one more address can only remove that address's stake from `reduced`, never add to it.
2. **Lookback min**: `base = (getPastTotalVotes(snapshotTs - FLOOR_LOOKBACK) != 0 && getPastTotalVotes(snapshotTs - FLOOR_LOOKBACK) < reduced) ? getPastTotalVotes(snapshotTs - FLOOR_LOOKBACK) : reduced`, i.e. `base = min(earlier, reduced)` with a fallback to `reduced` when the lookback read is zero (no electorate existed a lookback ago, including a `snapshotTs` inside the chain's first `FLOOR_LOOKBACK`, where the lookback instant clamps to 0) — a zero base there would disable the anti-capture floor for the protocol's whole bootstrap window. `accusedWeight` is never subtracted from the earlier read; only `reduced` (step 1's output) is compared against it. The min defeats the pre-drain stake-surge denial lever: an attacker inflating the electorate immediately before their own drain (the attacker is exactly the party who knows when `executedAt` will be) must have the inflating stake present at BOTH instants, i.e. visibly parked on-chain for a month before the drain it exists to protect. A zero floor is safe because `finalize`'s `turnout == 0` guard still forces `Inconclusive` on an empty vote — a zero floor never lets a zero-turnout case resolve on the merits.

Turnout is summed in aged weight while the base is raw, so aging only ever makes the floor harder to reach, never easier — the floor stays conservative. The floor SHALL read the LIVE `participationFloorBps` and the LIVE `stakedWood` at `finalize` time, deliberately not pinned per case: the floor is consumed exactly once, after voting has closed, so a change cannot retroactively alter any cast ballot, and a floor change applies to every case finalizing after it takes effect.

#### Scenario: Floor base excludes accused stake

- **WHEN** `finalize` computes the floor and `accusedWeight` is below the electorate base
- **THEN** the base is the electorate base minus the case's recorded `accusedWeight`, so the accused's own stake never inflates the turnout bar its jury must clear

#### Scenario: Floor is monotone across the accused-weight boundary

- **GIVEN** two otherwise identical cases whose recorded `accusedWeight` differ only in that one is just below the electorate base and the other is at or above it
- **WHEN** `finalize` computes each floor
- **THEN** the floor of the larger-`accusedWeight` case is less than or equal to the floor of the smaller — the floor never jumps up when `accusedWeight` crosses the base

#### Scenario: Accused outweighing the electorate cannot deny a verdict

- **GIVEN** a case whose recorded `accusedWeight` is at or above the electorate base
- **WHEN** a single unaccused voter with any non-zero aged snapshot weight votes and the window elapses
- **THEN** the floor is zero, turnout meets it, and `finalize` resolves the case on the merits rather than `Inconclusive` — the accused cannot buy a denial by staking past the base

#### Scenario: Zero floor never resolves an empty vote

- **GIVEN** a case whose recorded `accusedWeight` is at or above the electorate base, so the floor is zero
- **WHEN** the window elapses with no votes cast
- **THEN** `finalize` still returns `Inconclusive` via the `turnout == 0` guard — the clamp delegates the empty-vote case to that guard, never to the floor

#### Scenario: Floor change applies to a live case

- **WHEN** the owner changes `participationFloorBps` while a case is in `Voting`
- **THEN** that case's `finalize` uses the new value — the floor is read live at finalization, unlike the case's pinned snapshot and window
