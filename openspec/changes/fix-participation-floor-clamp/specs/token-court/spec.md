## MODIFIED Requirements

### Requirement: Participation floor

The participation floor SHALL be `participationFloorBps × base / 10_000` where the base is computed in two steps, both at `finalize` time:

1. **Electorate base**: `min(getPastTotalVotes(snapshotTs), getPastTotalVotes(snapshotTs - FLOOR_LOOKBACK))`, except when the lookback read is zero (no electorate existed a lookback ago, including a `snapshotTs` inside the chain's first `FLOOR_LOOKBACK`, where the lookback instant clamps to 0), in which case the snapshot total stands — a zero base there would disable the anti-capture floor for the protocol's whole bootstrap window. The min defeats the pre-drain stake-surge denial lever: an attacker inflating the electorate immediately before their own drain (the attacker is exactly the party who knows when `executedAt` will be) must have the inflating stake present at BOTH instants, i.e. visibly parked on-chain for a month before the drain it exists to protect.
2. **Accused subtraction, clamped at zero**: `base = base > accusedWeight ? base - accusedWeight : 0`. The floor SHALL be monotone non-increasing in `accusedWeight`: growing the accused cohort's recorded stake never raises the floor its jury must clear. When `accusedWeight >= base` — a reachable state, because the lookback can pick an earlier, smaller electorate while `accusedWeight` is measured at `snapshotTs` — the base SHALL clamp to zero, never fall back to the unreduced base. The adversary this clamp defeats is the accused set itself: with a fallback to the unreduced base, an accused approver could stake enough before the drain to push `accusedWeight` past the base and jump the floor from near-zero to its maximum, forcing `Inconclusive` (no slash, no conviction mark, no demotion, counter-bond returned whole) for one extra wei of stake. A zero floor is safe because `finalize`'s `turnout == 0` guard still forces `Inconclusive` on an empty vote — a zero floor never lets a zero-turnout case resolve on the merits — and any single unaccused voter clearing a zero floor is the correct continuous limit of the subtraction.

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
