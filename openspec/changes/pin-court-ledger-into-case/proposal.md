# Pin the exposure ledger into `Case` at `refer`

## Why

Closes issue #69 (deferred from PR #61 review, severity Low).

`TokenCourt._recordAccused` resolves the exposure ledger **live** from the game
at `refer` time (`IChallengeGameLedger(game).exposureLedger()`), and the case
record never stores which ledger produced its accused set. Every other input a
case depends on is pinned into `Case` at `refer` — `game`, `snapshotTs`,
`voteWindowAtReferral`, `accusedWeight` — under the "compute once, store"
discipline (D2/F5/F17). The ledger is the one input that escapes it.

Consequences of the gap:

- `ChallengeGame.setExposureLedger` has **no live-challenge guard** (its own
  natspec calls the re-point a "documented gap"). If the owner re-points the
  ledger between `file` and `refer`, `approversOf(governor, proposalId)` on the
  new ledger returns empty: `isAccused` is empty (every real approver may vote
  on its own case) and `accusedWeight == 0` pushes the participation floor to
  its maximum, compounding the B2 denial-of-quorum behaviour.
- Any **future reader** (a floor recompute, an off-chain indexer, a follow-up
  feature) that resolves the ledger live can silently diverge from the set the
  case was actually built from.

This was deliberately not fixed in PR #61 because it changes the `Case` struct,
and a PR carrying 4 blocking + 3 high findings was the wrong place for a
storage-shape change. `TokenCourt` is non-upgradeable and the protocol is
pre-fresh-deployment, so the struct change has no live-storage migration cost.

## What changes

- `ITokenCourt.Case` gains a `ledger` field, written once in `refer` from the
  single `IChallengeGameLedger(game).exposureLedger()` read.
- `_recordAccused` receives that resolved ledger as a parameter instead of
  reading it from the game itself — one read, one writer, all readers downstream
  of the pin (same shape as `snapshotTs`).
- `accusedWeight` stays pinned as today; a regression test asserts ledger and
  weight are pinned **together** (the issue's "check when doing it": pinning the
  ledger without the derived weight would leave half the property).
- Natspec documents the **residual window**: an owner re-point strictly between
  `file` and `refer` still yields an empty accused set, because the pin happens
  at `refer`. Closing that requires pinning at `file` inside `ChallengeGame`
  (a `Challenge` struct change) or a live-challenge guard on
  `setExposureLedger` — both out of scope here and flagged on the PR as a
  follow-up decision.

## Impact

- Contracts: `src/TokenCourt.sol`, `src/interfaces/ITokenCourt.sol` (struct +
  natspec only; no behavioural change on the happy path).
- Tests: `test/` TokenCourt suites — new regressions for pin-survives-re-point
  and empty-set parity; existing suites must stay green.
- No overlap with protected PR #68 (fee model): disjoint files.
- Storage: `Case` struct grows by one address slot. Non-upgradeable contract,
  fresh deployment planned — no migration.
