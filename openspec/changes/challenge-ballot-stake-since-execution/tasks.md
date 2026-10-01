# Tasks

## 1. Game

- [x] 1.1 `voteOnChallenge`: weight = min(stake at `filedAt - 1`, stake at the pinned `executedAt - 1`).

## 2. Tests

- [x] 2.1 `test/audit-fixes/ChallengeGame_ballotStakeSinceExecution.t.sol`: the E-1 PoCs inverted
      (fresh bloc, sybils, silent-electorate bloc all revert `NoVotableStake` and the false challenge
      fails), the top-up and reduced-stake edges, and the PoC controls.
- [x] 2.2 `test/ChallengeDecidedSettlement.t.sol`: the whale stakes before execution; asserted outcomes unchanged.

## 3. Docs

- [x] 3.1 `docs/guardian-network.md` ballot weight and the "what bounds a sybil" sentence.
