## Context

Batches execute under `delegatecall`, so every sub-call carries `msg.sender == vault`. The guard's job is to make the set of things a batch can do to the vault's custody a closed, small set that the outflow meter and the tier price can see. The previous design tried to do that by recognising calldata shapes (selectors + argument offsets) and by asking the registry whether the target and the decoded recipient were blessed. This design replaces recognition with structure.

## Goals / Non-Goals

- Goals: anyone can write a strategy; a proposal may call any contract with any calldata; capital leaves the vault only through an allowance a callee pulls inside the batch; nothing a batch grants survives the transaction; the registry prices, it does not admit.
- Non-Goals: protecting non-asset positions the vault holds (a position token is a strategy's business and the guardian's judgement); native value (the vault holds none); proxy-implementation swaps under a counterparty entry (unchanged caveat).

## Decisions

### D1 — Four rules, in this order

1. Every call whose `target != asset()` must name a strategy the protocol's `StrategyFactory` holds as registered with unchanged code, else `NotARegisteredStrategy(target)`. The vault resolves the factory live: `governor → tierRegistry() → strategyFactory()` (raw reads; a hop that does not answer reads as zero) and then `isRegisteredStrategy(target)` on the factory (raw staticcall, one word required). Fail-closed at every hop: an unwired or mis-pointed factory registers nothing, so every non-asset target is refused until the wiring is fixed — loud at execute, never a silent admit.
2. `target == asset()`: `transferFrom` whose `from` word is not the vault reverts `TransferFromNotVault(from)`; every other selector is admitted. `transfer` and `transferFrom(vault, …)` are metered like any outflow; `approve` and `increaseAllowance` record their spender for rule 3; reads are harmless; a selector the token does not have reverts in the token.
3. Every spender recorded in the batch is `forceApprove(spender, 0)`'d after the delegatecall returns, before the meters. A spender that did not pull loses the allowance; a spender that pulled has already been metered.
4. The meters (`maxNetOutflow`, `reservedQueueAssets`, buffer floor) run after the reset, unchanged.

### D2 — Permissionless registration is a shape, not a trust check

`StrategyFactory.registerStrategy(strategy)` is callable by anyone, with no fee. It requires code and that the three `IStrategy` getters `vault()`, `proposer()`, `executed()` each answer one word; it records the address and its codehash and emits `StrategyRegistered`. `isRegisteredStrategy` is true only while the codehash still matches, so a code change after registration de-registers (a proxy-implementation swap is visible to guardians and the tier is 2 regardless). `cloneAndInit` and its deterministic twin register the clone they mint. Registration does NOT require `vault() == anything`: a strategy may serve several vaults if its code allows.

What registration buys is a fixed simulation shape for the guardian network: every batch target answers `IStrategy`, so a reviewer can read `vault()`, `proposer()` and `executed()` and simulate `execute()`/`settle()` against a known surface. It is not an endorsement: `tierOf` prices an unknown registered strategy at tier 2 with `boundBps == 10_000`; the protocol lowers the price only through `proposeCertification`/`certify` or `certifyClass`.

### D3 — What the registration rule subsumes, and what it does not

- The privileged-target denylist. The only protocol function reachable because `msg.sender == vault` is on `VaultWithdrawalQueue` (`queueRedeem`, `queueDeposit`, `stampSettlement` are `onlyVault`; nothing on the vault, governor, registries, ledger, game, sWOOD or factories keys on the vault as caller). The queue answers no `IStrategy` getter, so it cannot register and is refused as a target by rule 1; so are the vault, governor, registries and every other protocol contract, for the same reason. No enumeration is needed.
- The approve-only asset rule. On the asset, the only call the meter and the reset cannot see is `transferFrom(from != vault, …)`: it spends an LP's standing deposit allowance, assets flow IN, the meter reads zero, there is nothing to reset. Rule 2 refuses exactly that; `transfer` and `transferFrom(vault, …)` are metered, and any allowance the batch grants is reset.
- A callee-side `vault() == this` predicate was considered as a cheap way to keep batches inside strategy code, and stays rejected: a registered strategy that answers the predicate and then calls Morpho reaches the identical outcome, so the predicate constrains nothing and only taxes honest multi-vault strategies. Registration asks for the shape, not for a binding.
- Non-asset tokens the vault holds between execute and settle can still be moved by a settlement batch through a registered strategy; the tier price and the guardian bound that, as before.

### D4 — Emergency batches

`emergencySettleWithCalls` → `finalizeEmergencySettle` → `executeGovernorBatch` runs the same guard. No exemption (the owner is not more trusted than the governor for custody) and no extra restriction (the emergency path must be able to reach whatever a strategy reached).

### D5 — Registry: pricing and template binding only

Deleted: `_adapterAllowed`, `_adapterAllowedCodehash`, `_calleeAllowed`, `_calleeRevoked`, `_classAllowed`, `_classCalleeAllowed`, `_classAllowDenied`, and every setter/getter/event over them. Kept: address and class certification with their timelocks, epochs, bonds and demotion; `isCounterpartyAllowed` (now a pure counterparty flag with its grant-time codehash snapshot — the adapter fallback is gone); `isPriceSourceForToken`; `classOf`; `strategyFactory`. `_demote` still clears the counterparty entry (a convicted venue should not be bindable by a template), still deletes the tier config, and no longer writes any callee or allowlist state. `_demoteClass` clears only the class config.

### D6 — Templates bind venues as counterparties

`MorphoSupplyStrategy` (Morpho singleton), `PortfolioStrategy` (swap adapter, each price feed) and `ConcentratedLiquidityStrategy` (swap adapter; the rest already were) read `isCounterpartyAllowed` through the same fail-closed raw staticcall shape. `PortfolioStrategy` keeps the per-token `isPriceSourceForToken` pairing. The owner's ceremony is one call per venue, `setCounterpartyAllowed(venue, true)`.

### D7 — Factory: clone is permissionless, the vault must exist

`_authClone`'s owner/agent gate and the `Unauthorized` error are deleted. The `vaultToSyndicate(vault) != 0` check stays: a clone's `initialize` walks `vault() → governor() → tierRegistry()`, and `cloneTemplate` provenance is what makes a clone a class member for pricing, so provenance should only ever name real vaults. `proposer == msg.sender` stays. Note that anyone may now mint a class-member clone bound to any vault; the clone can only be executed by that vault's governor, through a proposal its agents write, priced at the class's tier — the tier is a property of the code, not of who deployed it. Minted clones are registered (D2) as a side effect.

### D9 — Governor: the `strategy` field is a registered strategy, and propose mirrors the target rule

`propose` requires `isRegisteredStrategy(strategy)` through the same `tierRegistry → strategyFactory` path (`StrategyNotRegistered(strategy)` otherwise); the field is otherwise informational (it names the proposal's strategy for observers, `strategyOf`, and the emergency `rescueTo`). The former `proposer()`/`vault()` consistency probe is deleted: a contract answering neither getter passed it, so it was a shape check with holes, and registration is the shape check. `propose` also refuses any non-asset batch target that is not registered, with the vault's `NotARegisteredStrategy(target)`: a settlement leg naming an unregistered contract would otherwise be stored, executed, and wedge the proposal in `Executed` at settle (issue #118's shape). Execute time remains the security boundary; propose time is the early error.

### D8 — Storage

`SyndicateVault` and `SyndicateGovernor` delete only constants, private functions and errors; no slot moves, goldens unchanged. `TierRegistry` is constructor-deployed (no proxy, no golden), so its mappings are deleted freely.

## Risks / Trade-offs

- A proposal may now `approve` the asset to any registered strategy and call it. That is the design: registration is permissionless, the price is tier 2 on that call, and the reset guarantees the approval cannot be used after the batch. What the guard promises is the callee's shape, not its intent; the guardian review is where that judgement lives.
- Non-asset tokens the vault holds between execute and settle can be moved by a settlement batch to anywhere. Previously the recipient allowlist bounded this; now the tier price and the guardian do. Recorded as accepted.
- The factory is resolved live at each batch (two warm reads) plus one `isRegisteredStrategy` staticcall per non-asset call. Cheap relative to the batch itself; storing the factory on the vault would need a wiring hook on every rotation.

## Migration

Fresh deployment. Any address previously `setAdapterAllowed` for a template binding is re-seeded with `setCounterpartyAllowed`; nothing else migrates.
