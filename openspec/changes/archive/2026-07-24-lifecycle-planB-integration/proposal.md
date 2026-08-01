# Integration: `refactor/proposal-lifecycle` × `feat/guardian-econ-security-b`

> Migrated from docs/superpowers/plans/2026-07-24-lifecycle-planB-integration.md (superpowers workflow) on 2026-08-01.

## Why

Two sessions were editing the same contracts for different reasons: `refactor/proposal-lifecycle` (structural — one authoritative proposal state, single-writer transitions, registry stops calling back into the governor) and `feat/guardian-econ-security-b` (feature — guardian economic security v1a, see `openspec/changes/archive/2026-07-24-guardian-econ-security-B-coverage-quorum/`). Neither branch was redundant, but three of the overlaps were storage-layout edits to upgradeable contracts (`GuardianRegistry` UUPS proxy, the pending `SyndicateGovernor` storage fold into `ProposalLifecycle`), which do not survive a naive merge. This change recorded every collision, proposed one merged layout, and pinned a sequencing before either branch merged.

## What Changes

- Collision inventory C1–C8 across `GuardianRegistry.voteOnProposal`, `GuardianRegistry` storage, the `Review` struct repack, the `SyndicateGovernor` storage fold, the `getProposalView` dependency, `IGuardianRegistry`, shared test mocks, and `SyndicateFactory` (see design.md).
- One agreed merged `GuardianRegistry` layout: both new slots (`vaultOf`, `exposureLedger`) appended after the last pre-existing field, `__gap` 50 → 48, no pre-existing field moved, total slot count conserved — safe under both upgrade-in-place and fresh-redeploy assumptions.
- Agreed sequencing: land `refactor/proposal-lifecycle` first (including its governor storage fold), then rebase Plan B onto it — refactors go under features; the riskiest merge point (the fold) gets planned once instead of repaired twice; goldens regenerate once.
- Bounded re-apply list for Plan B post-rebase: re-insert the two vote hooks at the `_votes[...] = support;` anchor keeping the lifecycle's window reads, merged registry slot placement, fold slot accounting (`_exposureLedger`/`_bondEscrow` stay in `SyndicateGovernor` after `_tierRegistry`; `proposerBondWood` stays last in `StrategyProposal`), interface/mock unions, suite re-runs, single golden regeneration.
- Hard dependency pinned: `SyndicateGovernor.getProposalView` must not be deleted — `ExposureLedger.recordApproval` reads the proposal's vault and coverage through it. Recommended post-merge harmonization: switch the ledger to the registry's `vaultOf[governor]` mapping instead.

The integration landed via the `integration/lifecycle-planb` branch (PR #56).

## Capabilities

- syndicate-governor
- guardian-staking
- guardian-coverage

## Impact

- Coordination change — no new contracts of its own. Governs how these files merged: `src/GuardianRegistry.sol`, `src/SyndicateGovernor.sol`, `src/ProposalLifecycle.sol`, `src/ExposureLedger.sol`, `src/SyndicateFactory.sol`, `src/interfaces/IGuardianRegistry.sol`, `test/mocks/MockRegistryMinimal.sol`, `test/mocks/MockGovernorMinimal.sol`, storage-layout goldens
