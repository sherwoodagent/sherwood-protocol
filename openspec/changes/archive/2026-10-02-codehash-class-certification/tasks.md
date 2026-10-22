## 1. Codehash derivation

- [x] 1.1 Add the ERC-1167 clone-codehash derivation to `TierRegistry` — `keccak256(abi.encodePacked(hex"363d3d373d3d3d363d73", template, hex"5af43d82803e903d91602b57fd5bf3"))` — with natspec pinning the byte layout and the OZ version it mirrors
- [x] 1.2 Pin the derivation against reality: a test that clones a template through `StrategyFactory` and asserts the derived value equals the clone's live `EXTCODEHASH`. This is the guard that makes a future clone-mechanism change fail loudly instead of silently dissolving every class
- [x] 1.3 Assert the derivation reverts (or is refused at certification) for a template holding no code

## 2. Class storage and certification

- [x] 2.1 Add class storage keyed by `keccak256(abi.encodePacked(cloneCodehash, selector))`, holding template address, template codehash snapshot, tier, and bound — in a namespace that cannot alias the address-keyed mapping
- [x] 2.2 Add the owner-only class certification entry point, reusing the existing bond and `certifyDelay` machinery rather than duplicating it
- [x] 2.3 Reject class certification of a codeless template
- [x] 2.4 Add class allowlist grant/revoke mirroring `setAdapterAllowed`, with the same one-way coupling (certification never sets or restores allowlist standing)

## 3. Read-path integration

- [x] 3.1 Add the class fallback to `tierOf`: address entry first, class second, tier-2 default last. `ITierRegistry` signature unchanged
- [x] 3.2 Add the class fallback to `isAdapterAllowed` on the same ordering
- [x] 3.3 Implement the two-level membership check — target codehash matches the derived class fingerprint AND template's live codehash matches the snapshot — as a shared internal helper used by both reads
- [x] 3.4 Confirm both reads remain `view` and write no state on any path

## 4. Class demotion

- [x] 4.1 Extend the demotion paths to class entries with the same converging effect as address entries
- [x] 4.2 Extend the permissionless persistence path to class demotions
- [x] 4.3 Confirm re-certifying a demoted class does not restore its allowlist standing

## 5. Tests

- [x] 5.1 Membership positive: a factory clone of a certified template reads the class tier and is allowlisted, with no per-clone action ever taken
- [x] 5.2 Membership negative: a look-alike contract implementing the same interface but not a minimal-proxy clone reads as uncertified
- [x] 5.3 Level-2 staleness: mutate the template's code at the same address; every clone reads `(2, 10_000)` and `isAdapterAllowed` returns false on the next read
- [x] 5.4 Precedence: a target both address-certified and class-member returns the address values; demoting the address entry does not disturb the class
- [x] 5.5 Clone created outside the factory is a class member — pin the deliberate loosening so a future reader sees it was intended
- [x] 5.6 Immutable-args clone reads as uncertified and raises no error — pin the quiet-failure mode from design Decision 6
- [x] 5.7 Class demotion: all member clones lose tier and allowlist standing together; re-certification does not restore the allowlist
- [x] 5.8 Namespace isolation: an address entry cannot be written or demoted through a class entry point, or vice versa
- [x] 5.9 Regression sweep: every existing `TierRegistry` test still passes unmodified — the address path must be bit-for-bit unchanged

## 6. Conformance and consumers

- [x] 6.1 Verify `PortfolioStrategy` binds every init-supplied external address to the allowlist, and record the audit in the change as the eligibility evidence — **FINDING: it binds the swap adapter and price sources, but NOT the token↔feed pairing. See group 9**
- [x] 6.2 Verify `MorphoSupplyStrategy` is correctly excluded — document the unbound `morpho_` as the disqualifying property so the follow-up change has its starting point
- [x] 6.3 Confirm `SyndicateVault` and `SyndicateGovernor` need no code change: run their existing suites against the upgraded registry with a class certified
- [x] 6.4 Measure gas on `_guardBatchCalls` for the address-miss branch and record the delta — **measured: address hit 2,486 gas, class fallback 4,988 gas, delta 2,502 gas paid ONLY on an address miss. Not a regression on any working path: the calls that pay it are the ones that revert today. Pinned by `test_gas_isAdapterAllowed_addressHitVsClassMiss`**

## 7. Deployment and docs

- [x] 7.1 Add the class-certification step to the deploy runbook, including that it replaces per-proposal `setAdapterAllowed(clone, true)` for conformant templates
- [x] 7.2 Document the rollback: demoting a class returns clones to the tier-2 default, which is the current production state, so rollback is never worse than status quo
- [x] 7.3 Verify `TierRegistry`'s runtime size against the 98,304-byte Robinhood limit — **11,334 B runtime, 86,970 B margin**

## 9. Token↔price-source pairing (scope added after 6.1's finding)

`PortfolioStrategy` binds its adapter and price sources but never checks that a
slot's feed describes that slot's token. A valuable token paired with a cheap
asset's allowlisted feed yields a minimum-output floor computed off the wrong
reference — the trade bleeds value while every slippage check passes. Held
closed today by per-clone owner review; class certification removes that review,
so the template cannot be class-certified until the pairing is enforced in code.

- [x] 9.1 `TierRegistry`: add the token↔price-source attestation axis — `setPriceSourceForToken(token, priceSource, allowed)` (owner) and `isPriceSourceForToken(token, priceSource)` (view), carrying the source as `bytes32` so one mapping serves both push aggregators and Data Streams feed ids
- [x] 9.2 `PortfolioStrategy`: extend the local `ITierBindingPath` selector interface and add `_isPriceSourceForToken` as a length-checked raw staticcall, mirroring `_isAdapterAllowed`
- [x] 9.3 `PortfolioStrategy`: enforce the pairing per slot in BOTH modes — push mode normalizes the packed feed id to the bare aggregator address so one attestation covers every max-age variant; Data Streams mode passes the feed id verbatim, where the pairing is the only thing tying a report to a token
- [x] 9.4 Add `PriceSourceNotPairedWithToken(token, priceSource, registry)` with natspec naming its adversary
- [x] 9.5 Patch every registry stand-in that resolves but would lack the new selector — 4 files; a resolvable registry missing it makes `_requireAllowedPriceSource` revert, not degrade
- [x] 9.6 `PortfolioStrategy._initialize` is fail-closed on registry resolution (`TierRegistryUnresolved`), gated at init only so rebalance/settle keep degrading open — confirmed available by the full-redeployment decision
- [x] 9.7 Tests: mismatched pairing reverts; correct pairing passes; both price modes covered; init reverts when the registry is unresolvable
- [x] 9.8 Wire a resolvable registry into the two suites that construct `PortfolioStrategy` without one (`test/PortfolioStrategy.t.sol`, `test/audit-fixes/Strategy_init_frontrun.t.sol`), and invert the skip-behavior assertions in `test/PortfolioStrategyAdapterAllowlist.t.sol`
- [x] 9.9 Decide and document whether `MorphoSupplyStrategy`'s exclusion still stands after this (it does — its unbound `morpho_` is a separate defect)
- [x] 9.10 Runbook: deploy order is now load-bearing — the tier registry must be wired and reachable before any `PortfolioStrategy` clone is initialized, or every clone deploy reverts

## 8. Verification

- [ ] 8.1 Run the full `forge test` suite and confirm no pre-existing suite regressed — compare against the baseline failure list, not against zero
- [x] 8.2 Run `forge fmt --check` with a forge matching CI
- [x] 8.3 Run `openspec validate codehash-class-certification --strict`
