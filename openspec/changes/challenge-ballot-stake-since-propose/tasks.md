# Tasks

## 1. Game

- [x] 1.1 `Challenge.snapshotAt` (uint64, appended), pinned in `file()` from the governor's `snapshotTimestamp`.
- [x] 1.2 `voteOnChallenge`: weight = min(stake at `filedAt - 1`, stake at `snapshotAt`).

## 2. Tests

- [x] 2.1 `test/audit-fixes/ChallengeGame_ballotStakeSincePropose.t.sol`: the review-end bloc that self-executes
      and files a second later, the E-1 PoCs inverted (fresh bloc, sybils, silent-electorate bloc), the top-up and
      reduced-stake edges, and the PoC controls. Mutation: restoring the `executedAt - 1` clamp fails the review-end test.
- [x] 2.2 `test/ChallengeDecidedSettlement.t.sol`: the whale stakes before propose; asserted outcomes unchanged.

## 3. Docs

- [x] 3.1 `docs/guardian-network.md` ballot weight and the "what bounds a sybil" sentence; the paper's §5.5 sentence.
