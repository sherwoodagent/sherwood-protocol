# Codehash-Class Certification

## Why

Every strategy proposal deploys a fresh clone at a fresh address. Both of the registry's consent axes are keyed by address, so the protocol owner must bless each clone by hand, once per proposal, forever:

- `setAdapterAllowed(clone, true)` — without it the vault's callee gate (`SyndicateVault.sol:981`) rejects the batch outright. This is a hard block on execution, not a cost.
- `certify(clone, selector, …)` — without it the clone reads as tier 2, which carries two penalties: coverage priced at full notional, and a hard per-call cap of `totalAssets() × tier2CallCapBps()` enforced by `SyndicateGovernor._scanCalls` (`Tier2CallCapExceedsCeiling`).

The result is a manual owner action in the middle of an otherwise automated agent flow, and — when it is skipped, which is the realistic case — every strategy runs smaller and consumes more coverage capacity than its code warrants.

**The clones are not distinct contracts.** `StrategyFactory` uses `Clones.clone`, which deploys the standard ERC-1167 minimal proxy: a 45-byte runtime `363d3d373d3d3d363d73 ‖ <template> ‖ 5af43d82803e903d91602b57fd5bf3`. Every clone of a template is byte-identical, so they share one `EXTCODEHASH`, and that codehash embeds the template address. A matching codehash is therefore self-verifying on-chain proof that an address is a clone of a specific, owner-approved template — no factory hop, no proposer-supplied claim, no trusted intermediary.

The registry already computes and stores codehashes; it uses them as a freshness check on address-keyed records. This change promotes the codehash from freshness check to primary key, for entries that opt into it.

## What Changes

- **`TierRegistry` gains class entries.** A class is keyed by a code fingerprint rather than an address. Certifying a class attests a tier and `extractableBoundBps` for *any* address whose runtime code hashes to that fingerprint. Class entries carry the template address and the template's codehash so membership can be verified at two levels (see below).
- **Both read paths gain a class fallback.** `isAdapterAllowed(target)` and `tierOf(target, selector)` keep their existing address-keyed lookup and, on a miss, check class membership. Address entries continue to win; nothing about the current path changes.
- **Two-level membership check.** An address is a member when its live `EXTCODEHASH` equals the ERC-1167 codehash derived from the certified template **and** the template's own live `EXTCODEHASH` still equals the codehash snapshotted at certification. The first level proves "clone of T"; the second catches in-place mutation of T, which the clone's own codehash cannot see because it embeds T's address, not T's code.
- **A governance-discipline requirement on class certification.** Certifying a class asserts a bound that holds under *every* initialization, not just one deployment's configuration. Governance SHALL only class-certify templates that bind every init-supplied external address to the registry allowlist at initialization, or hold it immutable in the template's own bytecode. `MorphoSupplyStrategy` does not qualify, because its Morpho singleton arrives in init data and is then interrogated as its own validator.
- **A token↔price-source attestation axis, and the `PortfolioStrategy` fix that needs it.** Auditing `PortfolioStrategy` against the conformance bar (task 6.1) showed it binds its swap adapter and its price sources but never checks that a slot's feed describes that slot's *token*. A valuable token paired with a cheap asset's allowlisted feed produces a minimum-output floor computed off the wrong reference, so a trade can bleed value while every slippage check reads as satisfied. This is not a live defect — per-clone owner review closes it today — but class certification is precisely the removal of that review, so the template cannot carry a class claim until the pairing is enforced in code. `TierRegistry` therefore gains `setPriceSourceForToken` / `isPriceSourceForToken`, and `PortfolioStrategy` enforces the pairing per slot in both price modes. The pairing must be *attested* rather than derived: `AggregatorV3` exposes no on-chain link from a feed to the asset it prices, and Chainlink's Feed Registry is not deployed on Robinhood Chain.
- **A prohibition on per-clone immutable args.** Clone variants that write per-instance data into the clone's bytecode give every clone a distinct codehash and dissolve the class. Templates intended for class certification SHALL be cloned with `Clones.clone` / `cloneDeterministic` only.
- **Demotion extends to classes.** The existing demotion paths and the permissionless persistence path apply to class entries, with the same one-way, fail-closed coupling: demoting a class clears its allowlist standing, and re-certifying never restores it.

**BREAKING**: none. Class entries are additive and opt-in; every existing address-keyed certification, allowlist grant, and demotion behaves exactly as before.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `tier-policy`: class-keyed certification as a second keying mode alongside `(target, selector)`; the two-level membership check; class fallback in both `tierOf` and `isAdapterAllowed`; demotion semantics for classes; the token↔price-source attestation axis; and the governance-discipline requirements governing which templates may be class-certified and how they may be cloned.
- `operator-docs`: `docs/adapter-onboarding-checklist.md` gains the class-certification procedure (eligibility bar, the three writes, verification reads, rollback) and the statement that clone-init deploy order is load-bearing.

## Impact

**Touched code**
- `src/TierRegistry.sol` — class storage, class certification and demotion entry points, class fallback inside `tierOf` and `isAdapterAllowed`, the ERC-1167 codehash derivation helper, and the token↔price-source attestation axis.
- `src/strategies/PortfolioStrategy.sol` — per-slot token↔feed pairing enforcement in both price modes, a new error, and one added selector on the locally-declared `ITierBindingPath`. This is a **live template**: the added check runs at `initialize`, so it changes what configurations are accepted going forward and requires redeploying the template (clones bind their implementation at creation and cannot be upgraded).
- Four test registry stand-ins gain the new selector. A stand-in that resolves but lacks it makes `_requireAllowedPriceSource` revert rather than degrade, so they must be patched in the same commit.
- `src/interfaces/ITierRegistry.sol` — unchanged read surface. `tierOf` and `isAdapterAllowed` keep their exact signatures; the class fallback is internal to the registry, which is why neither the vault nor the governor needs a code change.
- `test/` — a class-membership suite (positive, negative, two-level staleness, demotion), plus coverage that address entries still take precedence.

**Untouched**
- `src/SyndicateVault.sol` and `src/SyndicateGovernor.sol` — both consume the registry through the existing two reads and inherit class support for free.
- `src/StrategyFactory.sol` — no provenance mapping is added. Class membership is proven from bytecode, not from factory records, deliberately: it avoids a second source of consent and keeps the registry the single root of trust, consistent with the argument in `target-based-batch-gating`.

**Operational**
- One-time class certification per template replaces per-proposal address ceremony. `PortfolioStrategy` is the first eligible template.
- The `_authClone` permission gate in `StrategyFactory` stops being enforced for class membership — anyone may clone an approved template directly and inherit the class. Analyzed as granting no additional capability (a clone is inert unless a proposal names it, and that proposal still passes vote and guardian review), but it is a deliberate loosening, not an oversight.

**Explicitly out of scope**
- Retrofitting `MorphoSupplyStrategy` to pin or allowlist-bind its Morpho singleton. That changes a deployed template's initialization ABI and warrants its own change; until then it remains address-certifiable only. Note the asymmetry with the `PortfolioStrategy` work above, which is in scope: the pairing check is additive validation inside an unchanged init signature, whereas fixing `MorphoSupplyStrategy` means removing a parameter from its init tuple.
- The degrade-open branch in the templates' address binding (`if (registry == address(0)) return;`). It is a stated exception to the class guarantee here, not a fix — see design.md.
