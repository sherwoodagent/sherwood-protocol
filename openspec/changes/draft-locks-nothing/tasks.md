# Tasks

## 1. Governor

- [x] 1.1 `ProposalLifecycle._draftCount`, carved from `__lifecycleGap` (10 → 9).
- [x] 1.2 `lockedProposalCount() = _openProposalCount - _draftCount`, exposed on
      `IProposalStatus` and `ISyndicateGovernor`.
- [x] 1.3 Increment on Draft creation; decrement on every Draft exit — the
      Draft → Pending transition, `cancelProposal`'s Draft branch,
      `emergencyCancel` (Draft only), `rejectCollaboration`, and the lazy
      Draft → Expired commit in `_computeState`/`_commitState`.
- [x] 1.4 Golden regenerated (one slot carved from the gap, nothing renumbered).

## 2. Vault

- [x] 2.1 `redemptionsLocked()` reads `lockedProposalCount()`.
- [x] 2.2 `depositsLocked()` reads `getActiveProposal()`; no longer an alias.
- [x] 2.3 `requestDeposit` gates on `depositsLocked()` so exactly one deposit path
      is open in every state.
- [x] 2.4 Rescue paths (`rescueEth`/`rescueERC20`/`rescueERC721`) keep reading the
      full open count via `_proposalOpen()` — a Draft binds the vault.

## 3. Tests

- [x] 3.1 Draft: instant redeem open, and the holder who leaves is outside the
      electorate stamped at Draft → Pending. Mutation — make a Draft lock redeem.
- [x] 3.2 Draft: `requestRedeem` reverts `RedemptionsNotLocked`, which is what makes
      `veto-votable-supply` Decision 3 unreachable; the queue opens at Pending.
- [x] 3.3 Pending: instant deposit open, and the deposit buys no vote weight
      (`getVoteWeight == 0`, `vote` reverts `NoVotingPower`, the recorded electorate
      is unmoved). Mutation — lock deposits at Pending.
- [x] 3.4 Executed: instant deposit closed, the lane opens tagged to the active pid,
      settle reopens both.
- [x] 3.5 Re-pointed the suites that pinned the old boundaries:
      `Vault_redemptionLockSemantics` (deposits open pre-execute),
      `Vault_settleStampDenominator` (finding #13's dead window, now closed from the
      other side), `Vault_depositLifecycleAndHwm` (the lane opens at execute),
      `OpenProposalCount.test_draft_locksNoLpFlow`.
- [x] 3.6 Every governor fake gained `lockedProposalCount()`.
- [ ] 3.7 Invariant/lifecycle harness pass with a Draft open across a redeem.
- [x] 3.8 Every Draft exit pinned on `lockedProposalCount() == 0` plus a live
      `redemptionsLocked()` read (cancel, emergencyCancel, rejectCollaboration,
      expiry); the Sherlock #8 trade exercised through the stamp.
- [x] 3.9 Collaborative same-block `{redeem, approveCollaboration}`: the recorded
      electorate includes the exit, 30% Against of 100% misses the 40% bar.
      Mutation — read the collaborative electorate live.

## 1b. Governor (review of #320)

- [x] 1.5 `approveCollaboration` stamps `votableSupply` at `snapshotTimestamp`
      (`getPastTotalSupply − getPastVotes(queue)`); `propose` keeps the live read.
- [x] 1.6 `requestDeposit` reverts `DepositsNotLocked` (was `NoOpenProposal`) and
      resolves the governor once; dead `IRequestableVault.getPastVotes` removed.

## 4. Docs

- [x] 4.1 `docs/proposal-lifecycle.md` lock table.
- [x] 4.2 `veto-votable-supply` design.md Decision 3 → resolved, pointing here.
- [x] 4.3 `docs/deposit-withdraw-flow.md` on the two predicates.
