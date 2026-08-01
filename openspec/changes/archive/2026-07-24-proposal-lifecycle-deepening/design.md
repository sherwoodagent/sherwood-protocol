# Design — Proposal Lifecycle Deepening

> Distilled from the plan's architecture notes (no separate design doc existed for this change).

## Context

Collapse the proposal state machine into one owning module (`ProposalLifecycle`) with a true-view `stateOf(pid)` seam, kill the registry call-back and all three duplicate proposal-struct projections. Vocabulary: proposal lifecycle, proposal state, review outcome, economic commit, review registration.

Frame: fresh-deploy (Robinhood stack). Storage layouts, ABIs, and struct shapes are free to change. Base (8453) legacy deployment untouched. Emergency-review registry seam keeps its current shape (scope fence); emergency paths only reroute state writes.

## Goals / Non-Goals

- Goal: one authoritative state per proposal, read via `stateOf` (never lags behind determinable reality) and written ONLY by `_transition`/`_commitState`.
- Goal: registry never calls back into the governor — the governor pushes review-window facts at propose time (`registerReview`); `IGovernorMinimal`/`getProposalView`/`ProposalViewLite` deleted.
- Goal: the review verdict is a deterministic registry view (`outcomeOf`) sharing one internal predicate (`_isBlocked`) with `resolveReview`, the economic commit.
- Goal: the vault reads `strategyOf(pid)` (scalar) instead of the full `StrategyProposal`.
- Non-goal: changing the emergency-review registry seam's shape.
- Non-goal: touching the legacy Base (8453) deployment — the storage-layout shift is safe ONLY under the fresh-deploy frame; do not cherry-pick onto the Base beacon.

## Decisions

### Behavioral delta (the one intentional spec change)

Before: the view path reported `GuardianReview` after `reviewEnd` until a mutating tx poked `resolveReview`. After: `stateOf` reports `Approved`/`Rejected`/`Expired` immediately once determinable. Tests asserting the lazy behavior were updated individually — each such diff is the spec change, reviewed one by one, never bulk-fixed.

### Invariant preserved exactly

`resolveReview` (economic commit / slash) is fired from mutating governor paths ONLY when the proposal actually passed the vote and traversed guardian review — a veto-rejected proposal never triggers it (matches the pre-refactor `_resolveState`, which only called `resolveReview` when the view resolved to `GuardianReview`). `_computeState` returns a `reviewConcluded` flag that is false for veto-rejections at `voteEnd`; `_commitState` fires the registry's economic commit only when it is true.

### Module responsibilities after the refactor

| File | Action | Responsibility after |
|---|---|---|
| `src/ProposalLifecycle.sol` | Create | Abstract base: proposal-state storage, `stateOf`, `_computeState`, `_commitState`, `_transition`, `_decOpen`, `openProposalCount`, `whenNoActiveProposal` |
| `src/GuardianRegistry.sol` | Modify | + `vaultOf`, `registerReview`, `outcomeOf`, `_isBlocked`; − `IGovernorMinimal`, all `getProposalView` call-backs |
| `src/SyndicateGovernor.sol` | Modify | Propose/vote/execute/settle only; − twin resolvers, `getProposalView`, `ProposalViewLite`; + `registerReview` pushes, `strategyOf` |
| `src/GovernorParameters.sol` | Modify | Extends `ProposalLifecycle`; − abstract `openProposalCount`, − `whenNoActiveProposal` (moved to base) |
| `src/GovernorEmergency.sol` | Modify | Extends `ProposalLifecycle`; − `_getProposal`/`_getRegistry` virtual accessors; state writes via base |
| `src/SyndicateFactory.sol` | Modify | `addGovernor(gov, vault)` |
| `src/interfaces/IGuardianRegistry.sol` | Modify | + `registerReview`, `outcomeOf`, `ReviewOutcome`; `addGovernor(address,address)` |
| `src/interfaces/IProposalStatus.sol` | Modify | `getProposal` → `strategyOf` |
| `src/SyndicateVault.sol` | Modify | `_activeStrategy` uses `strategyOf`; try/catch + `ISyndicateGovernor` struct import dropped |

### Key mechanism decisions

- **`vaultOf` factory wiring replaces the `getProposalView().vault` call-back.** Vault identity comes from factory wiring at `addGovernor(gov, vault)`, so a compromised governor cannot misdirect `slashOwnerBond`.
- **`registerReview` is onlyGovernor, one-shot per proposal**, rejecting `voteEnd == 0` and `reviewEnd < voteEnd` (`InvalidReviewWindow`) and re-registration (`ReviewAlreadyRegistered`). Pushed at both Pending transitions: direct propose (`_initPendingProposal`) and collaborative Draft → Pending (`approveCollaboration`).
- **`ReviewOutcome {Unresolved, Cleared, Blocked}`**: `Unresolved` only before `reviewEnd` (or unregistered); cohort-too-small and never-opened reviews are `Cleared`; post-commit the view reports the cached resolution. `_isBlocked` is the single block-quorum predicate shared by `outcomeOf` (view), `resolveReview` (commit), and `cancelReview`, so the twins can never drift — pinned by a fuzz agreement test.
- **`_commitState` semantics**: compute the authoritative state; when the review concluded and the state changed, fire the registry's economic commit (idempotent on the registry — slash + attribution at most once); persist the transition; terminal transitions (Rejected/Expired, including Draft expiry — Sherlock #8: Draft binds the vault) decrement the open-proposal counter through `_decOpen`, which also stamps the settle cooldown (PR #359 review #1: single chokepoint so the lazy terminal path can't dodge the cooldown).
- **Unregistered-window branch (SUPERSEDED mid-plan)**: the plan's original `_afterVote` fallthrough held at `GuardianReview` when the outcome was `Unresolved` past `reviewEnd`; as shipped that branch returns a terminal `Expired` instead — holding would strand the proposal AND the vault it binds (`resolveReview` reverts `ReviewNotReadyForResolve`, `_openProposalCount` stays pinned, `emergencyCancel` is Draft/Pending-only, only a beacon upgrade recovers). Terminal-and-closed: never executable without a guardian review, but `_decOpen` releases the vault binding. See `test_unregisteredWindowExpiresAndCannotExecute`.
- **`GovernorEmergency`'s four `if (p.state != ProposalState.Executed)` checks stay direct reads** — Executed is not a time-lazy state (it only leaves via settle, a mutating path), so the stored field IS authoritative there; a `stateOf` call would cost an external registry read for nothing.
- **Veto check details preserved in `_computeState`**: G-H4 (skip when `pastTotalSupply == 0` — threshold collapses to 0), G-H6 (threshold snapshotted at Draft → Pending, not live params).

## Risks / Trade-offs

- Moving `_proposals`/`_openProposalCount` into the base shifts the governor storage layout — safe ONLY under the fresh-deploy frame; layout-pin goldens regenerated as part of the change with the diff explained.
- Consumers of the old lazy view see the new true-view behavior without a poke: the individually reviewed test deltas are the record of the spec change; the concentration was in `test/governor/GuardianReviewLifecycle.t.sol`, `test/SyndicateGovernor.t.sol`, `test/invariants/InvariantNoProposalBleed.t.sol`.
- Type-consistency pins from the plan's self-review: `registerReview(uint256,uint256,uint256)` matches both push sites; `strategyOf(uint256) → address` consistent between governor and vault; `addGovernor(address,address)` consistent across registry, mocks, and factory; `ReviewOutcome` is what `_afterVote` consumes.
