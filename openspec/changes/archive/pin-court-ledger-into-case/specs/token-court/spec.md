# token-court (delta)

## MODIFIED Requirement: Case inputs are pinned at referral

Every input a case's verdict depends on SHALL be resolved exactly once, at
`refer`, and stored on the `Case` record. This now includes the exposure
ledger that produced the accused set.

#### Scenario: ledger pinned at refer

- **GIVEN** a disputed challenge on the wired `ChallengeGame`
- **WHEN** `refer(challengeId)` executes
- **THEN** the ledger address read from `IChallengeGameLedger(game).exposureLedger()`
  is stored in `Case.ledger`, and `_recordAccused` consumes that same resolved
  address (single read — no second live resolution within the call).

#### Scenario: owner re-point after refer does not disturb the case

- **GIVEN** a referred case with a non-empty accused set and `accusedWeight > 0`
- **WHEN** the game owner calls `ChallengeGame.setExposureLedger(newLedger)`
  where `newLedger.approversOf(...)` returns an empty set
- **THEN** `Case.ledger`, the `isAccused` set, and `Case.accusedWeight` are
  unchanged, and `finalize`'s participation floor uses the pinned
  `accusedWeight`.

#### Scenario: ledger and accused weight are pinned together

- **GIVEN** any referred case
- **THEN** `Case.accusedWeight` equals the `getPastStake` sum computed over the
  approvers of `Case.ledger` at `Case.snapshotTs` (the derived weight can never
  come from a different ledger than the pinned one).

## MODIFIED Requirement: Residual re-point window is documented

The contract SHALL document (natspec on `refer` / `_recordAccused`) that an
owner re-point of the game's exposure ledger strictly **between `file` and
`refer`** still produces an empty accused set, that this is owner-only and
recoverable by re-pointing back before `refer`, and that closing it requires
either an at-`file` pin inside `ChallengeGame` or a live-challenge guard on
`setExposureLedger` (follow-up decision, out of scope for this change).
