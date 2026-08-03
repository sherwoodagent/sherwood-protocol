# Design — target-based batch-callee gating, Option B (issue #166)

Line anchors are against `origin/main` @ `00a264a`.

## Context — what exists today

`SyndicateVault._guardBatchCalls` (src/SyndicateVault.sol:761-942) runs on every `executeGovernorBatch` (:495-544), i.e. on the execute, settlement, `unstick`, and both emergency batch paths. It has three layers:

1. **Part 1 — unconditional privileged-target denylist** (:808-812): rejects `target ∈ {vault, bound queue}` via `_isPrivilegedBatchTarget` (:950-953), reverting `DisallowedBatchTarget`. Runs before, and independent of, the registry. Issue #118 exposed the same predicate as the external view `isPrivilegedBatchTarget` (:551-553) and consumes it at propose time (`SyndicateGovernor._rejectPrivilegedTargets`, src/SyndicateGovernor.sol:1055-1084).
2. **Part 1b — unconditional `transferFrom`-source guard** (:813-859): every recognized "pull via delegated allowance" selector must name the vault as its debited source, reverting `DisallowedTransferFromSource`. Unconditional for the same reason as Part 1: confiscation is refused, not priced.
3. **Part 2 — registry-gated value-moving-selector allowlist** (:862-941): resolves the calling governor's `tierRegistry()` by staticcall probe with two degrade-open returns (:864-867 — getter missing/malformed, and `registry == address(0)`), then checks the spender/recipient of ~20 enumerated selectors against `ITierRegistry.isAdapterAllowed`, reverting `DisallowedTransferTarget`. One exemption: the self-transfer fast-path, `recipient == address(this) && calls[i].target == asset()` (:922, :937).

`TierRegistry.isAdapterAllowed(adapter)` (src/TierRegistry.sol:743-745) is the owner-managed, **codehash-bound** (issue #137) transfer-permission axis: `setAdapterAllowed(adapter, true)` (:707-713) snapshots the adapter's effective codehash; the read self-heals lazily on drift; every demotion path clears the flag (`_demote`, :640-643). It is deliberately a separate axis from `(target, selector)` tier certification, which only PRICES coverage (`tierOf`, :204-210; consumed by `SyndicateGovernor._resolveTierAndCoverage` / `_scanCalls`, src/SyndicateGovernor.sol:1197-1231).

A batch `Call` is `{address target; bytes data; uint256 value;}` (src/BatchExecutorLib.sol:19-23). Note `value`: an empty-calldata call with `value > 0` moves native ETH and is invisible to every selector check and to the `asset()`-balance net-outflow meter (:537-538).

## Decision 1 — the callee predicate is `isAdapterAllowed`, reused; no new registry method, no second allowlist

**Question (issue #166, deferred from PR #157 round 2):** target-gating couples the batch guard to `TierRegistry`/tier-pricing more tightly than the selector-scoped approach — is that coupling acceptable, or does it need its own abstraction boundary?

**Decision:** the callee gate consumes the registry's **existing** `isAdapterAllowed(address)` — the same predicate, the same mapping, the same owner ceremony (`setAdapterAllowed`), the same codehash self-heal and demotion-clears semantics. No new registry function, no new mapping, no new event. `TierRegistry.sol` is not edited except for natspec. The coupling to *tier-pricing* does not increase at all: `tierOf` and the coverage math in `_resolveTierAndCoverage` are untouched, and remain a pure PRICING axis. What broadens is the *allowlist* axis's meaning, and that broadening is principled, not a bolt-on:

- **Under selector-blindness, "callable" and "possible fund destination" are the same consent.** The entire lesson of rounds 2-4 is that we cannot know which selectors move value. Therefore any target a batch may call must be assumed able to receive an approval/transfer under a selector we did not enumerate. A registry that answered "callable: yes, fund-destination: no" for some address would be drawing a distinction the guard cannot enforce — the two roles collapse, and `isAdapterAllowed` (defined as "may receive approvals/transfers of vault funds", src/TierRegistry.sol:135-141) is exactly the collapsed predicate.
- **A second allowlist would be a drift generator.** #118's design rejected restating the privileged-target set in two places because duplicated security predicates drift; the identical argument applies to a hypothetical `isBatchCalleeAllowed` mapping that the owner would have to keep in lockstep with `isAdapterAllowed` for every live adapter (every adapter that receives an `approve` must also be callable, and vice versa for `BaseStrategy.execute`/`settle`). One predicate, two consumers (recipient checks and callee gate) — same rule as `isPrivilegedBatchTarget`.
- **The inherited hardening is exactly what a callee gate needs.** Codehash drift (metamorphic redeploy, code appearing at a codeless address) closes callability on the next read with no state write (issue #137); any demotion severs callability instantly (`_demote`'s allowlist clear, deliberately over-broad per its natspec :610-616). Recreating those on a fresh mapping would re-fight issues #137/#51.
- **The abstraction boundary that DOES matter is preserved:** the vault still reaches the registry only through the calling governor's `tierRegistry()` staticcall (never a stored registry address of its own), and `TierRegistry`'s note at :161-166 — the allowlist codehash snapshot must not be repurposed by certification-path features — is unaffected; we add a consumer of the axis, not a new axis.

**Accepted consequence (the "tighter coupling" the round-2 author flagged, decided rather than deferred):** a non-value-moving call to an arbitrary external protocol, which today is *priced* (tier 2, full-notional coverage via `_scanCalls`) but never *refused*, now requires an explicit `setAdapterAllowed` entry to remain callable. Tier pricing stops being an implicit callability grant. This is the point of Option B, and it matches how the system is actually operated: every live strategy adapter is already allowlisted (deploy batches `approve(adapter)`, which Part 2 already requires), so the incremental owner burden is only for direct-to-protocol calls that bypass an adapter — which is precisely the surface that should require explicit consent. Tier certification remains optional and orthogonal: an allowlisted callee with no certification is simply priced at tier 2, as today.

## Decision 2 — `asset()` is exempt from the callee gate; the existing self-transfer fast-path is preserved verbatim

**Question:** does the self-transfer fast-path exemption (`target == asset()`) survive under a target-based model?

**Decision:** yes, generalized. The callee gate exempts `target == asset()` entirely (the gate is `target != asset_ && !isAdapterAllowed(target)` → revert), and the existing recipient-side fast-path at :922/:937 (`recipient == address(this) && calls[i].target == asset()` skips the recipient registry check) is kept character-for-character.

- **Why the exemption is necessary:** every capital-deploy batch's first call is `asset().approve(adapter, amt)` — `target == asset()`. Requiring the owner to allowlist the vault's own underlying token in the TierRegistry would make every existing deploy flow revert until a migration ceremony ran, for zero security gain (see next bullet), and would break the entire registry-wired test corpus. Losing the recipient-side fast-path would additionally break vault-internal accounting shapes (`asset().transferFrom(vault, vault, amt)` / self-approve) that `test/vault/SelectorGuard.t.sol` pins today.
- **Why the exemption is safe:** `asset()` is a deployment-time-vetted constant (chosen at `initialize`, immutable thereafter), not a member of the open-ended token set the selector gap was about. Calls to it remain covered by Part 1b (source guard), Part 2's recipient checks on every enumerated selector, and — uniquely among all targets — the outer net-outflow balance-diff meter (:537-538), which verifies actual movement rather than calldata claims. The residual is an *unenumerated* selector on `asset()` itself that sets an approval without moving balance; that is real but bounded to one owner-vetted contract (the launch assets are standard ERC-20s), versus today's exposure of every token the vault has ever held. Recorded in the spec delta as the documented residual.
- **`WETH`-style wrappers and reward tokens are NOT exempt:** any token other than `asset()` that a batch must call (e.g. to approve a reward token to a swap adapter) needs an explicit `setAdapterAllowed(token, true)`. That is intended: each such token is an owner-attested, codehash-pinned exception rather than an ambient capability.

## Decision 3 — the callee gate is ADDED and the selector layer RETAINED; no dual-mode transition; degrade posture copies #118 exactly

**Question:** does this replace `_guardBatchCalls`'s selector checks or run alongside them, and what about in-flight proposals validated under the old rule?

**Decision — layering:** additive. Parts 1 and 1b stay unconditional and untouched. Part 2 keeps its registry resolution and both degrade-open returns, then gains the callee gate at the **top of the existing per-call loop** (:869), before the `data.length < 4` early-continue (:871) — short-calldata calls must be callee-gated, since an empty-calldata `value`-bearing call is a native-ETH exfiltration route today. The selector recipient/spender checks then run as before. Replacing the selector layer outright was considered and rejected: on an *allowlisted* token callee, `token.approve(attacker, max)` passes any pure target gate (the target is the consented token; the attacker appears only in calldata) — only the recipient check refuses it. Target gate = outer boundary over the open-ended target set; selector layer = inner boundary on the finite allowlisted set. Neither subsumes the other.

**Decision — no transition period / dual mode.** An on-chain "warn-only" mode is unenforceable, and a config flag toggling the gate would itself be a new attack surface. The compat lane for legacy deployments already exists and is the #118-established degrade posture, followed exactly:

- **Degrade-open on unresolved registry:** governor without a `tierRegistry()` getter, malformed return, or `registry == address(0)` ⇒ the callee gate (like the whole of Part 2) is skipped. A registry-less vault keeps working; hard-reverting would brick it (same argument as the UNSET REGISTRY note, :751-760).
- **Fail-closed on resolved-but-refused:** a wired registry that answers `false` (including via codehash drift) ⇒ revert `DisallowedBatchCallee(target)`. No fallback to "priced at tier 2".
- **No divergence from #118's pattern** — the one difference (this gate lives in the registry-dependent half rather than the unconditional half) is forced by the predicate itself requiring a registry, and matches where Part 2's checks already live.

**Decision — in-flight proposals (the migration question asked by #166).** `_guardBatchCalls` validates stored calldata at *use* time, so a vault-implementation upgrade changes the rule for proposals already in flight. Per #118's asymmetry analysis: a proposal in `Approved` whose `executeCalls` now refuse self-heals (revert at `executeProposal` → `Expired` → `_decOpen`); a proposal in `Executed` whose `settlementCalls` now refuse is **terminal** (`settleProposal` and `unstick` replay the same calls; recovery is the owner's `emergencySettleWithCalls` — whose fresh calls must themselves pass the callee gate, so a rescue targeting a not-yet-allowlisted protocol additionally needs the registry owner to run `setAdapterAllowed` first). This is handled operationally, not with code:

1. Before rolling the implementation, pre-populate the registry: `setAdapterAllowed(t, true)` for every non-`asset()` target that live/queued batches legitimately call (live adapters already qualify via Part 2's existing requirement).
2. Upgrade a vault only while it has no open proposal (`_openProposalCount` caps open proposals at one per vault, so this is a single check per vault), OR verify the open proposal's stored `executeCalls`/`settlementCalls` targets are each `asset()` or allowlisted before upgrading.

No lifecycle state is grandfathered in code — a batch that cannot satisfy the live rule must not run, and the checklist above makes the honest set empty at upgrade time.

**Decision — propose-time is NOT extended.** #118's Decision 2 ("propose validates the denylist half only; checking the registry half would manufacture false completeness") applies with extra force here: `isAdapterAllowed` is mutable (`setAdapterAllowed`, `_demote`) *and* flips with zero state writes on codehash drift, so a propose-time callee check would be stale by settle time and invite exactly the wrong inference. `SyndicateGovernor._rejectPrivilegedTargets` stays denylist-only; no governor edits in this change.

## Decision 4 — this genuinely subsumes issue #18 for its entire scenario set; recommend closing #18 as a duplicate once landed, with the residual recorded

**Question:** does Option B really subsume #18 (ERC-721/1155/777 selector gaps), and how should #18 be dispositioned?

**Decision:** yes, for every scenario #18 actually describes — and the recommendation (recorded here; do NOT close #18 from this change, only comment) is to close #18 as **subsumed by this change** once it lands.

- #18's vectors are `nft.setApprovalForAll(attacker, true)`, `nft.safeTransferFrom(vault, attacker, id)`, `erc777.authorizeOperator(attacker)`, etc., against exotic-asset contracts the vault holds as strategy positions. None of those contracts is `asset()`, and none has a reason to be allowlisted as a batch callee (positions are held and later unwound by adapters, not manipulated by direct batch calldata). Under the callee gate every such call reverts `DisallowedBatchCallee(nft)` before its selector is even examined — including standards #18 never enumerated (ERC-6909, future ones). That is the whole class, closed by default posture rather than selector-by-selector, which is strictly stronger than what #18 asked for.
- **Residual, stated so #18's closure is honest:** if governance ever DID allowlist an exotic-asset contract as a callee, its non-ERC-20 selectors would pass unexamined (the retained selector layer only knows ERC-20-family shapes). The tier-policy spec delta therefore adds the governance-discipline requirement: exotic-asset contracts MUST NOT be allowlisted as batch callees; batches reach positions through allowlisted adapters. This mirrors the registry's existing proxy-discipline rule (certify nothing upgradeable, src/TierRegistry.sol:24-44) — a documented operator invariant backing a mechanical guard. Adding #18's specific selectors to the retained layer stays available as cheap future hardening if that discipline ever needs a mechanical backstop, but it is not needed to close #18's filed scenarios and is out of scope here (scope discipline is the lesson of rounds 1-4).

## Exact code shape (for the implementer)

**`src/interfaces/ISyndicateVault.sol`** — after `DisallowedBatchTarget` (:64), declare:

```solidity
/// @notice A governor-batch call named a target that is neither the vault's
///         underlying asset() nor an adapter allowlisted in the TierRegistry.
///         Refused regardless of selector or calldata length — the callee
///         gate is what closes the unenumerable-selector class (issue #166);
///         the selector checks beneath it are defense-in-depth on allowlisted
///         callees. Only raised when the calling governor resolves a nonzero
///         TierRegistry (the callee gate degrades open with the rest of the
///         registry-gated half).
error DisallowedBatchCallee(address target);
```

**`src/SyndicateVault.sol`** — in `_guardBatchCalls`, after the registry resolution block (:862-867) and before the Part 2 loop (:869), hoist the asset once; then gate at the top of the loop body, ahead of the `data.length < 4` continue:

```solidity
address asset_ = asset();
for (uint256 i = 0; i < calls.length; i++) {
    // ── PART 2a: target-based callee gate (issue #166, Option B) ──
    // Runs on EVERY call — before the short-calldata continue below, so
    // empty-calldata and native-`value` calls are gated too. asset() is
    // the sole exemption (design.md Decision 2); everything else must be
    // an allowlisted, codehash-current adapter.
    address target = calls[i].target;
    if (target != asset_ && !ITierRegistry(registry).isAdapterAllowed(target)) {
        revert DisallowedBatchCallee(target);
    }
    bytes calldata data = calls[i].data;
    if (data.length < 4) continue;
    // ── PART 2b: value-moving-selector checks (retained, unchanged) ──
    ...existing selector switch, byte-for-byte...
}
```

Also replace `calls[i].target == asset()` in the two fast-path sites (:922, :937) with `calls[i].target == asset_` (pure caching; behavior identical). Parts 1/1b (:808-860) and the registry resolution (:862-867) are not touched. No storage changes; no changes to `executeGovernorBatch`'s meters.

**Natspec:** rewrite the `_guardBatchCalls` doc comment's Option-A/Option-B passages (:120-127, :639-652, :710-749) and `executeGovernorBatch`'s RESIDUAL note (:524-536) to describe the two-layer model: callee gate = outer boundary (class-closing), selector layer = inner boundary on allowlisted callees, `asset()` = metered exemption. Do not delete the round 2-4 history — compress it into the "why the selector list is no longer the boundary" narrative. `TierRegistry.setAdapterAllowed`/`isAdapterAllowed`/`_adapterAllowed` natspec (:135-141, :684-745) gains the callee-gate consumer and the exotic-asset discipline note.

**Error-ordering consequence for tests (this WILL move reverts):** any existing test that drove a guarded selector at a **non-allowlisted, non-asset token** while a registry was wired previously reverted `DisallowedTransferTarget`/`MalformedCall` inside the selector switch; it now reverts `DisallowedBatchCallee` at the gate above. Tests whose point is the recipient/spender/malformed check must first `setAdapterAllowed(token, true)` (or target `asset()`) so the inner layer is actually reached — which is also the only honest way to keep the inner layer covered post-change. Tests running with NO registry wired are unaffected (both layers skipped). Part 1/1b assertions are unaffected (they fire before the registry section).

## Test impact — sweep targets

- `test/vault/SelectorGuard.t.sol` — the main selector suite; reclassify each case per the error-ordering rule above. Fast-path pins (`asset()` self-transfer) unchanged.
- `test/audit-fixes/Vault_batchQueueTargets.t.sol`, `Vault_batchQueueTargets_lifecycle.t.sol`, `test/audit-fixes/Governor_proposeTargetValidation.t.sol` — Part 1/propose-time pins; expected untouched (fire before the registry half). If any needs edits, the change regressed Part 1 — stop and revisit.
- `test/vault/OutflowMetering.t.sol`, `test/GovernorCoverageGates.t.sol`, `test/governor/TierResolution.t.sol`, `test/integration/TierEndToEnd.t.sol`, `test/integration/Robinhood*IntegrationTest.sol`, `test/integration/strategies/PortfolioMainnetFork.t.sol` — registry-wired flows; any batch call to a mock protocol/token that is not allowlisted needs a `setAdapterAllowed` in setup (this is the migration checklist rehearsed in miniature).
- New `test/vault/CalleeGate.t.sol` — scenarios from the spec delta: unknown-selector call on unlisted token refused; `setApprovalForAll` on unlisted NFT refused (the #18 witness); empty-calldata `value` call refused; `asset()` exemption; allowlisted-callee pass; allowlisted-token + bad recipient still refused by the inner layer; degrade-open with unset registry and with getter-less governor; codehash-drift refusal (allowlisted then code swapped ⇒ `DisallowedBatchCallee`); demotion severs callability.

## Risks

- **Bricking honest flows at upgrade** — the real operational risk; mitigated by the Decision 3 checklist (pre-populate allowlist, upgrade with no open proposal). The failure mode if the checklist is skipped is loud (`DisallowedBatchCallee` naming the missing target) and recoverable (`setAdapterAllowed`, then `unstick`/emergency path).
- **Emergency-path tightening**: owner rescue calls to a never-allowlisted protocol now need a registry-owner `setAdapterAllowed` first. Accepted: the registry owner is the same governance that certifies adapters, and an emergency involving a brand-new callee already requires governance coordination; degrade-open still covers registry-less vaults.
- **Over-reliance on the allowlist's codehash discipline**: the callee gate makes `isAdapterAllowed` more load-bearing; the proxy blind spot (a proxy's runtime bytecode is static across upgrades) applies to callability exactly as it does to fund destinations today. Already documented at src/TierRegistry.sol:738-742; the tier-policy delta restates it for the callee role.
- **Sequencing**: touches only `SyndicateVault.sol` + interface + tests, so no collision with governor-editing changes in flight; do not touch #35/#45/#115 branches or worktrees. Land as its own implementation + audit cycle per #166's explicit request — the pattern being fixed is precisely "just one more selector" scope-underestimation.
