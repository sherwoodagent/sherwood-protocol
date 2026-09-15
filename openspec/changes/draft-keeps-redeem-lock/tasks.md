# Tasks

## 1. Vault

- [x] 1.1 `depositsLocked()` reads `getActiveProposal()`; no longer an alias of
      `redemptionsLocked()`, which keeps reading `openProposalCount()`.
- [x] 1.2 `requestDeposit` gates on the active pid (`DepositsNotLocked` otherwise) so
      exactly one deposit path is open in every state; resolves the governor once.
- [x] 1.3 Rescue paths unchanged: `redemptionsLocked()`, Drafts included.
- [x] 1.4 Dead `IRequestableVault.getPastVotes` declaration removed.

## 2. Governor

- [x] 2.1 `approveCollaboration` stamps `votableSupply` at `snapshotTimestamp`
      (`_votableSupplyAt`: `getPastTotalSupply − getPastVotes(queue)`); `propose`
      keeps the live `_votableSupplyOf`.
- [x] 2.2 No storage change.

## 3. Tests

- [x] 3.1 Draft: redeem lock held, deposit open; the Draft-window deposit votes and is
      locked until settle (Sherlock #8, accepted). Mutation — a Draft does not bind.
- [x] 3.2 Draft deposit `X` cannot exit in the final-approve block; the bar counts
      only locked capital.
- [x] 3.3 Same-block `requestRedeem` ahead of the final approve: the recorded
      electorate includes the queued shares, 30% Against of 100% misses the 40% bar.
      Mutation — read the collaborative electorate live.
- [x] 3.4 Parked queue shares are outside the collaborative electorate. Mutation —
      drop the queue term from `_votableSupplyAt`.
- [x] 3.5 Pending: instant deposit open, buys no vote weight. Mutation — lock
      deposits at Pending.
- [x] 3.6 Executed: instant deposit closed, the lane opens tagged to the active pid,
      settle reopens both.
- [x] 3.7 Every Draft exit (cancel, emergencyCancel, rejectCollaboration, expiry)
      lifts the redeem lock.
- [x] 3.8 Re-pointed the suites that pinned the old deposit boundary:
      `Vault_redemptionLockSemantics`, `Vault_settleStampDenominator`,
      `Vault_depositLifecycleAndHwm`, `OpenProposalCount`.

## 4. Docs

- [x] 4.1 `docs/proposal-lifecycle.md` lock table and the two electorate reads.
- [x] 4.2 `veto-votable-supply` design.md Decision 3 → resolved, pointing here.
- [x] 4.3 `docs/deposit-withdraw-flow.md` on the two predicates.
