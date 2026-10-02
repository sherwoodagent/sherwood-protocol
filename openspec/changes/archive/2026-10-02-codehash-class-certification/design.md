## Context

See `proposal.md` — Why. Requirements are in `specs/tier-policy/spec.md`.

The constraints that shape the approach:

- `StrategyFactory` clones with OpenZeppelin `Clones.clone` (OZ 5.6.1), producing the standard ERC-1167 runtime: `363d3d373d3d3d363d73 ‖ <template:20> ‖ 5af43d82803e903d91602b57fd5bf3`, 45 bytes. Deterministic from the template address alone.
- `TierRegistry` already snapshots and re-checks codehashes on both axes (`tierOf`'s lazy demotion, `isAdapterAllowed`'s grant-time snapshot). Codehash reasoning is established here, not new.
- Both consumers reach the registry through exactly two reads — `tierOf(target, selector)` and `isAdapterAllowed(adapter)` — declared in `ITierRegistry`. `SyndicateVault._guardBatchCalls` runs the second per sub-call; `SyndicateGovernor._scanCalls` runs the first per sub-call at propose time.
- `SyndicateGovernor.propose` stores `p.strategy = strategy` unvalidated; `test_propose_eoaStrategySucceedsAtPropose` pins that an EOA is accepted. Nothing about a proposal's declared strategy is evidence of provenance.
- `PortfolioStrategy._initialize` already binds every init-supplied external address to the allowlist. `MorphoSupplyStrategy._initialize` does not — its `morpho_` singleton arrives in init data and is interrogated as its own validator.

## Goals / Non-Goals

**Goals:**
- Remove the per-proposal owner action without introducing a second source of consent.
- Keep the existing address path bit-for-bit unchanged, so the change cannot regress anything already certified.
- Make class membership provable from chain state alone — no trusted intermediary, no proposer-supplied claim.

**Non-Goals:**
- Changing `ITierRegistry`, the vault, or the governor. If either consumer needs a code change, the design has failed.
- A factory-provenance registry (`clone → template`). Explicitly rejected, see Decision 1.
- Retrofitting `MorphoSupplyStrategy`. Out of scope by the proposal; it stays address-certifiable.
- Changing the degrade-open posture at rebalance or settle. Only `_initialize` becomes fail-closed; see Decision 5.

## Decisions

### Decision 1: Prove membership from bytecode, not from provenance

Class membership is decided by hashing the target's runtime code and comparing against a value derived from the certified template address. Nothing else is consulted.

This is what lets the read stay inside `TierRegistry` and keeps `ITierRegistry` frozen — and it is why the vault and governor inherit class support for free. It also means the check is total: it works for a clone the factory made, a clone someone made directly, and a clone made before the class was certified.

*Alternative considered — ask `StrategyFactory` for provenance.* Rejected on three counts. It puts a cross-contract hop in the vault's per-sub-call hot path; it makes the factory a security dependency for a boundary the registry owns; and it mints a second source of consent, which is precisely what `target-based-batch-gating` argued against when it chose to reuse `isAdapterAllowed` rather than create a parallel allowlist.

*Alternative considered — verify a CREATE2 address prediction.* Rejected: the salt is not recoverable from an address, so the verifier cannot reconstruct the prediction without the caller supplying the salt, which reintroduces a proposer-supplied claim.

### Decision 2: Do not exempt the proposal's declared strategy

The tempting shortcut is to exempt `strategyOf(activeProposal)` from the vault's callee gate the way `asset()` is exempt. It is unsound: `propose` never validates the strategy address, so the exemption would let any proposer name any contract and have the vault reach it carrying vault identity.

Worth recording because the shortcut looks attractive and someone will suggest it again. The reason it fails is instructive — `strategyOf` is a label, not a provenance claim — and it is exactly the gap Decision 1 fills.

### Decision 3: Class is a fallback; address always wins

Lookup order is address entry first, class second. Three reasons: existing behavior is preserved by construction; an owner retains a per-address override to demote or re-price one misbehaving clone without touching the class; and the hot path pays for the class check only on an address miss.

### Decision 4: Two-level codehash check, and level 2 is not optional

A clone's codehash is a function of the template's **address**. Mutate the template's code in place and every clone's codehash is unchanged while every clone's behavior changes. So the class entry snapshots the template's codehash at certification and every read re-verifies it.

Without level 2 this design would be strictly weaker than the address path it extends — the address path's whole metamorphic defense would be lost, multiplied across every clone. With it, the design is strictly stronger: under class keying there is nothing to demote, because mutated code simply is not in the class.

### Decision 5: Initialization is fail-closed on the registry — and only initialization

`PortfolioStrategy`'s binding helpers return early when the registry is unresolvable:

```solidity
address registry = _resolveTierRegistry();
if (registry == address(0)) return;
```

That is a hole in the class guarantee. A clone initialized while the registry was unreachable carries an adapter, price sources, and token↔feed pairings that were never checked against governance, yet still inherits the class bound from its codehash. Initialization and execution are different transactions, so "the registry answered at certification time" does not imply "it answered at init."

Survivable today, because every clone is individually allowlisted by the owner before it can be called — a human reads the configuration first. Not survivable under class certification, whose entire claim is that the bound holds under *every* initialization.

**Resolution: `_initialize` reverts `TierRegistryUnresolved` when the registry cannot be resolved.** This became available once `PortfolioStrategy` was confirmed for full redeployment; an earlier draft of this document deferred it as too invasive for a template already in production, which no longer applies.

Scoped deliberately to init. The shared helpers are **not** changed, because they also run at rebalance and settle where the balance genuinely inverts: blocking those would strand vault capital behind a revert, and the file already documents that liveness there outweighs a stale binding. Gating at init instead of inside the helpers keeps that posture exactly as it was — at init the registry is now guaranteed non-zero, so the helpers' early return is simply unreachable there.

*Cost accepted:* deploy order becomes load-bearing. The registry must be wired and reachable through `vault() → governor() → tierRegistry()` before any clone is initialized, or every clone deploy reverts. That is a real operational constraint and belongs in the runbook.

*Alternative considered — fail closed only on the new pairing check.* Rejected: it leaves two checks that skip and one that reverts inside one function, an asymmetry with no principle behind it that the next reader would have to reverse-engineer.

### Decision 5a: The token↔price-source pairing is attested, not derived

Auditing `PortfolioStrategy` against the conformance bar showed it binds its adapter and its price sources but never checks that a slot's feed describes that slot's token. The obvious fix — ask the feed what it prices and compare — does not exist on-chain: `AggregatorV3.description()` is a human-readable string, and Chainlink's Feed Registry, which does expose `getFeed(base, quote)`, is not deployed on Robinhood Chain.

So the pairing is an owner attestation in `TierRegistry`, keyed `(token, bytes32 priceSource)`. Carrying the source as `bytes32` lets one mapping serve both price modes: a push aggregator widened from its address, or a Data Streams feed id verbatim. Push mode strips the packed max-age before lookup, so one attestation covers an aggregator regardless of the staleness bound a proposer picked for a given slot — otherwise every max-age variant would need its own attestation and operators would paper over that by attesting broadly.

*Alternative considered — infer the pairing from the swap quote.* Compare the oracle price against what the adapter quotes and reject on divergence. Rejected: it makes the guard depend on live pool state, which is the thing the oracle exists to be independent of, and a manipulated pool would then be able to reject honest configurations.

*Why this is in scope at all:* the gap is not a live defect. Per-clone owner review closes it today. Class certification is precisely the removal of that review, so the template cannot carry a class claim while the gap exists — the mechanism and the fix have to land together or the mechanism has nothing eligible to certify.

*Note on the Data Streams asymmetry:* in push mode each slot's aggregator is separately allowlisted, so the price-source allowlist acts as an indirect token allowlist and the pairing check tightens an already-real constraint. In Data Streams mode only the verifier is allowlisted and feed ids are opaque, so the pairing is the **only** thing tying a slot's report to a slot's token. The check matters more there, not less.

### Decision 6: The per-clone-immutable-args prohibition is a spec requirement, not a comment

Pinning a template's external addresses is the fix for conformance (Requirement: "Only conformant templates may be class-certified"), and the ergonomic way to pin them per clone is clone-with-immutable-args. That would give every clone a distinct codehash and dissolve the class.

The failure mode is what makes this spec-worthy rather than a code comment: nothing reverts. Proposals keep executing, having silently fallen back to tier 2 — more coverage consumed, per-call cap reinstated, no error anywhere. A quiet regression to the status quo is the hardest kind to notice, so the constraint is written as a requirement with its own scenario.

## Risks / Trade-offs

- **A class certification is a much stronger claim than an address certification, and the codebase contains a template that cannot honour it.** → The conformance requirement makes eligibility explicit, and `MorphoSupplyStrategy` is named in the spec as ineligible rather than left to be discovered. The precedent that the rule is satisfiable is `PortfolioStrategy`, which already implements it.
- **Blast radius multiplies.** A wrongly-certified class vouches for every clone that will ever exist, not one address. → Class certification stays owner-only and bonded, demotion applies to classes, and the two-level check means template mutation revokes the whole class instantly.
- **Gas in the vault's per-sub-call hot path.** Up to two `EXTCODEHASH` (~2600 each cold) plus a storage read, on the address-miss branch only. → Measure before merging; the address path is unchanged, so the regression is bounded to calls that are failing the gate today anyway.
- **`StrategyFactory._authClone` stops being enforced for class membership.** → Analyzed as granting no capability: a clone is inert until a proposal names it, and that proposal still faces vote and guardian review. Recorded in the spec as a deliberate loosening so it is not mistaken for an oversight later.
- **Codehash collision.** → Not a practical risk at keccak256; noted only to be explicit that class identity rests on collision resistance.
- **A future migration off `Clones.clone`** — to any variant with per-instance bytecode — would silently disable every class. → Decision 6's requirement plus a test that pins the derived fingerprint against an actual factory-produced clone, so a clone-mechanism change fails a test rather than degrading quietly in production.

## Appendix: why `MorphoSupplyStrategy` stays ineligible

Recorded here so the follow-up change starts from evidence rather than re-deriving it.

`MorphoSupplyStrategy._initialize` decodes the Morpho singleton from init data and then validates the configuration **by asking that same supplied address**:

```solidity
(address morpho_, MarketParams memory mp, uint256 supplyAmount_) = abi.decode(...);   // :101
if (morpho_ == address(0)) revert ZeroAddress();                                       // :104
if (IMorpho(morpho_).market(id).lastUpdate == 0) revert MarketNotCreated();            // :111
morpho = IMorpho(morpho_);                                                             // :113
```

The guard at `:111` is real against a typo and useless against an adversary: a contract that answers `lastUpdate != 0` and reports a matching `loanToken` passes every check and then keeps the supplied funds. Extraction is 100% of `supplyAmount`, and it is a function of init parameters, not of the code — which is precisely the property class certification cannot tolerate.

Note this is **not** the same defect the `PortfolioStrategy` work fixed. There the addresses were bound but their *pairing* was not; here the address itself is unbound. The fixes differ accordingly:

- `PortfolioStrategy` — additive validation inside an unchanged init signature. In scope.
- `MorphoSupplyStrategy` — `morpho` must become `immutable` on the template (one template per Morpho deployment, which on a single chain is one template), which means **removing a parameter from the init tuple**. That is an ABI change to a deployed template and belongs in its own change.

Until then it remains address-certifiable: per-clone certification and per-clone allowlisting still work exactly as today, because the owner reviews each clone's configuration.

## Migration Plan

Additive and reversible. Deploy the registry upgrade; no class entries exist, so behavior is identical to today. Certify `PortfolioStrategy`'s class when ready; its clones become callable and tiered with no further action. Rollback is demoting the class, which returns every clone to the tier-2 default — the exact state they are in today, so rollback is never worse than the status quo.

Existing per-clone allowlist grants stay valid and keep winning over the class entry, so there is no cutover moment and no need to revoke anything.

## Open Questions

- Whether class certification should carry a longer `certifyDelay` than address certification, given the larger blast radius. Deferrable: it is a parameter choice on an existing mechanism and changes neither the requirements nor the task breakdown.
- Whether to expose a public view for the derived class fingerprint of a template, for operator tooling. Deferrable: additive read, no behavioral consequence.
