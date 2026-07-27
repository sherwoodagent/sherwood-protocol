# Integration plan: `refactor/proposal-lifecycle` × `feat/guardian-econ-security-b`

**Date:** 2026-07-24
**Status:** Proposal — needs agreement from BOTH sessions before either branch merges.
**Audience:** the session driving `refactor/proposal-lifecycle`, and the session driving `feat/guardian-econ-security-b` (Plan B).

Two sessions are editing the same contracts for different reasons. Neither branch is redundant; the work is complementary. But three of the overlaps are **storage-layout edits to upgradeable contracts**, which do not survive a naive merge. This document lists every collision, proposes one merged layout, and recommends a sequencing.

---

## 1. Branches at a glance

| | `refactor/proposal-lifecycle` | `feat/guardian-econ-security-b` |
|---|---|---|
| Goal | Structural: one authoritative proposal state, single-writer transitions, registry stops calling back into the governor | Feature: guardian economic security v1a (spec §3.3, §3.3a, §3.6, §3.7, §3.9) |
| Head at time of writing | `90700ed` | `739004e` |
| New contracts | `src/ProposalLifecycle.sol` (abstract base) | `src/ExposureLedger.sol`, `src/ProposerBondEscrow.sol` |
| `src/` files touched | `GuardianRegistry.sol` (+145/-46), `SyndicateFactory.sol` (2 lines), `interfaces/IGuardianRegistry.sol` (+42) | `GuardianRegistry.sol` (+38), `SyndicateGovernor.sol` (+59), `TierRegistry.sol` (+156), `interfaces/IGuardianRegistry.sol` (+10), `interfaces/ISyndicateGovernor.sol` (+23) |
| Tests | ~25 files touched/added | 5 new suites (~89 tests green) |
| Plan doc | `docs/superpowers/plans/` (lifecycle plan + CONTEXT.md) | `docs/superpowers/plans/2026-07-24-guardian-econ-security-B-coverage-quorum.md` |

**Key asymmetry:** the lifecycle branch does **not** touch `src/SyndicateGovernor.sol` yet — its storage fold is still pending (`ProposalLifecycle` declares `_guardianRegistry`, `_proposals`, `_openProposalCount`, `_lastSettledAt`, `collaborationDeadline`, `uint256[10] __lifecycleGap` with the comment *"Moved here in the later fold task"*). Plan B **has already** modified that contract's storage. The fold is therefore the single highest-risk merge point and has not happened yet — which is good news: it can be planned rather than repaired.

---

## 2. Collision inventory

### C1 — `GuardianRegistry.voteOnProposal` body (textual, certain)

- **Lifecycle** deletes the `IGovernorMinimal(governor).getProposalView(proposalId)` call and reads the review window from the `Review` struct instead (`r.voteEnd` / `r.reviewEnd`, populated by a new `registerReview` push). It rewrites the window guard and both late-vote-lockout computations.
- **Plan B** inserts `exposureLedger.recordApproval(...)` in the first-vote Approve branch and `releaseApproval` / `recordApproval` in the vote-change branch — immediately after `_votes[key][msg.sender] = support;` and before the emit, in both branches.
- Same hunks. Guaranteed conflict; both edits must survive.

**Resolution:** keep the lifecycle's window source (`r.voteEnd`/`r.reviewEnd`) and re-insert Plan B's two hook blocks at the same anchor (`_votes[...] = support;` → hook → emit). Plan B's CEI comment must come along: the ledger call is deliberately after every state write.

### C2 — `GuardianRegistry` storage (layout, needs a decision)

Both branches add exactly one new storage slot to a UUPS proxy, and they account for it **differently**:

| Branch | New slot | `__gap` |
|---|---|---|
| Plan B | `IExposureLedger public exposureLedger;` placed immediately before the gap | `uint256[50]` → **`uint256[49]`** (slot consumed from the gap; total slot count conserved) |
| Lifecycle | `mapping(address => address) public vaultOf;` inserted at ~line 147, **before `factory` and `swood`** | left at **`uint256[50]`** (slot count grows by one; `factory`, `swood` and the whole gap shift down one slot) |

> **Action required from the lifecycle session:** confirm which is intended.
> - If the registry proxy is **upgraded in place**, inserting `vaultOf` ahead of `factory`/`swood` moves live fields and those reads return the wrong slots after upgrade. `vaultOf` should then move to the end (before the gap) and the gap should absorb it.
> - If the registry is **redeployed fresh** (the existing comment at the gap says *"this is a fresh V1.5 mainnet redeployment so no live storage to migrate"*), the shift is harmless — but then the two branches are operating on different assumptions and must agree on one.

**Proposed merged layout** (safe under either assumption, and what Plan B's tests + goldens already assume):

```solidity
    // ... all pre-existing fields, order untouched ...
    address public factory;
    IStakedWood public swood;

    /// @notice Lifecycle: vault served by each governor (slash-misdirection guard).
    mapping(address => address) public vaultOf;
    /// @notice Plan B: exposure ledger consulted on approve-side review votes.
    IExposureLedger public exposureLedger;

    /// @dev Reserved storage (was 50; -1 vaultOf, -1 exposureLedger).
    uint256[48] private __gap;
```

Both new slots appended after the last pre-existing field, gap `50 → 48`, no pre-existing field moved, total slot count conserved.

### C3 — `Review` struct repacking (layout, lifecycle-owned)

Lifecycle changes `uint256 reviewEnd` → `uint64 reviewEnd` and adds `uint64 voteEnd`. `Review` lives in the `_reviews` mapping, so this re-packs every stored entry — fine on a fresh deployment, breaking for existing entries.

Plan B does **not** touch `Review`. No conflict, but the same fresh-deploy-vs-upgrade question as C2 applies. Flagged for one answer covering both.

### C4 — `SyndicateGovernor` storage fold (layout, future — the big one)

Plan B added, after `_tierRegistry`:

```solidity
    address internal _exposureLedger;
    address internal _bondEscrow;
    /// @dev (was 33; -2 for _exposureLedger/_bondEscrow — Plan B)
    uint256[31] private __gap;
```

and appended **one** field to the very end of `StrategyProposal`:

```solidity
    uint256 proposerBondWood;   // Plan B, append-only
```

The lifecycle fold intends to move `_guardianRegistry`, `_proposals`, `_openProposalCount`, `_lastSettledAt`, `collaborationDeadline` into `ProposalLifecycle` (with `uint256[10] __lifecycleGap`). Whoever performs the fold must:

1. Account for `_exposureLedger` and `_bondEscrow` in the post-fold layout (they are governor-level wiring, not lifecycle state — they should stay in `SyndicateGovernor`, after `_tierRegistry`).
2. Preserve `StrategyProposal.proposerBondWood` as the last field of the struct (`ProposalLifecycle` owns `_proposals`, so the struct definition travels with the base — the append must not be dropped).
3. Regenerate the storage-layout goldens (`test/GovernorLayoutPins.t.sol` + `syndicate-governor-layout.golden.json` + factory golden) **once, after the fold**, and verify the diff is append-only for every pre-existing slot.

### C5 — hard dependency: do not delete `SyndicateGovernor.getProposalView`

`ExposureLedger` reads the proposal's vault and coverage straight off the governor:

```solidity
interface ILedgerGovernorMinimal {
    function getProposalView(uint256) external view returns (ProposalViewLite memory); // .vault
    function getRequiredCoverage(uint256) external view returns (uint256);
}
```

The lifecycle branch removes the **registry's** use of `getProposalView`, which is fine — but the function itself must stay on the governor, or `ExposureLedger.recordApproval` breaks (and with it every approve vote once the ledger is wired).

**Harmonization opportunity (recommended):** after the merge, `ExposureLedger` could read the vault from the registry's new `vaultOf[governor]` mapping instead of calling back into the governor. That matches the lifecycle branch's direction (registry stops depending on governor callbacks), removes one external call from the vote hot path, and leaves only `getRequiredCoverage` as a governor read. Small change to `ExposureLedger.recordApproval`; worth doing as a follow-up rather than inside the merge.

### C6 — `IGuardianRegistry` interface (textual, mechanical)

Lifecycle adds ~42 lines (`registerReview`, `outcomeOf`, `vaultOf`, review-window getter, new errors/events). Plan B adds 10 (`setExposureLedger`, `exposureLedger()` returning `IExposureLedger`). No name clashes — union both.

### C7 — shared test mocks (textual, mechanical)

`test/mocks/MockRegistryMinimal.sol` and `test/mocks/MockGovernorMinimal.sol` are edited by both. Both declare interface conformance, so both sets of new members need stubs. Union them; keep `MockRegistryMinimal.factory()` in mind — it currently reverts `NotImplemented()`, which is the cause of the **pre-existing** failure in `test/audit-fixes/SetGuardianRegistry.t.sol::test_factory_setGuardianRegistry_succeedsForOwner` (`RegistryFactoryMismatch()`). That failure exists on `main`, on Plan B, and is unrelated to either branch's feature work — but the lifecycle branch's `vaultOf` factory wiring touches this area and could fix it cheaply.

### C8 — `SyndicateFactory` (minor now, larger later)

Lifecycle changes 2 lines. Plan B's **Task 10** (not yet implemented) will add `exposureLedger`/`bondEscrow` slots, setters, `createSyndicate` pushes, and a `pushWiring` rewire entrypoint. If the lifecycle branch lands first, Task 10 is written against the merged factory and there is no conflict at all.

---

## 3. Recommended sequencing

**Land `refactor/proposal-lifecycle` first (including its storage fold). Then rebase Plan B onto it.**

Rationale:

1. **Refactors go under features, not over them.** Re-applying Plan B's hooks/gates onto refactored code is a bounded, well-understood edit (C1 anchor + C4 slot accounting). Re-applying a structural single-writer refactor on top of new feature code means the refactor has to absorb feature logic it was never designed around.
2. **The riskiest merge point hasn't happened yet.** The governor fold is pending. If it lands with Plan B's two slots and appended struct field already known (documented in C4 above), it is planned once instead of repaired twice.
3. **Plan B's remaining tasks get cheaper.** Tasks 9, 10, 11 all touch governor/factory/goldens. Written against the post-refactor shapes, they conflict with nothing. Written now, all three need redoing.
4. **Goldens are regenerated once.** Task 11 regenerates storage-layout goldens; doing it after the fold avoids generating them twice against two different layouts.

### Concrete re-apply work for Plan B after the lifecycle branch lands

| Item | Work |
|---|---|
| C1 hooks | Re-insert two hook blocks in `voteOnProposal` at the `_votes[...] = support;` anchor, keeping the lifecycle's window reads. ~15 lines. |
| C2 registry slot | Move `exposureLedger` to the merged layout, gap → 48. ~2 lines. |
| C4 governor slots | Confirm `_exposureLedger`/`_bondEscrow` survived the fold after `_tierRegistry`; confirm `proposerBondWood` is still the last `StrategyProposal` field. |
| C5 | Verify `getProposalView` still exists on the governor; optionally switch the ledger to `vaultOf`. |
| C6/C7 | Union interface + mock members. Mechanical. |
| Tests | Re-run the 5 Plan B suites (`ExposureLedgerTest`, `ProposerBondEscrowTest`, `TierRegistry*`, `RegistryExposureHook`, `GovernorCoverageGates`) — 89 tests currently green. Fix fixtures that construct proposals if `registerReview` changes how a proposal enters review. |
| Task 11 | Regenerate goldens once, verify append-only. |

### Interim work Plan B can do without conflicting

Only **Task 12** (`script/DeployPlanB.s.sol`) touches nothing either branch shares. Tasks 9, 10, 11, 13, 14 should wait.

---

## 4. Merge-time checklist

- [ ] Lifecycle session answers the C2/C3 question: is `GuardianRegistry` upgraded in place, or redeployed fresh?
- [ ] If upgraded in place: `vaultOf` moves to the end of storage, gap absorbs it.
- [ ] Merged registry layout matches §C2 (both slots appended, gap `50 → 48`, no pre-existing field moved).
- [ ] Governor fold accounts for `_exposureLedger` / `_bondEscrow` and keeps `proposerBondWood` last in `StrategyProposal`.
- [ ] `SyndicateGovernor.getProposalView` still exists (C5).
- [ ] `IGuardianRegistry` and both test mocks are unions, not either/or.
- [ ] Storage-layout goldens regenerated once post-fold; diff verified append-only for every pre-existing slot.
- [ ] `forge test` — no new failures beyond the known pre-existing `SetGuardianRegistry.t.sol` one (C7).
- [ ] `forge fmt --check` clean with the CI-pinned forge version.

---

## 5. Open questions for the lifecycle session

1. **C2/C3:** upgrade-in-place or fresh redeploy for `GuardianRegistry`? This decides whether `vaultOf`'s placement is a bug or a non-issue, and whether the `Review` repacking is safe.
2. **C4:** does the fold intend to move `_tierRegistry` (Plan A) as well, or only the lifecycle state? Plan B's slots sit directly after it.
3. **Timeline:** roughly when does the fold land? Plan B pauses Tasks 9–11 until then.
4. **C5 harmonization:** any objection to `ExposureLedger` reading `vaultOf[governor]` off the registry instead of calling `getProposalView` on the governor, as a post-merge follow-up?
