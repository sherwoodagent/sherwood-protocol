# Proposal: Challenge ballots count only stake held since the propose snapshot

## Why

Audit 2026-10-01 (post-audit-v2) E-1: `voteOnChallenge` weighed a ballot by raw
stake at `filedAt - 1`. A fresh address that stakes one second before a filing,
with no exposure anywhere, could convict honest approvers of a benign proposal in
the filing second (convict above half of `votableAtFiling`) and exit after one
cooldown. With a silent electorate, a bloc of only the quorum share convicts at
the window's close. The PR #326 review accepted raw-stake ballots; the owner has
now decided to clamp the ballot.

A first cut clamped at `executedAt - 1`. Review showed that only moves the
commitment point by seconds: a bloc can stake at the end of guardian review, call
the permissionless `executeProposal` one second later and file one second after
that, still at full weight. The clamp therefore sits at the propose-time snapshot,
so an attacker must already be staked before the proposal is public.

## What Changes

- `IChallengeGame.Challenge` gains `uint64 snapshotAt`, appended, pinned in
  `file()` from the governor's `StrategyProposal.snapshotTimestamp` that `file()`
  already reads for the accused-stake cap. The accused cap and the ballot clamp
  therefore read one instant. `ChallengeGame` is not a proxy and is redeployed at
  the v1 to v2 migration, so no live storage layout moves.
- A ballot's weight becomes
  `min(getPastStake(voter, filedAt - 1), getPastStake(voter, snapshotAt))`;
  a zero result reverts `NoVotableStake`.
- The electorate is NOT changed: `totalStakeAtFiling`, `votableAtFiling`, the
  quorum and the early-settle bar keep reading `filedAt - 1`.

## Impact

- Relative to the unclamped rule, conviction and acquittal weight can only
  shrink, so the quorum and the early-settle bar get harder to reach, never easier.
- Trade-off: an honest guardian who staked after the proposal was proposed cannot
  vote on its challenge. This is the electorate rule the guardian review itself
  uses (`GuardianRegistry` weighs review ballots at its propose-time `snapshotAt`).
- Not fixed: post-snapshot stake still enlarges both denominators. That can only
  make a conviction harder (the C2 direction the PR #326 review accepted), and it
  means a filing that passes the `NoVotableStake` door is not guaranteed reachable.
- Disclosed side effect: a defender whose only stake arrived after the snapshot
  casts zero acquit weight, which moves the window-close `convictWeight >
  acquitWeight` comparison toward conviction. The quorum still binds on
  pre-snapshot convict stake, so no fresh bloc can use this.
