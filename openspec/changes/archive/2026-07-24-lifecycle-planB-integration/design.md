# Design — Lifecycle × Plan B integration

## Context

Status at writing (2026-07-24): proposal — needed agreement from BOTH sessions before either branch merged. Audience: the session driving `refactor/proposal-lifecycle` (head `90700ed`) and the session driving `feat/guardian-econ-security-b` (head `739004e`).

| | `refactor/proposal-lifecycle` | `feat/guardian-econ-security-b` |
|---|---|---|
| Goal | Structural: one authoritative proposal state, single-writer transitions, registry stops calling back into the governor | Feature: guardian economic security v1a (spec §3.3, §3.3a, §3.6, §3.7, §3.9) |
| New contracts | `src/ProposalLifecycle.sol` (abstract base) | `src/ExposureLedger.sol`, `src/ProposerBondEscrow.sol` |
| `src/` touched | `GuardianRegistry.sol` (+145/-46), `SyndicateFactory.sol` (2 lines), `IGuardianRegistry.sol` (+42) | `GuardianRegistry.sol` (+38), `SyndicateGovernor.sol` (+59), `TierRegistry.sol` (+156), `IGuardianRegistry.sol` (+10), `ISyndicateGovernor.sol` (+23) |
| Tests | ~25 files touched/added | 5 new suites (~89 tests green) |

**Key asymmetry:** the lifecycle branch did NOT yet touch `src/SyndicateGovernor.sol` — its storage fold was still pending (`ProposalLifecycle` declares `_guardianRegistry`, `_proposals`, `_openProposalCount`, `_lastSettledAt`, `collaborationDeadline`, `uint256[10] __lifecycleGap`). Plan B had already modified that contract's storage. The fold was therefore the single highest-risk merge point and had not happened yet — good news: it could be planned rather than repaired.

## Decisions

### Collision inventory

**C1 — `GuardianRegistry.voteOnProposal` body (textual, certain).** Lifecycle deletes the `getProposalView` call and reads the review window from the `Review` struct (`r.voteEnd`/`r.reviewEnd`, populated by a new `registerReview` push), rewriting the window guard and both late-vote-lockout computations. Plan B inserts `recordApproval`/`releaseApproval` hooks immediately after `_votes[key][msg.sender] = support;` in both branches. Same hunks, guaranteed conflict; both edits must survive. Resolution: keep the lifecycle's window source, re-insert Plan B's two hook blocks at the same anchor (state write → hook → emit), carrying Plan B's CEI comment.

**C2 — `GuardianRegistry` storage (layout, needs a decision).** Both branches add one slot to a UUPS proxy but account differently: Plan B places `exposureLedger` before the gap and shrinks it 50 → 49 (slot count conserved); lifecycle inserts `vaultOf` BEFORE `factory`/`swood` and leaves the gap at 50 (shifting `factory`, `swood`, and the gap down one slot). If the proxy is upgraded in place, the lifecycle placement moves live fields — `vaultOf` must move to the end. If redeployed fresh (the gap comment says "fresh V1.5 mainnet redeployment"), the shift is harmless — but the branches must agree on one assumption. Proposed merged layout (safe under either):

```solidity
    address public factory;
    IStakedWood public swood;
    mapping(address => address) public vaultOf;      // lifecycle
    IExposureLedger public exposureLedger;           // Plan B
    uint256[48] private __gap;                       // was 50; -1 each
```

**C3 — `Review` struct repacking (layout, lifecycle-owned).** `uint256 reviewEnd` → `uint64 reviewEnd` + new `uint64 voteEnd` re-packs every stored `_reviews` entry — fine on fresh deploy, breaking for existing entries. Plan B does not touch `Review`; no conflict, but the same fresh-deploy-vs-upgrade question as C2 applies. One answer covers both.

**C4 — `SyndicateGovernor` storage fold (layout, future — the big one).** Plan B added `_exposureLedger`/`_bondEscrow` after `_tierRegistry` (gap 33 → 31) and appended `proposerBondWood` to the end of `StrategyProposal`. Whoever performs the fold must: (1) keep the two slots in `SyndicateGovernor` after `_tierRegistry` — they are governor-level wiring, not lifecycle state; (2) preserve `proposerBondWood` as the last struct field (`ProposalLifecycle` owns `_proposals`, so the struct definition travels with the base); (3) regenerate storage-layout goldens ONCE, after the fold, verifying an append-only diff for every pre-existing slot.

**C5 — hard dependency: do not delete `SyndicateGovernor.getProposalView`.** `ExposureLedger` reads the proposal's vault and coverage off the governor (`ILedgerGovernorMinimal.getProposalView(...).vault` + `getRequiredCoverage`). The lifecycle branch removes the *registry's* use, which is fine — but the function must stay, or `ExposureLedger.recordApproval` breaks and with it every approve vote once the ledger is wired. Harmonization opportunity (recommended, post-merge follow-up): read the vault from the registry's `vaultOf[governor]` mapping instead — matches the lifecycle direction, removes one external call from the vote hot path, leaves only `getRequiredCoverage` as a governor read.

**C6 — `IGuardianRegistry` interface (textual, mechanical).** Lifecycle adds ~42 lines (`registerReview`, `outcomeOf`, `vaultOf`, review-window getter, errors/events); Plan B adds 10 (`setExposureLedger`, `exposureLedger()`). No name clashes — union both.

**C7 — shared test mocks (textual, mechanical).** `MockRegistryMinimal` / `MockGovernorMinimal` edited by both; union the stubs. `MockRegistryMinimal.factory()` reverting `NotImplemented()` is the cause of the pre-existing `SetGuardianRegistry.t.sol` failure (`RegistryFactoryMismatch()`) — exists on `main` and both branches, unrelated to either feature; the lifecycle's `vaultOf` factory wiring touches this area and could fix it cheaply.

**C8 — `SyndicateFactory` (minor now, larger later).** Lifecycle changes 2 lines; Plan B's Task 10 (not yet implemented at time of writing) adds ledger/escrow slots, setters, pushes, and `pushWiring`. If lifecycle lands first, Task 10 is written against the merged factory and there is no conflict at all.

### Sequencing rationale

Land `refactor/proposal-lifecycle` first (including its storage fold), then rebase Plan B onto it:

1. Refactors go under features, not over them — re-applying Plan B's hooks/gates onto refactored code is a bounded, well-understood edit; re-applying a structural single-writer refactor on top of new feature code means the refactor absorbs feature logic it was never designed around.
2. The riskiest merge point (the governor fold) hadn't happened yet — with Plan B's two slots and appended struct field documented in C4, it is planned once instead of repaired twice.
3. Plan B's remaining tasks (9, 10, 11) all touch governor/factory/goldens — written against post-refactor shapes they conflict with nothing; written earlier, all three need redoing.
4. Goldens are regenerated once, after the fold, not twice against two different layouts.

Interim work Plan B could do without conflicting: only Task 12 (`script/DeployPlanB.s.sol`); Tasks 9, 10, 11, 13, 14 waited.

### Open questions posed to the lifecycle session

1. C2/C3: upgrade-in-place or fresh redeploy for `GuardianRegistry`? Decides whether `vaultOf`'s placement is a bug or a non-issue, and whether the `Review` repacking is safe.
2. C4: does the fold move `_tierRegistry` (Plan A) as well, or only the lifecycle state? Plan B's slots sit directly after it.
3. Timeline: when does the fold land? Plan B pauses Tasks 9–11 until then.
4. C5 harmonization: any objection to the ledger reading `vaultOf[governor]` off the registry as a post-merge follow-up?

## Risks / Trade-offs

- A naive merge of the storage edits would silently corrupt live proxy state (C2's field shift) or strand the appended struct field (C4) — the whole point of pre-agreeing the layout.
- The chosen sequencing delayed Plan B's Tasks 9–11; accepted because the alternative was doing the golden regeneration and governor/factory work twice.
