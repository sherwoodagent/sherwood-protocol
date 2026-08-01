# Proposal Lifecycle Deepening

> Migrated from docs/superpowers/plans/2026-07-24-proposal-lifecycle-deepening.md (superpowers workflow) on 2026-08-01.

## Why

The proposal state machine was smeared across modules: the governor kept twin resolvers (`_resolveState` mutating / `_resolveStateView` view) that could drift, the registry called back into the governor through `IGovernorMinimal.getProposalView` (so a compromised governor could misdirect `slashOwnerBond`), and three duplicate proposal-struct projections existed. The view path also lagged reality — it reported `GuardianReview` after `reviewEnd` until a mutating tx poked `resolveReview`, forcing every consumer to know about the lazy resolver.

## What Changes

- New abstract base `src/ProposalLifecycle.sol` owning proposal-state storage and the full arc propose → vote → guardian review → execute → settle. `stateOf(pid)` is a true view (reports Approved/Rejected/Expired immediately once determinable after `reviewEnd`); `_transition`/`_commitState` are the ONLY writers of `proposal.state` (greppable single-writer invariant: `grep -rn "\.state =" src/` hits only this file).
- Registry call-back inverted to a push: the governor registers the review window at propose time via `registerReview(proposalId, voteEnd, reviewEnd)`; `IGovernorMinimal`, `getProposalView`, and `ProposalViewLite` deleted. `addGovernor` becomes `addGovernor(gov, vault)` so vault identity comes from factory wiring (`vaultOf`), not a governor call-back.
- Registry gains `outcomeOf(governor, proposalId)` — a deterministic view of the review verdict (`Unresolved`/`Cleared`/`Blocked`) sharing one internal `_isBlocked` predicate with `resolveReview` (the economic commit), so view and commit can never drift (fuzz-proved agreement).
- Vault reads scalar `strategyOf(pid)` instead of the full `StrategyProposal` struct; the shape-drift try/catch in `_activeStrategy` is dropped; `IProposalStatus` narrows.
- `GovernorParameters` and `GovernorEmergency` extend `ProposalLifecycle`; the `_getProposal`/`_getRegistry` virtual accessors and the duplicated `whenNoActiveProposal` modifier die.
- One intentional behavioral delta: `stateOf` resolves immediately after `reviewEnd` instead of holding at `GuardianReview` until poked. Tests asserting the lazy behavior were updated individually, never bulk-fixed.

## Capabilities

- syndicate-governor
- syndicate-vault
- guardian-staking

## Impact

- Created: `src/ProposalLifecycle.sol`, `test/GuardianRegistryRegisterReview.t.sol`, `test/GuardianRegistryOutcome.t.sol`, `test/governor/ProposalLifecycle.t.sol`
- Modified: `src/GuardianRegistry.sol`, `src/SyndicateGovernor.sol`, `src/GovernorParameters.sol`, `src/GovernorEmergency.sol`, `src/SyndicateFactory.sol`, `src/SyndicateVault.sol`, `src/interfaces/IGuardianRegistry.sol`, `src/interfaces/IProposalStatus.sol`, `test/mocks/MockGovernorMinimal.sol`, existing suites (mechanical ABI adaptation + individually reviewed lazy-view deltas)
- Frame: fresh-deploy (Robinhood stack) — storage layouts, ABIs, and struct shapes were free to change; the legacy Base (8453) deployment was untouched. Emergency-review registry seam kept its shape (scope fence); emergency paths only rerouted state writes.
