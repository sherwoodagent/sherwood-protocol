# Tasks

## 1. Governor

- [x] 1.1 `StrategyProposal.votableSupply`, appended after `effectiveMaxCapital`.
- [x] 1.2 `_votableSupplyOf(vault)` = `totalSupply() − balanceOf(withdrawalQueue())`,
      both live; zero-queue vault returns the full supply.
- [x] 1.3 Stamp it at BOTH Draft → Pending sites: `_initPendingProposal` (direct
      propose) and the co-proposer approval path.
- [x] 1.4 `_computeState` reads `p.votableSupply`; the snapshot reconstruction and
      the `min` are deleted, along with the now-dead `IVotes`/`IERC20`/
      `ISyndicateVault` imports in `ProposalLifecycle`.
- [x] 1.5 Regenerate `script/syndicate-governor-layout.golden.json` (append-only:
      one entry, struct slot 26, nothing reordered or retyped).

## 2. Tests

- [x] 2.1 The repro: 100k parked in the queue plus a 200k same-block pre-propose
      redeem; 45% of the real electorate Against must reject. Mutation-verified —
      restoring the `min` flips it to Approved.
- [x] 2.2 The queue term is read live at propose, not at the snapshot.
- [x] 2.3 The eight existing F2 tests in
      `test/audit-fixes/Governor_vetoDenominatorExits.t.sol` stay green
      unchanged, including the two claimed-in-the-propose-block shapes and
      `test_queuedRedeemAfterTheSnapshotDoesNotShrinkTheVetoBar`.
- [ ] 2.4 Lifecycle/invariant harness pass with a proposal whose queue holds a
      parked balance across resolve.

## 3. Residual

- [ ] 3.1 Decide the phantom-weight trade in `design.md` Decision 2 (keep the
      `− 1` snapshot for vote weight, or move both reads to the propose instant
      and re-open the flash-delegate window). Not closed by this change.
