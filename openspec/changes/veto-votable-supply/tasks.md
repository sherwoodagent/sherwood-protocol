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
- [x] 2.2 Queued shares are outside the electorate. Deliberately does NOT
      distinguish the live read from a snapshot read — unreachable on the direct
      path; see design.md Decision 1.
- [x] 2.3 The collaborative stamp site is pinned: a collab proposal driven to
      Pending via `approveCollaboration`, then vetoed. Mutation — delete the
      `votableSupply` line at the collab site and it fails.
- [x] 2.4 The eight existing F2 tests in
      `test/audit-fixes/Governor_vetoDenominatorExits.t.sol` stay green
      unchanged, including the two claimed-in-the-propose-block shapes and
      `test_queuedRedeemAfterTheSnapshotDoesNotShrinkTheVetoBar`.
- [ ] 2.5 Lifecycle/invariant harness pass with a proposal whose queue holds a
      parked balance across resolve.

## 3. Docs

- [x] 3.1 `docs/proposal-lifecycle.md` and
      `docs/papers/guardian-network-economic-security.md` said "past total
      supply"; both now describe the recorded votable set.
- [x] 3.2 Announce the ABI change: `getProposal` returns the struct, so its
      tuple gains a trailing `uint256` for the SDK, app and guardian daemon.

## 4. Open decisions (NOT closed by this change)

- [ ] 4.1 The phantom-weight trade, design.md Decision 2: keep the `− 1`
      snapshot for vote weight, or move both reads to the propose instant and
      re-open the flash-delegate window.
- [ ] 4.2 The collaborative-path window, design.md Decision 3: stamp at Draft
      creation (a), or accept the bounded easier-veto and pin it (b). Related to
      4.1 — both come from the weight instant and the electorate instant
      differing, and are best settled together.
