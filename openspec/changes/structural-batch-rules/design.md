## Context

Batches execute under `delegatecall`, so every sub-call carries `msg.sender == vault`. The guard's job is to make the set of things a batch can do to the vault's custody a closed, small set that the outflow meter and the tier price can see. The previous design tried to do that by recognising calldata shapes (selectors + argument offsets) and by asking the registry whether the target and the decoded recipient were blessed. This design replaces recognition with structure.

## Goals / Non-Goals

- Goals: anyone can write a strategy; a proposal may call any contract with any calldata; capital leaves the vault only through an allowance a callee pulls inside the batch; nothing a batch grants survives the transaction; the registry prices, it does not admit.
- Non-Goals: protecting non-asset positions the vault holds (a position token is a strategy's business and the guardian's judgement); native value (the vault holds none); proxy-implementation swaps under a counterparty entry (unchanged caveat).

## Decisions

### D1 — Four rules, in this order

1. Privileged-target denylist, every call, before anything else. The set is every protocol contract the vault can resolve from its own wiring: itself, its queue, its factory, its governor, the governor's tier registry, that registry's `strategyFactory`, the governor's exposure ledger, that ledger's `coverageFreezer` (the challenge game), the governor's guardian registry and its `swood`. Resolution is fail-soft (a missing getter reads as `address(0)`, which is never a target) so a stand-in governor without every getter still executes; nothing in the set is owner-extensible, so the set is fixed by deployment wiring.
2. `target == asset()` admits exactly `approve(address,uint256)` with at least 68 calldata bytes; any other selector or shorter calldata reverts `DisallowedAssetSelector(sel)`. This covers `transfer`, `transferFrom` (including the LP-allowance-confiscation shape, whose only standing allowance is on the asset), `permit`, `increaseAllowance`, `transferAndCall`, `authorizeOperator` and every future sibling without naming any of them.
3. Every spender approved in the batch is collected in memory and `forceApprove(spender, 0)`'d after the delegatecall returns, before the meters. A spender that did not pull loses the allowance; a spender that pulled has already been metered. A spender equal to the asset or the vault is reset the same way — an `approve(x, 0)` is harmless for any `x`. Duplicates are reset twice.
4. Everything else is admitted. Admission is not endorsement: `tierOf` prices an unknown `(target, selector)` at tier 2 with `boundBps == 10_000`, so uncertified code costs full-notional coverage and a bond.

The meters (`maxNetOutflow`, `reservedQueueAssets`, buffer floor) run after the reset, unchanged.

### D2 — The rejected `vault() == this` predicate

A callee-side check ("only call contracts that answer `vault()` with this vault") was considered as a cheap way to keep batches inside strategy code. Rejected: a contract that answers the predicate and then calls Morpho reaches the identical outcome, so the predicate constrains nothing an attacker does and only taxes honest direct-protocol batches. The same argument retires the callee allowlist: any allowlisted contract that forwards calldata is an unallowlisted target with one extra hop.

### D3 — Why no source guard on non-asset tokens

The old `transferFrom` source guard protected the LP deposit allowance, which is on `asset()`; rule 2 refuses `transferFrom` on the asset outright. A `transferFrom(x, vault, n)` on some other token spends an allowance nobody grants the vault in the normal course of use; if a token holder did, the guardian reads the batch. Enumerating source-bearing selectors on arbitrary tokens is exactly the shape this change removes.

### D4 — Emergency batches

`emergencySettleWithCalls` → `finalizeEmergencySettle` → `executeGovernorBatch` runs the same guard. No exemption (the owner is not more trusted than the governor for custody) and no extra restriction (the emergency path must be able to reach whatever a strategy reached).

### D5 — Registry: pricing and template binding only

Deleted: `_adapterAllowed`, `_adapterAllowedCodehash`, `_calleeAllowed`, `_calleeRevoked`, `_classAllowed`, `_classCalleeAllowed`, `_classAllowDenied`, and every setter/getter/event over them. Kept: address and class certification with their timelocks, epochs, bonds and demotion; `isCounterpartyAllowed` (now a pure counterparty flag with its grant-time codehash snapshot — the adapter fallback is gone); `isPriceSourceForToken`; `classOf`; `strategyFactory`. `_demote` still clears the counterparty entry (a convicted venue should not be bindable by a template), still deletes the tier config, and no longer writes any callee or allowlist state. `_demoteClass` clears only the class config.

### D6 — Templates bind venues as counterparties

`MorphoSupplyStrategy` (Morpho singleton), `PortfolioStrategy` (swap adapter, each price feed) and `ConcentratedLiquidityStrategy` (swap adapter; the rest already were) read `isCounterpartyAllowed` through the same fail-closed raw staticcall shape. `PortfolioStrategy` keeps the per-token `isPriceSourceForToken` pairing. The owner's ceremony is one call per venue, `setCounterpartyAllowed(venue, true)`.

### D7 — Factory: clone is permissionless, the vault must exist

`_authClone`'s owner/agent gate and the `Unauthorized` error are deleted. The `vaultToSyndicate(vault) != 0` check stays: a clone's `initialize` walks `vault() → governor() → tierRegistry()`, and `cloneTemplate` provenance is what makes a clone a class member for pricing, so provenance should only ever name real vaults. `proposer == msg.sender` stays. Note that anyone may now mint a class-member clone bound to any vault; the clone can only be executed by that vault's governor, through a proposal its agents write, priced at the class's tier — the tier is a property of the code, not of who deployed it.

### D8 — Storage

`SyndicateVault` and `SyndicateGovernor` delete only constants, private functions and errors; no slot moves, goldens unchanged. `TierRegistry` is constructor-deployed (no proxy, no golden), so its mappings are deleted freely.

## Risks / Trade-offs

- A proposal may now `approve` the asset to any contract and call it. That is the design: the price is tier 2 on that call, and the reset guarantees the approval cannot be used after the batch. What the guard no longer promises is that the callee is known; the guardian review is where that judgement lives.
- Non-asset tokens the vault holds between execute and settle can be moved by a settlement batch to anywhere. Previously the recipient allowlist bounded this; now the tier price and the guardian do. Recorded as accepted.
- The privileged set is resolved live at each batch (≈10 warm reads). Cheap relative to the batch itself; the alternative (storing the set) would need a wiring hook on every rotation.

## Migration

Fresh deployment. Any address previously `setAdapterAllowed` for a template binding is re-seeded with `setCounterpartyAllowed`; nothing else migrates.
