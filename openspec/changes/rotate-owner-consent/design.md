# Design — consent-gated owner-stake binding (issue #98)

## Context

See proposal.md — Why. The spend happens in `StakedWood.transferOwnerStakeSlot` (src/StakedWood.sol:1032-1046), reached only via `SyndicateFactory.rotateOwner` (src/SyndicateFactory.sol:714-740). `rotateOwner` is public API (declared in `ISyndicateFactory.sol:48`); no deploy script calls it, and two test files exercise it (`test/factory/OwnerStakeAtCreation.t.sol`, `test/audit-fixes/SyndicateFactory_rotateOwner_proposalGuard.t.sol`). The `PreparedOwnerStake` struct (src/StakedWood.sol:292-296) packs `uint128 amount + uint64 preparedAt + bool bound` = 200 bits, leaving only 56 spare bits in its slot — an approved-vault address (160 bits) cannot be packed into the existing struct slot.

Repo precedent: sWOOD already carries defence-in-depth guards at the hazard site rather than trusting the sole caller — see `bindOwnerStake`'s `PriorStakeNotCleared` natspec (src/StakedWood.sol:921-931), which guards a path "unreachable today" specifically so future factory entrypoints land on the guard instead of the hazard. House natspec style: every guard states its adversary.

## Goals / Non-Goals

**Goals:**
- No path exists by which anyone other than the escrow's owner can cause their prepared stake to become bound to a vault.
- Keep `rotateOwner`'s ABI and single-call semantics intact.
- Consent lives at the spend site (sWOOD), covering any future factory-side caller of `transferOwnerStakeSlot`, not just today's `rotateOwner`.

**Non-Goals:**
- No change to the creation-time bind (`createSyndicate` → `bindOwnerStake`) — consent there is structural (`owner_` is the factory caller).
- No change to unstake/cooldown mechanics, slash mechanics, or the `ownerStake(vault) == 0` rotation precondition.
- No pending-owner registry on the factory (see Decision 1).

## Decisions

### Decision 1 — Remedy (a): opt-in approval checked inside `transferOwnerStakeSlot`, not (b) two-step `proposeOwner`/`acceptOwner`

The issue names two remedies. We choose (a). Rationale, axis by axis:

- **Where the guard lives.** The vulnerability is that sWOOD spends a third party's escrow on the factory's word. Option (a) puts the consent check in `transferOwnerStakeSlot` itself — the exact hazard — so *every* present and future factory code path is covered. Option (b) puts consent in factory flow control; sWOOD's `transferOwnerStakeSlot` would remain consent-free, and any future factory entrypoint (the `claimUnstakeOwner` natspec at src/StakedWood.sol:986-991 already contemplates re-bind routes) would reintroduce the bug. This mirrors the repo's own `PriorStakeNotCleared` guard-at-hazard precedent.
- **Backward compatibility of the public API.** `rotateOwner(vault,newOwner)` is declared in `ISyndicateFactory` and is the documented "only legal route" for ownership change (src/SyndicateVault.sol:407-411). Option (a) keeps its signature, event, and one-call completion; the only behavioral delta is a revert when consent is absent — which is precisely the attack being removed. Option (b) either deletes/renames the function (ABI break) or keeps the name while silently changing it into a propose step whose `OwnerRotated` event no longer means ownership changed — a semantic trap for integrators. A breaking signature change is not justified when the non-breaking remedy is also the stronger one.
- **Storage cost.** (a): one fresh mapping `address => address` (approver → approved vault), one non-zero slot per pending approval, zeroed on consumption/cancel (gas refund). The address does not fit the 56 spare bits of `PreparedOwnerStake`, so a separate mapping is the layout-safe choice either way; sWOOD state is append-only (new mapping), no layout risk. (b): an equivalent `vault => pendingOwner` mapping on the factory plus re-validation of all four rotation guards at accept time (they were checked at propose time but can drift). Net: comparable storage, but (b) duplicates guard logic across two entrypoints.
- **Griefing surface left behind.** (a): an approval is inert on its own — it locks nothing, blocks nothing, and `cancelPreparedStake` remains available to the approver at all times before the bind; worst case the current owner never rotates and the approver revokes or simply cancels the escrow. (b): a dangling `pendingOwner` lets the proposed owner accept at an arbitrary later time, when vault state (proposals, prior-owner restake) may have changed — every rotation guard must be re-checked at accept, and a cancel path for the proposer is needed; more states, more edges.
- **Callers to migrate.** No scripts; two test files gain one `vm.prank(newOwner); swood.approveOwnerStakeBinding(vault);` line per rotation. Under (b) those tests would need full two-transaction rewrites.

### Decision 2 — Approval shape: single-slot `mapping(address => address) approvedBindVault`, overwrite-on-approve

At most one approved vault per address. A prospective owner has at most one prepared escrow (`PreparedStakeAlreadyExists` guard, src/StakedWood.sol:881), so multi-vault approval sets would model consent the escrow cannot honor. Overwrite semantics (approving B replaces A) keep the API one-call; `revokeOwnerStakeBinding()` deletes. Alternative considered — `mapping(address => mapping(address => bool))`: rejected, needless surface and it permits standing approvals for many vaults, widening replay risk.

### Decision 3 — Lifecycle clearing: consume on bind, clear on `cancelPreparedStake` and on `prepareOwnerStake`

Without clearing, this replay exists: Alice approves V for a legitimate planned rotation, the plan is abandoned, she cancels, later prepares a fresh 50k escrow for her own vault — V's owner could then bind the *new* escrow against the stale approval. Clearing at all three lifecycle edges (bind = consumed; cancel = escrow gone; fresh prepare = new escrow lifetime) makes an approval valid for exactly one escrow lifetime. Cost: one `delete` (refund) per edge. `cancelPreparedStake` and `transferOwnerStakeSlot` currently have no external calls after their state writes; the added `delete` preserves that (CEI intact, `nonReentrant` omissions remain sound).

### Decision 4 — Error and events

New error `BindingNotApproved()`; events `OwnerStakeBindingApproved(address indexed owner, address indexed vault)` and `OwnerStakeBindingRevoked(address indexed owner, address indexed vault)`. The factory needs no new error — the sWOOD revert bubbles up through `rotateOwner`, and the ordering of `rotateOwner`'s calls (vault `rotateOwnership` before `transferOwnerStakeSlot`, src/SyndicateFactory.sol:731-733) is inside one transaction, so a consent revert unwinds the ownership transfer atomically. `bindOwnerStake` is deliberately left approval-free; its natspec gains a line stating why (structural consent), per house style.

## Risks / Trade-offs

- [Rotation becomes two transactions across two contracts (approve on sWOOD, rotate on factory)] → Inherent to any consent fix; the approve step is by the party being protected, cheap, and revocable. UX documented in `rotateOwner` + `transferOwnerStakeSlot` natspec.
- [Current owner front-runs a revoke: Alice approves, changes her mind, `revokeOwnerStakeBinding` is pending, owner's `rotateOwner` lands first] → The bind then executes with a consent Alice had granted and not yet revoked — a consented outcome, not the issue-#98 spend. Alice retains the normal `requestUnstakeOwner` exit. No mitigation needed beyond documenting that approval is live until revoked/cleared.
- [Stale approvals surviving forever if never used] → Inert by construction (Decision 3 + prepared-stake guards); revocable at will; zero standing risk because an approval alone moves no funds.
- [Existing tests assume consent-free rotation] → Enumerated in tasks.md; each gains the one-line approval. A miss shows up as `BindingNotApproved` in CI, not a silent pass.
- [Behavioral break for unknown external integrators calling `rotateOwner` cold] → The protocol is pre-launch on Robinhood Chain; the only enumerable callers are in-repo tests. The break *is* the fix.

## Migration Plan

New sWOOD state is append-only (one new mapping) — no storage-layout migration. Contracts are UUPS-upgradeable; for live deployments the sWOOD impl upgrade ships the guard and factory natspec ships alongside. No deploy-script changes (none call `rotateOwner`). Rollback = revert to prior impl; no state to unwind since approvals are advisory until consumed.
