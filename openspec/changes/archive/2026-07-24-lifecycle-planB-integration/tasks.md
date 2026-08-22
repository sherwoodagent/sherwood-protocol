# Tasks — Lifecycle × Plan B integration

## 1. Pre-merge decisions

- [x] 1.1 Lifecycle session answers the C2/C3 question: upgrade-in-place vs fresh redeploy for `GuardianRegistry` (if in-place, `vaultOf` moves to the end of storage and the gap absorbs it)
- [x] 1.2 Agree the merged registry layout: `vaultOf` + `exposureLedger` appended after the last pre-existing field, gap 50 → 48, no pre-existing field moved
- [x] 1.3 Confirm fold intent for `_tierRegistry` and the fold timeline; Plan B pauses Tasks 9–11 until the fold lands

## 2. Land lifecycle first, rebase Plan B

- [x] 2.1 Land `refactor/proposal-lifecycle` including its `SyndicateGovernor` storage fold, with `_exposureLedger`/`_bondEscrow` accounted for after `_tierRegistry` and `proposerBondWood` kept last in `StrategyProposal`
- [x] 2.2 Re-insert Plan B's two vote hooks in `voteOnProposal` at the `_votes[...] = support;` anchor, keeping the lifecycle's `r.voteEnd`/`r.reviewEnd` window reads and the CEI comment (C1)
- [x] 2.3 Move `exposureLedger` to the merged registry layout (C2)
- [x] 2.4 Verify `SyndicateGovernor.getProposalView` still exists for `ExposureLedger` (C5); note the `vaultOf[governor]` harmonization as a follow-up
- [x] 2.5 Union `IGuardianRegistry` additions and both test mocks (C6/C7)

## 3. Verification

- [x] 3.1 Re-run the 5 Plan B suites (ExposureLedger, ProposerBondEscrow, TierRegistry, RegistryExposureHook, GovernorCoverageGates — 89 tests), fixing fixtures if `registerReview` changed how proposals enter review
- [x] 3.2 Regenerate storage-layout goldens once, post-fold; verify the diff is append-only for every pre-existing slot
- [x] 3.3 `forge test` — no new failures beyond the known pre-existing `SetGuardianRegistry.t.sol` one (C7)
- [x] 3.4 `forge fmt --check` clean with the CI-pinned forge version
