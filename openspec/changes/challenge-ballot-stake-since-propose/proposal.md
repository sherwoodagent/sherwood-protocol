# Proposal: Challenge ballots count only stake held since execution

## Why

Audit 2026-10-01 (post-audit-v2) E-1: `voteOnChallenge` weighed a ballot by raw
stake at `filedAt - 1`. A fresh address that stakes one second before a filing,
with no exposure anywhere, could convict honest approvers of a benign proposal in
the filing second (convict above half of `votableAtFiling`) and exit after one
cooldown. With a silent electorate, a bloc of only the quorum share convicts at
the window's close. The PR #326 review accepted raw-stake ballots; the owner has
now decided to clamp the ballot.

## What Changes

- A ballot's weight becomes
  `min(getPastStake(voter, filedAt - 1), getPastStake(voter, executedAt - 1))`,
  reading the `executedAt` the challenge already pins at filing. Stake added after
  the proposal executed carries no vote; a zero result reverts `NoVotableStake`.
- The electorate is NOT changed: `totalStakeAtFiling`, `votableAtFiling`, the
  quorum, the early-settle bar and `file()` are untouched.

## Impact

- Conviction and acquittal weight can only shrink, so the quorum and the
  early-settle bar get harder to reach, never easier.
- Not fixed: fresh stake still enlarges both denominators. That can only make a
  conviction harder (the C2 direction the PR #326 review accepted).
- Disclosed side effect: a defender whose only stake arrived between execution
  and filing now casts zero acquit weight, which moves the window-close
  `convictWeight > acquitWeight` comparison toward conviction. The quorum still
  binds on pre-execution convict stake, so no fresh bloc can use this.
