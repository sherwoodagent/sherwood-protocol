# Design

## Shape of the change

One read, one write, all consumers downstream — identical to how `snapshotTs`
(D2) and `game` are handled in `refer` today.

```solidity
// refer(), after the existing pins:
address ledger = IChallengeGameLedger(game).exposureLedger();
c.ledger = ledger; // pinned: setExposureLedger afterward must not re-derive this case's accused set
...
_recordAccused(caseId, c, ledger, ch.governor, ch.proposalId, snapshotTs);
```

`_recordAccused` drops its `game` parameter (its only use was the ledger
lookup) and takes `address ledger` directly. No other body changes: the
approver loop, the `committedUsd[i] == 0` skip, the dedup guard, and the
`accusedWeight` sum are untouched.

## Decisions

1. **Struct field placement.** Append is not required for layout safety
   (non-upgradeable contract, mapping-held struct), but place `ledger`
   adjacent to `game` in `ITokenCourt.Case` for readability — both are
   "pinned counterparty" fields. Comment mirrors `game`'s:
   `// pinned IExposureLedger the accused set was derived from, written once in refer`.
2. **Type: `address`, not `IExposureLedger`.** Matches `game` being `address`
   in the struct; interfaces are applied at the call site.
3. **No event change.** `AccusedSetRecorded(caseId, count, weight)` already
   fixes the observable outcome; the pinned ledger is readable via the case
   getter. Adding a field to an event is an ABI break for indexers with no
   security payoff.
4. **No behavioural guard added in `ChallengeGame`.** The file→refer residual
   window is a separate decision (at-`file` pin = `Challenge` struct change on
   a much hotter contract, or a live-challenge guard on `setExposureLedger`
   whose natspec currently rejects that dependency direction). Documented in
   natspec + on the PR; not silently expanded scope.
5. **Getter surface.** `_cases` is exposed via the existing case view
   (`caseOf` / public struct getter — match whatever the interface exposes
   today). The new field rides along; update `ITokenCourt` natspec.

## Testing

Repo convention is failing-first regressions (see PR #61's suites):

- `test_ledgerPinnedAtRefer` — after `refer`, `Case.ledger` equals the game's
  ledger at referral instant.
- `test_repointAfterReferDoesNotDisturbCase` — re-point the game to a fresh
  mock ledger returning an empty approver set; assert `Case.ledger`,
  `isAccused[...]`, `accusedWeight`, and the finalize-path floor are unchanged.
- `test_ledgerAndWeightPinnedTogether` — recompute the expected weight from the
  pinned ledger's approvers at `snapshotTs`; assert equality (guards the
  issue's "half the property" hazard).
- Existing TokenCourt / ChallengeGame end-to-end suites must pass unmodified.

## Risks

- Trivial bytecode growth (one SSTORE + slot); TokenCourt is far from any size
  limit.
- Mock ledger must implement `approversOf` and `challengeWindow` (the
  `setExposureLedger` bound reads it) — reuse existing mocks if present.
