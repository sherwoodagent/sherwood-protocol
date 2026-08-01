# Tasks — Proposal Lifecycle Deepening (completed; work merged)

## 1. Registry — review registration + vault wiring

- [x] 1.1 Write failing tests for `registerReview` (stores window; reverts for non-governor, re-register, invalid window) and `addGovernor(gov, vault)` recording `vaultOf` in `test/GuardianRegistryRegisterReview.t.sol`
- [x] 1.2 Add `voteEnd`/`reviewEnd` to the registry `Review` struct, `vaultOf` mapping, two-arg `addGovernor`, one-shot onlyGovernor `registerReview`, and `reviewWindow` view
- [x] 1.3 Extend `IGuardianRegistry` (new functions, `InvalidReviewWindow`/`ReviewAlreadyRegistered` errors, `ReviewRegistered` event) and pass the vault at the factory's `addGovernor` call site
- [x] 1.4 Run the new suite green and commit

## 2. Registry — delete the `IGovernorMinimal` call-back

- [x] 2.1 Rewire all five `getProposalView` call sites (`voteOnProposal` incl. late-vote lockout math, `cancelReview`, `openReview`, `resolveReview`, `_resolveEmergency` via `vaultOf`) to read stored registration state
- [x] 2.2 Delete the `IGovernorMinimal` interface block and its comment references
- [x] 2.3 Adapt registry test mocks: drop `getProposalView` from `MockGovernorMinimal`, push windows via `registerReview` in harness setups, carry the slash-target vault through `addGovernor`
- [x] 2.4 Run registry + StakedWood + invariant suites green and commit

## 3. Registry — `outcomeOf` + shared `_isBlocked` predicate

- [x] 3.1 Write failing tests in `test/GuardianRegistryOutcome.t.sol`: Unresolved before `reviewEnd`, Cleared when never opened or cohort too small, Blocked at quorum, plus the anti-twin-drift fuzz (`outcomeOf` agrees with `resolveReview` for any voting configuration past `reviewEnd`; post-commit the view reports the cached resolution)
- [x] 3.2 Add `ReviewOutcome` enum + `outcomeOf` to the interface; extract `_isBlocked` and reuse it in `outcomeOf`, `resolveReview`, and `cancelReview`
- [x] 3.3 Run the registry suites green and commit

## 4. `ProposalLifecycle` abstract base

- [x] 4.1 Create `src/ProposalLifecycle.sol`: migrated storage (`_guardianRegistry`, `_proposals`, `_openProposalCount`, `_lastSettledAt`, `collaborationDeadline`, layer gap), `whenNoActiveProposal`, true-view `stateOf`, `_computeState` (veto snapshot G-H4/G-H6, `_afterVote` reading `outcomeOf`), single-writer `_transition`/`_commitState`, `_decOpen` chokepoint
- [x] 4.2 Compile; verify shared events/errors live in `ISyndicateGovernor`; commit

## 5. `GovernorParameters` extends the base

- [x] 5.1 Rewire inheritance; delete the duplicated `whenNoActiveProposal` modifier and the abstract `openProposalCount` (committed with task 6)

## 6. `SyndicateGovernor` — twins die; pushes at propose; `strategyOf`

- [x] 6.1 Remove migrated storage, `_decOpen`, and `openProposalCount` duplicates from the governor
- [x] 6.2 Delete `_resolveState`, `_resolveStateView`, `_resolveAfterVote`, `getProposalView`, `ProposalViewLite`
- [x] 6.3 Reroute every call site to `_commitState`/`_transition`/`stateOf`; verify `grep -rn "\.state =" src/` hits only `ProposalLifecycle.sol`
- [x] 6.4 Push `registerReview` at both Pending transitions (`_initPendingProposal` and `approveCollaboration`'s Draft → Pending block)
- [x] 6.5 Add the `strategyOf(uint256) → address` scalar view
- [x] 6.6 Compile, run governor suites (mechanical fixes inline; lazy-view assertion deltas deferred to task 10), commit tasks 5+6 together

## 7. `GovernorEmergency` extends the base

- [x] 7.1 Rewire inheritance; delete `_getProposal`/`_getRegistry` virtual accessors (base storage used directly); keep direct `Executed` state reads (not time-lazy)
- [x] 7.2 Run the emergency suite green (mechanical adaptation only — behavioral diffs here would be refactor bugs) and commit

## 8. Vault reads `strategyOf`; `IProposalStatus` narrows

- [x] 8.1 Replace `getProposal` with `strategyOf` in `IProposalStatus`; drop the now-unused `ISyndicateGovernor` import
- [x] 8.2 Simplify `SyndicateVault._activeStrategy` to the scalar read (no try/catch)
- [x] 8.3 Run vault + invariant suites green, confirm no size regression, commit

## 9. Lifecycle harness suite

- [x] 9.1 Create `test/governor/ProposalLifecycle.t.sol` on the factory-deployed stack, all through `stateOf`/public entrypoints: Pending during vote; veto rejects WITHOUT economic commit; true-view Approved immediately after `reviewEnd`; true-view Rejected then commit agrees (slash exactly once); expiry releases the vault binding; Draft expiry; `registerReview` pushed at the Pending transition (collaborative Drafts register at Draft → Pending, not at propose)
- [x] 9.2 Run green and commit

## 10. Lazy-view test deltas — individually reviewed

- [x] 10.1 Enumerate full-suite failures; classify mechanical (ABI/mock/`addGovernor` arity — fixed inline) vs spec delta (old lazy-view assertions)
- [x] 10.2 Update each spec-delta assertion individually with a dated true-view comment; list every one in the PR description; no bulk sed
- [x] 10.3 Regenerate governor layout-pin goldens (base-contract move shifts the layout by design under the fresh-deploy frame)
- [x] 10.4 Full suite green; commit

## 11. Docs, fmt, wrap-up

- [x] 11.1 Update the README contract table (`ProposalLifecycle` row; governor/parameters/registry descriptions)
- [x] 11.2 `forge fmt` with a CI-matching forge; final gates: sizes vs Robinhood 98,304 limit, full `forge test`, single-writer grep, and empty `getProposalView|IGovernorMinimal|ProposalViewLite` grep
- [x] 11.3 Push branch and open the PR with the behavioral delta called out, the individually reviewed assertion changes listed, and the grep gates quoted as evidence
