# Design — per-call capital declarations (issue #43)

## Context

Line references are against `origin/main` @ `388460c` unless a branch is named.

Today's arithmetic, all in `SyndicateGovernor`:

- `_resolveTierAndCoverage(execCalls, settleCalls, maxCapital)` (:1150-1163): `tier = max(execTier)`; `coverage = maxCapital * (Σ execBps + Σ settleBps) / 10_000`; `registry == address(0)` → `(2, maxCapital)`.
- Called at propose via `_snapshotTierAndGate` (:1049-1128, which also runs the covered-TVL cap, coverage horizon, and proposer-bond lock) and re-resolved at execute (:415-418) behind the `TierRegressed` / `CoverageRegressed` guards.
- Enforcement is batch-level only: `SyndicateVault.executeGovernorBatch(calls, maxNetOutflow)` (:467-516) takes ONE before/after snapshot of the vault's `asset()` balance around the whole delegatecalled batch; `BatchExecutorLib.executeBatch` (:36-45) is a bare loop with zero accounting.

Deployment reality (re-verified 2026-08-03 at `388460c`, same method as retire-lane-a's owner-confirmed finding): **no governor proxy and no vault proxy is deployed on the plan-of-record chain** — `broadcast/` has no `4663` directory at all. `broadcast/UpgradeVaultImpl.s.sol/46630` shows Robinhood TESTNET vaults exist (disposable); the Base 8453 lineage is legacy, takes no upgrades (vault impl 18 bytes under EIP-170), and is out of scope by standing decision. Consequences: the storage-layout change is free in practice (goldens still regenerated, append-only discipline still followed because it costs nothing), and the `BatchExecutorLib` migration must be *specified and shippable* but its live-vault leg exercises only testnet until mainnet deploys.

## D1 — Caps arrive as two parallel arrays on `propose`, not as a `RiskEnvelope` field

**Decision:** `propose` gains `uint256[] calldata executeCallCaps` (immediately after `executeCalls`) and `uint256[] calldata settlementCallCaps` (immediately after `settlementCalls`). `RiskEnvelope` keeps exactly `{maxCapital, maxDrawdownBps}`.

The issue sketched "`RiskEnvelope` gains per-call caps"; the decision comment left it open ("gains a field, or caps arrive as a parallel array"). Parallel arrays win on every axis examined:

- **The struct is transient, so "append-only" buys nothing here.** `RiskEnvelope` is a calldata-only carrier — it is never stored. `propose` flattens it into `StrategyProposal`'s appended scalar fields (`p.maxCapital`, `p.maxDrawdownBps`, :285-286). A dynamic array cannot be flattened into that appended-scalars discipline; it would have to live in its own mapping regardless. So the struct-field option changes the ABI shape without changing where the data actually lives — the storage question is decided independently (two appended mappings, mirroring `_executeCalls` / `_settlementCalls`).
- **ABI clarity.** A cap is per-call data; its meaning is positional against the call array it prices. Placing `executeCallCaps` adjacent to `executeCalls` in the signature makes the pairing legible in calldata, in explorers, and in the length-mismatch error. A `uint256[]` buried inside a struct that otherwise holds proposal-scalars would be the one dynamic member of an otherwise fixed struct — legal, but it obscures which call each entry binds, and the envelope would need TWO such arrays anyway (the execute and settlement legs price separately), at which point the struct is just carrying a parallel-array pair at one remove.
- **Gas / stack.** Calldata size is identical. Two top-level array params cost two calldata-offset stack slots in `propose` — a real concern in this function (see Risks) — but the struct alternative costs the same slots the moment the arrays are touched, plus a nested decode. Neither wins on gas; arrays win on the mitigation available (store-early-then-drop, the exact `_storeCalls` pattern already used to kill the call arrays' stack pressure at :316-326).
- **`maxCapital` survives, deliberately.** The issue thread's recommendation ("keep the proposal-level ceiling as a belt-and-braces bound") is adopted: `maxCapital` remains the vault-enforced per-batch net-outflow cap and the `MaxCapitalExceedsCeiling` anchor; caps must sum within it per batch.

**Validation set (propose-time, all before any state-changing external call):**

1. `executeCallCaps.length == executeCalls.length` and `settlementCallCaps.length == settlementCalls.length`, else `CallCapsLengthMismatch()`. Runs with the other cheap input checks, after `TooManyCalls` (which bounds every loop that follows).
2. `Σ executeCallCaps <= maxCapital` AND `Σ settlementCallCaps <= maxCapital`, else `CallCapsExceedMaxCapital()`. **Per batch, not combined**: the execute and settlement batches run in separate transactions, each independently bounded by the vault's `maxNetOutflow = maxCapital` meter — an honest unwind legitimately re-moves the same capital the execute batch deployed, so requiring the combined sum under `maxCapital` would halve every proposal's settlement budget for no safety gain. Overflow is a non-issue (`cap_i ≤ maxCapital ≤ totalAssets`, ≤ 64 entries per array).
3. Per-call tier-2 ceiling — D2 below. Runs inside the existing registry scan (one sweep, not two).

## D2 — Tier stays batch-wide; coverage becomes per-call; the tier-2 ceiling returns as a PER-CALL parameter

**Question as posed: does a single call's cap get its own tier classification independent of the batch max, or is tier still batch-wide with only the coverage math becoming per-call?**

**Decision: tier stays batch-wide (`tier = max(execTier)`); only the coverage math becomes per-call.** Every call already HAS its own tier — `TierRegistry.tierOf(target, selector)` is per-(target, selector) and `_scanCalls` reads it per call. What the proposal-level `envelopeTier` field does is aggregate for three consumers, and all three want the max:

1. **The quorum-tier gate** (`proposal.envelopeTier >= quorumTierThreshold`, :444) decides whether a covering quorum is required *at all*. Max is the fail-closed aggregate: if any call is tier 2, the proposal contains tier-2 risk and must clear whatever the threshold demands. (Moot in the plan-of-record deployment — PRE-FLIGHT 4 pins the threshold at 0, every tier requires quorum — but the spec must stay correct for nonzero thresholds.)
2. **`TierRegressed`** (:417) is a scalar snapshot-vs-live compare. Keeping it batch-wide keeps it one SLOAD + one compare. Per-call tier snapshots would cost up to 128 stored tiers per proposal and buy nothing: a certification change that matters economically ALSO moves the coverage sum — a demotion flips that call's `boundBps` to 10_000, and a same-tier re-certification with a higher bound raises `boundBps` — and the per-call-sum `CoverageRegressed` compare catches both at exactly the affected call's weight. The one drift the coverage compare cannot see is a demotion on a call whose cap is 0 (contribution 0 before and after); the batch-wide `TierRegressed` catches precisely that case whenever it raises the max, and a zero-cap call inside an already-tier-2 batch can still move nothing (its meter cap is 0) — see the residual in Risks.
3. **`getProposalTier`** is informational; max matches how guardians reason about a batch ("what is the worst thing in here").

So the tier system needs no per-call storage; the caps do the per-call work. Coverage becomes:

```
coverage = Σ_exec (cap_i × boundBps_i) / 10_000  +  Σ_settle (cap_j × boundBps_j) / 10_000
```

computed in one place (`_resolveTierAndCoverage`, now taking the two cap arrays alongside the two call arrays). Monotonic in every `cap` and every `boundBps`, which is what the regression guard and #27's scaling both lean on.

**Fail-closed default preserved exactly:** `registry == address(0)` still returns `(2, maxCapital)` — with no bounds data there is no per-call pricing, and the pre-registry safe default must not get cheaper because caps exist. (The caps are still validated and still metered at execution in that configuration; metering needs no registry.)

**The per-call tier-2 ceiling.** The proposal-wide `maxEnvelopeTier <= 1` ceiling was dropped by owner decision 2026-07-31 (recorded at `script/DeployPlanB.s.sol` PRE-FLIGHT 4: tier 2 stays admissible on-chain; guardian ROE handled off-chain). This change re-introduces a ceiling in the per-call, composable form the issue argued for ("tier 2 becomes a line item, not a proposal type") — which does not conflict with that decision: it never refuses tier 2, it bounds how much any single tier-2 line item may declare.

- New governor parameter `tier2CallCapBps`, owner-set via the standard setter pattern (bounds `[1, 10_000]`, 0 stored = unset = reads as 10_000, mirroring `maxCapitalBps`; uniform `ParameterChangeFinalized` event; frozen mid-proposal like every parameter). Default is therefore **inert** — the mechanism lands with the change (per the owner's "both propose-time validations must land"), the policy value is a deployment/governance act: `DeployPlanB` sets 200 (2% of TVL, the issue's "~100–200bps") with a post-wiring pre-flight assert.
- Enforcement at propose, inside the coverage scan: for every call in EITHER array whose resolved tier is 2 (uncertified included), require `cap_i <= totalAssets() * tier2CallCapBps / 10_000`, else `Tier2CallCapExceedsCeiling(i)` (index disambiguates; arrays are scanned exec-then-settle). Settlement calls are included because they are arbitrary pre-committed calldata and are priced by coverage for exactly that reason — a settle-side tier-2 call is the classic parked-extraction vector (:470-474's own natspec).
- Propose-time only, deliberately: post-propose tier drift is the regression guards' job (a call certified tier-0/1 at propose that demotes to tier 2 before execute raises the coverage sum and/or the max tier, so `CoverageRegressed`/`TierRegressed` block execution — the ceiling does not need re-checking at execute to stay sound).

**Zero caps are legal at every tier.** A cap of 0 declares "this call moves no vault asset" — true of harvests, approvals (balance-invisible by nature), adapter pokes, and most uncertified-but-harmless selectors, which all default to tier 2. Forcing nonzero caps on tier-2 calls would re-create a miniature of the over-count this change deletes (phantom coverage for calls that cannot move the asset), and any floor low enough to be honest is dust. The doctrine is already in the codebase (:438-441): coverage prices EXTRACTABLE value, and the gate keys on it — a call whose asset-extractable value is capped at 0 needs no covering signer *for that route*; the balance-invisible routes are `_guardBatchCalls`' job (ERC20 selector allowlist), not pricing's. The residual this leaves for exotic assets is real and recorded in Risks — a reduction in DEGREE of an already-documented residual, not a new class.

`requiredCoverage == 0` becomes genuinely reachable with a wired registry (an all-zero-cap batch prices to zero at ANY tier mix, since a tier-2 call's contribution is `cap × 10_000 / 10_000 = cap = 0`). The quorum gate's existing `requiredCoverage != 0` key (:442-448) handles it as designed; the "not currently reachable" natspec at :438-441 must be updated to say it now is, and why that is sound (zero declared extractable value + per-call meters enforcing exactly that declaration at 0).

## D3 — `BatchExecutorLib` metering: gross per-call balance-delta against the declared cap; breach reverts the batch

**What is measured:** the vault's underlying `asset()` — the SAME asset the batch-level meter uses, passed in by the vault (`asset` parameter), never re-derived inside the lib. This is the issue reverification's design note (a): defining per-call "outflow" against any other token would re-blur the attribution the caps exist to sharpen. Multi-asset flows remain the selector guard's and tier pricing's domain, unchanged.

**How** (illustrative shape, not committed code):

```solidity
function executeBatch(Call[] calldata calls, address asset, uint256[] calldata caps) external {
    bool metered = caps.length != 0;
    if (metered && caps.length != calls.length) revert CapsLengthMismatch();
    uint256 beforeBal = metered ? IERC20(asset).balanceOf(address(this)) : 0;
    for (uint256 i = 0; i < calls.length; i++) {
        (bool success, bytes memory returnData) = calls[i].target.call{value: calls[i].value}(calls[i].data);
        if (!success) { /* bubble revert data, as today */ }
        if (metered) {
            uint256 afterBal = IERC20(asset).balanceOf(address(this));
            uint256 outflow = beforeBal > afterBal ? beforeBal - afterBal : 0;
            if (outflow > caps[i]) revert CallCapExceeded(i, outflow, caps[i]);
            beforeBal = afterBal; // consecutive snapshots: nothing runs between iterations
        }
    }
}
```

Under delegatecall `address(this)` is the vault, so the lib reads the same balance vantage as the vault's own meter. One `balanceOf` staticcall per call plus one before the loop (the *after* of call *i* is reused as the *before* of call *i+1* — safe because no code runs between iterations, and it is exactly the issue's gas budget of "one balance read per call"). The spec pins only the observable semantics: `outflow_i = max(0, balance_before_call_i − balance_after_call_i)`, per call, gross across calls.

**Gross rule (the issue's explicit decision, endorsed at filing):** a refund arriving in call 4 must not refill call 3's budget. Per-call snapshots give this automatically — each call's outflow is floored at 0 and compared only against its OWN cap; inflows benefit no other call's budget. *Within* one call, netting is inherent (a call is atomic; a swap leg that sends 100 and receives 99 in the same external call has outflow 1). Proposers pad unwind-and-redeploy patterns; accepted cost, stated in the issue.

**On breach: revert the whole batch.** `CallCapExceeded(uint256 index, uint256 outflow, uint256 cap)`. The design-question alternative — "refuse to count the excess toward coverage" (fail-open on gross spend, fail-closed on accounting) — is rejected on house style and on substance: every money boundary in this codebase reverts (`MaxNetOutflowExceeded`, `QueueReserveBreached`, `BufferBreached`, `InsufficientApproveCoverage`), and an accounting-only response would mean the chain watched a call exceed the declaration guardians priced and let the money go anyway — realized extraction would then exceed priced coverage, the one direction the tier system promises never to err in. The revert leaves the proposal exactly where a `MaxNetOutflowExceeded` revert leaves it today: execute-leg breach → proposal stays `Approved`, expires at `executeBy` (self-healing); settle-leg breach → stuck `Executed`, owner rescue via the emergency path — which is why the emergency path must accept empty caps (below), or the rescue could brick on the same declaration that stranded the proposal.

**Empty caps skip per-call metering** (`caps.length == 0`); non-empty wrong-length reverts `CapsLengthMismatch`. The empty form exists for exactly one caller class: owner-supplied emergency calls (`finalizeEmergencySettle`), which have no propose-time declaration to enforce and are independently bounded by guardian review, the owner bond, and the batch-level `maxCapital` meter. `unstick` is NOT in that class — it replays the voted settlement calls, so it passes the stored settlement caps. Pre-fix stored proposals cannot exist (no deployment), so no compatibility branch for capless stored proposals is needed.

**`simulateBatch`** gains the same `(asset, caps)` parameters and reports per-call outflow in `CallResult` (fields appended), so proposers can size caps from a fork/eth_call dry-run instead of guessing. Breaking for any off-chain consumer of the old signature — acceptable alongside the `executeBatch` break; the single known consumer is the team's own tooling.

## D4 — The vault's batch-level meter is a different accounting layer and does not move

**The answer to design question 6, precisely:** per-call metering moves ENTIRELY into `BatchExecutorLib`; `SyndicateVault.executeGovernorBatch`'s own single before/after snapshot (:475, :491, :509-510) is retained UNCHANGED in semantics, as are the queue-reserve and buffer checks that hang off the same `balanceAfter` read. The two layers must not be conflated:

| | Vault meter (existing) | Lib meter (new) |
|---|---|---|
| Unit | NET outflow of the whole batch | GROSS outflow of each call |
| Bound | `maxCapital` (proposal envelope) | `caps[i]` (per-call declaration) |
| Serves | Custody ceiling; queue-reserve seniority; idle buffer | Coverage attribution (the number guardians priced) |
| Present when | Every batch, including empty-caps emergency batches | Only when caps are supplied |

Neither implies the other. The lib meter is not a superset: it does not run on empty-caps batches, and the reserve/buffer checks are about LP seniority, not coverage. The vault meter is not a superset either: it cannot attribute outflow to calls (that blindness is the bug). Keeping both also keeps two independent implementations of "money left custody" — a lib bug (the delegatecalled, redeployable component) is still caught at the batch level by code compiled into the vault. The vault-side change is plumbing only: accept `callCaps`, forward `(calls, asset(), callCaps)` in the `abi.encodeCall`, keep everything after the delegatecall byte-for-byte.

Mathematical note for reviewers: when caps are supplied, batch net outflow ≤ Σ per-call gross outflows ≤ Σ caps ≤ maxCapital, so on a correctly-metered batch the vault meter cannot fire first. Do not "optimize" it away on that observation — the inequality holds only while both implementations are correct, which is the point of having both, and the vault meter is the ONLY meter on empty-caps batches.

## D5 — The shared-singleton migration is designed, not footnoted

`BatchExecutorLib` is documented "Deploy once, share across all syndicate vaults" (:16). Three couplings make its ABI change a migration rather than an edit:

1. **The vault pins the lib by codehash** (`_expectedExecutorCodehash`, stamped at `initialize`, re-verified before every delegatecall, :473). A new lib is a new address AND a new codehash.
2. **Both references are init-only today.** `SyndicateVault._executorImpl` is written only in `initialize` (:256-257) — there is NO re-point path. `SyndicateFactory.executorImpl` is written only in the factory's `initialize` (:268) — no setter. An already-deployed factory can never hand new vaults a new lib, and an already-deployed vault can never follow one. This is the operational gap the migration must add primitives for.
3. **The ABI change is tri-lateral.** Governor → vault (`executeGovernorBatch` signature) and vault → lib (`executeBatch` signature) change together. A mixed pairing fails CLOSED at the first batch: a new-ABI vault delegatecalling the old lib (or vice versa) reverts on the unknown selector — the lib has no fallback. Note the codehash check does NOT catch mis-pairing by itself: a stale stamp with the stale lib passes the hash check and then reverts on selector. Fail-closed means no fund risk, but a vault in that state cannot execute, settle, or emergency-settle (all three route through `executeGovernorBatch`) until re-pointed — mis-sequencing bricks the strategy surface, recoverably but loudly. LP deposit/withdraw/queue paths never touch the executor and are unaffected.

**New primitives (this change):**

- `SyndicateFactory.setExecutorImpl(address newImpl)` — factory-owner-only, nonzero, takes effect for vaults created afterwards (`createSyndicate` reads the live `executorImpl`, :332). The factory is deployed and UUPS; this is code-only (the `executorImpl` slot exists; golden label untouched).
- `SyndicateVault.setExecutorImpl(address newImpl)` — factory-only (`msg.sender == _factory`), re-points `_executorImpl` AND re-stamps `_expectedExecutorCodehash = newImpl.codehash` atomically (the pair must never be written separately), rejecting zero and codeless targets. Reached via `SyndicateFactory.pushExecutor(vault)` — factory-owner-only, mirrors `pushWiring`'s shape (verifies the vault is factory-deployed via the `governorOf` round-trip), pushes the factory's current `executorImpl`, and requires the vault's governor lifecycle quiet (`getActiveProposal() == 0 && openProposalCount() == 0`, the same two gates `rotateOwner`/`upgradeVault` use) — a re-point under a live proposal would swap the meter out from under stored, coverage-priced calls.

**Operational sequence for a live deployment** (testnet 46630 today; mainnet 4663 has nothing deployed, so its "migration" is just deploying current code):

1. **Quiesce**: settle/expire all proposals on every vault (`openProposalCount == 0` everywhere). The lifecycle gate on `pushExecutor` enforces per-vault what this step does globally.
2. **Deploy** the new `BatchExecutorLib` singleton; record address + codehash.
3. **Upgrade implementations together, before any re-point**: governor beacon `upgradeTo(newGovernorImpl)` (atomic for all governors) and, per vault, `upgradeVault(vault, newVaultImpl)` (creator-consented, lifecycle-gated). Order within this step is free — every pairing of new impls with the OLD lib fails closed, and step 1 guarantees nothing needs to execute during the window.
4. **Re-point**: `factory.setExecutorImpl(newLib)`, then `factory.pushExecutor(vault)` for each existing vault (re-points + re-stamps codehash in one tx per vault).
5. **Verify before re-opening**: per vault, assert the executor address and codehash match the deployment record, and prove the selector chain end-to-end with a `simulateBatch` dry-run through the vault path (eth_call) or a canary propose→execute on a test vault.
6. New syndicates created after step 4 wire the new lib automatically.

**What breaks if a vault is NOT migrated**: nothing silently — its next `executeGovernorBatch` (from its post-upgrade governor) delegatecalls the old lib with the new selector and reverts; strategies are unavailable until `pushExecutor` runs; funds and LP exits are unaffected. **Compatibility shim considered and REJECTED**: keeping an old-signature `executeBatch(Call[])` on the new lib would let a mis-wired pairing "work" with unmetered batches — a silent downgrade of the exact guarantee this change ships. Fail-closed-until-rewired is the correct failure mode; the old selector is not retained anywhere.

## D6 — Composition with #118 (propose-time target validation)

Read from `fix/issue-118-propose-target-validation` @ `69461c0` (unmerged; this change lands after it): #118 adds `_rejectPrivilegedTargets(vault, executeCalls, settlementCalls)` in `propose`'s cheap-validation block (after `TooManyCalls`, before any state write), consuming the vault's new single-sourced `isPrivilegedBatchTarget` view via a degrade-open staticcall probe.

This change **adds no target validation and touches none of #118's** — the two propose-time checks are disjoint in subject (call TARGETS vs call CAPITAL), in data source (vault predicate via staticcall vs pure calldata arithmetic + the tier-registry scan), and in failure mode (#118 degrades open on a predicate-less vault; cap validation never degrades — it depends on nothing optional). They compose as SIBLING helpers in the same validation region:

```
TooManyCalls cap                       (bounds every loop below)
→ _rejectPrivilegedTargets(...)        #118 — degrade-open staticcall probe
→ cap-array length + per-batch sums    this change — pure calldata, new private helper
→ ... existing envelope checks ...
→ _snapshotTierAndGate(...)            this change extends: per-call coverage sum + tier-2 ceiling inside the ONE registry sweep
```

Ordering between the two new validation helpers is observability-only (which error a doubly-invalid proposal reports first); the spec pins neither. What this change must NOT do: fold cap validation into #118's loop (different degrade semantics — a vault without the predicate view must skip target checks yet still get full cap validation), or re-probe `isPrivilegedBatchTarget` (caps never consult the vault). The spec-delta text for "Proposal creation validation" incorporates #118's paragraph so that whichever change archives second does not clobber the other's requirement text; if #118's final merged wording differs, reconcile at archive time.

**#151** (deletes `selfManagesFees`; agreed order #147 → #118 → #151 → #43) edits `propose`'s snapshot block and the `StrategyProposal` struct's pre-append region — no shared lines with this change's edits (validation block, `_snapshotTierAndGate`, appended mappings, batch threading). Rebase-order only; if #151 regenerates the governor layout golden first, this change's regen is a second append on top. No semantic interaction: caps do not read fee snapshots.

## D7 — The interface #27 will consume (recorded so its spec does not rediscover it)

#27 (held pending #154; do not assume it proceeds) will size a proposal down to the coverage actually raised instead of reverting. After this change, that means distributing a proposal-level shortfall multiplier back across per-call caps. Everything it needs is left in place:

1. **Read the caps**: `getCallCaps(uint256 proposalId) external view returns (uint256[] memory executeCallCaps, uint256[] memory settlementCallCaps)` — the stored, immutable propose-time declarations.
2. **The linearity property** (the load-bearing fact): `requiredCoverage` is linear in the cap vector — `coverage(s·caps) = s·coverage(caps)` in the reals, and with floor rounding `coverage(⌊s·caps⌋) ≤ s·coverage(caps)`. Pro-rata scaling of caps scales coverage by the same factor, never upward. #27's shape: given `haveUsd < requiredCoverage`, compute per call `effectiveCap_i = cap_i * haveUsd / requiredCoverage` (floor) and `effectiveMaxCapital = maxCapital * haveUsd / requiredCoverage` (floor). Rounding edge recorded here so #27's spec handles it explicitly: term-wise floors do not automatically satisfy the batch bound relative to the floored `effectiveMaxCapital`, so #27 must re-assert `Σ effectiveCaps ≤ effectiveMaxCapital` after rounding (or clamp the largest term). A cap that floors to zero disables that call's outflow entirely — fail-closed and correct (the raised coverage did not fund it).
3. **The plumbing is parameter-shaped, not recomputed downstream**: caps flow governor → `executeGovernorBatch(calls, callCaps, maxNetOutflow)` → lib as ARGUMENTS of each batch invocation. The vault and lib never read proposal storage. #27 therefore changes only WHAT NUMBERS `executeProposal`/`settleProposal` pass (scaled instead of stored) plus its own ledger-side change (`requireApproveQuorum` returning `haveUsd` instead of reverting — `ExposureLedger`, out of this change's scope). Zero new plumbing.
4. **Settlement-symmetry warning**: if #27 scales the execute leg it must scale the settlement caps by the SAME factor and persist that factor at execute (the settle batch may run weeks later; recomputing from live ledger state at settle would re-size a batch voters already priced). This change deliberately leaves a clean place for it: appended governor storage, same discipline as the caps mappings.

## Risks

- **`propose`'s Yul stack budget.** The function is documented at the edge (four separate hoisting comments; repo guardrail history of "too deep by 1 slot"). Two new calldata params + threading is real pressure. Mitigations, in order: (1) store caps to their mappings immediately after `_storeCalls` and let later stages read storage (the established `_loadCalls` idiom — `_snapshotTierAndGate` already takes only `(p, execCalls)` and loads the rest itself; extend it to load caps the same way); (2) all new validation in private helpers, mirroring `_checkMaxCapitalCeiling`; (3) if still over, fold the length/sum checks into the helper that stores the caps (validate-while-storing). Tasks order the build so this surfaces at the first compile checkpoint, not after the test sweep.
- **The exotic-asset residual gets cheaper, and that must be said out loud.** Today an asset-invisible tier-2 call (ERC721 `setApprovalForAll`, ERC1155, LP-position NFTs — outside the vault's guarded ERC20 selector set, per `_guardBatchCalls` RESIDUAL, SyndicateVault.sol:573-578) is economically backstopped by full-notional pricing: it costs `maxCapital` of coverage. After this change it costs `cap_i`, and a proposer can honestly declare `cap_i = 0` because such a call moves no `asset()`. The extraction routes are unchanged (the meter never saw these flows; the selector guard still doesn't); the ECONOMIC deterrent shrinks. This is the approved design's accepted consequence — pricing extraction at declared notional is the entire point — and the codebase's stated plan for exotics is guarding their selectors as adapters onboard. Carried into the spec delta as a hard precondition (exotic-asset adapters MUST NOT be certified or allowlisted before their selectors join the guarded set) and flagged for a follow-up issue to add ERC721/1155 selectors before any NFT-position adapter onboards.
- **Coverage can now be zero with a wired registry** (all-zero caps — D2). Sound per the extractable-value doctrine, but it flips the :438-441 natspec from "defensive, not reachable" to reachable — update the comment, pin with a test, and note the exotic residual above as the one caveat.
- **Test blast radius.** Every `propose(...)` and `executeGovernorBatch(...)` call in `test/` breaks on arity. Mitigation: the shared fixtures/helpers (`GovEnvelope`, the lifecycle harnesses) absorb the new arguments with ONE documented default — suggested: `caps = [maxCapital, 0, 0, ...]` per array (sum-legal for any batch, permissive for single-mover batches) — so leaf tests change only where caps are the subject. Beware the repo's argument-position-call gotcha (`vm.prank` consumed by an argument evaluation) when mechanically rewriting call sites. Budgeted as its own task section with a compile checkpoint before it.
- **Migration mis-sequencing** (D5): every mixed pairing fails closed; the risk is availability, not funds. The `pushExecutor` lifecycle gate plus step-5 verification bound it. Testnet 46630 is the rehearsal.
- **Coverage economics downstream**: smaller `requiredCoverage` means smaller risk-scaled proposer bonds (`proposerBondWood(asset, coverage)`) and more headroom under the covered-TVL cap — both intended (the bond and the cap were pricing the over-count too). Called out so nobody reads the bond drop as a regression. `ExposureLedger` itself is untouched: it consumes the coverage figure opaquely (`requireWithinCoveredTvlCap`, `requireApproveQuorum`, `proposerBondWood`); grep confirms no dependency on `_effectiveTotal` or any #154-affected machinery from this change's files.
