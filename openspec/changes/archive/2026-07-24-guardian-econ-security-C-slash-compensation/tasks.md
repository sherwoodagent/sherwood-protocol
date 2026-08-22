# Tasks — Guardian Economic Security Plan C

## 1. CompensationEscrow — case funding

- [x] 1.1 Write failing tests: openCase pulls proceeds and records, funder-only, future snapshot rejected, zero proceeds rejected, empty-snapshot supply rejected
- [x] 1.2 Write `ICompensationEscrow` (errors, events, openCase/redeem/sweepResidue, views, owner setters)
- [x] 1.3 Implement case funding: Ownable2Step, immutable WOOD, authorized funder + backstop + residue window config, `openCase` with cached snapshot supply and `totalEscrowed` accounting, reverting stubs for claims/sweep
- [x] 1.4 Run `CompensationEscrowTest` green; commit

## 2. Pro-rata claims and redemption

- [x] 2.1 Write failing tests: claimable is pro-rata at snapshot (70/30), redeem pays and marks consumed, double-redeem reverts, non-holder reverts, post-drain accumulator gets nothing (the F1 property), no claim-transfer surface, balance-covers-outstanding fuzz invariant
- [x] 2.2 Implement `claimable` (pro-rata against snapshot, rounds down, zero after redeem/sweep) and pull-based `redeem` (per-holder flag set before transfer — no re-entrant double payout)
- [x] 2.3 Run suite green including fuzz; commit

## 3. Residue sweep to the backstop

- [x] 3.1 Write failing tests: sweep before window reverts, sweep after window pays backstop, permissionless and once-only, redeem after sweep reverts
- [x] 3.2 Implement `sweepResidue`: window check, once-only, residue to the owner-set backstop (never live NAV)
- [x] 3.3 Run suite green; commit

## 4. StakedWood — authorized-slasher entrypoint

- [x] 4.1 Write failing tests on the canonical StakedWood fixture: setter owner-only, entrypoint slasher-only, proceeds route to escrow not burn and fund a case, review path still burns through `onlyRegistry`, zero-total verdict opens no case
- [x] 4.2 Append `authorizedSlasher` storage before `__gap` (9 → 8), add `onlyAuthorizedSlasher` modifier + `setAuthorizedSlasher`
- [x] 4.3 Implement `slashToEscrow`: same per-approver legs as the review path (`_slashOne`), total-stake checkpoint push, proceeds approved to the escrow and booked via `openCase` pinned to the caller-chosen snapshot
- [x] 4.4 Run new + all pre-existing StakedWood suites green; commit

## 5. End-to-end — real slash, real vault, victim redeems

- [x] 5.1 Build a real fixture (real StakedWood proxy, GuardianRegistry, SyndicateVault, LP deposits; escrow with sWOOD as funder; test contract as slasher) — exercises the D1 auto-delegation assumption for real
- [x] 5.2 `test_verdictSlash_compensatesPreDrainHolders`: 70/30 checkpoint split proven, escrow holds exactly the slashed WOOD, both LPs redeem in full
- [x] 5.3 `test_verdictSlash_postDrainBuyerGetsNothing`: real post-snapshot deposit gets zero claim, pre-drain entitlements unchanged (F1 against the real vault)
- [x] 5.4 `test_verdictSlash_doesNotTouchLiveNav`: `totalAssets()` unchanged across slash and redemptions
- [x] 5.5 Run `CompensationEndToEnd` green; commit

## 6. Goldens, full suite, docs, PR

- [x] 6.1 Add StakedWood to `script/check-layout-goldens.sh`, regenerate goldens, inspect the diff — only `authorizedSlasher` and the shrunken gap may appear; no pre-existing slot moved
- [x] 6.2 Full `forge test` — no new failures beyond the documented pre-existing baseline (fork tests without `--fork-url`, SetGuardianRegistry mock)
- [x] 6.3 `forge fmt && forge fmt --check`
- [x] 6.4 Update the master spec status header: v1b part 1 complete; challenge game and approver premium outstanding; verdict is governance-driven until Plan D
- [x] 6.5 Push and open PR stating what landed, the F1 property, decisions D1–D5, and explicit exclusions (Plan D/E, v1c)
- [x] 6.6 Post-review hardening (2026-07-25, `e7fcc24`): per-case fund isolation cap, slashBps clamping, owner-set `compensationEscrow`, per-case frozen residue window, `SnapshotAfterVerdict` guard, richer returns/events — see design.md amendments
