# Tasks

## 1. Vault

- [x] 1.1 `depositsLocked()` stays an alias of `redemptionsLocked()`
      (`openProposalCount()`, Drafts included), as on v1-deploy (#362 option b).
- [x] 1.2 `requestDeposit` keeps v1-deploy's gate and error (`NoOpenProposal`), so
      exactly one deposit path is open in every state.
- [x] 1.3 Rescue paths unchanged: `redemptionsLocked()`, Drafts included.
- [x] 1.4 Dead `IRequestableVault.getPastVotes` declaration removed.
- [x] 1.5 `_delegate` refuses any delegatee but the account (`DelegationDisabled`, SHE-293);
      `delegate`, `delegateBySig` and the auto-delegate all route through it.

## 2. Governor

- [x] 2.1 Both paths stamp `votableSupply` at `snapshotTimestamp`
      (`_votableSupplyAt`: `getPastTotalSupply − getPastVotes(queue)`), and `vote`
      lowers it to the same read at `snapshot + 1` (a845b781).
- [x] 2.2 No storage change.

## 3. Tests

- [x] 3.1 Draft: both locks held; a Draft-window deposit reverts `DepositsLocked`
      (Sherlock #8). Mutation — `depositsLocked()` reads `getActiveProposal()`.
- [x] 3.2 A redeem ahead of `propose` cannot re-deposit after it in the same second.
      Mutation — as 3.1.
- [x] 3.3 Same-block `requestRedeem` ahead of the final approve: the recorded
      electorate includes the queued shares, 30% Against of 100% misses the 40% bar.
      Mutation — read the collaborative electorate live.
- [x] 3.4 Parked queue shares are outside the collaborative electorate. Mutation —
      drop the queue term from `_votableSupplyAt`.
- [x] 3.7 Every Draft exit (cancel, emergencyCancel, rejectCollaboration, expiry)
      lifts the redeem lock.
- [x] 3.8 `Vault_redemptionLockSemantics`, `Vault_settleStampDenominator`,
      `Vault_depositLifecycleAndHwm` and `OpenProposalCount.test_draft_locksDeposits`
      are v1-deploy's.
- [x] 3.9 `delegate(other)`, `delegate(0)`, `delegateBySig(other)` revert
      `DelegationDisabled`; `delegate(self)` succeeds. Mutation — drop the override.

## 4. Docs

- [x] 4.1 `docs/proposal-lifecycle.md` lock table and the two electorate reads.
- [x] 4.2 `veto-votable-supply` design.md Decision 3 → resolved, pointing here.
- [x] 4.3 `docs/deposit-withdraw-flow.md` on the one predicate.
