## Why

The vault's batch guard grew into an enumeration: fifteen ERC-20-shaped selectors decoded for a spender or recipient, a callee allowlist consulted per target, a recipient allowlist consulted per decoded address, a class-member vault-binding probe, and a benign-read list for the asset. Every audit round found a sibling selector the enumeration missed (Permit2, DSToken, ERC1363, ERC4626), and every fix widened the list without changing the shape of the problem: an allowlist over calldata the proposer writes is a list of what someone thought of. Meanwhile the callee allowlist turned "anyone can write a strategy" into "the registry owner must bless every address a proposal touches", which is the opposite of the protocol's premise — uncertified code is admitted and PRICED (tier 2, full notional), and the guardian network is the judgement.

## What Changes

- **BREAKING** — `SyndicateVault._guardBatchCalls` is exactly four structural rules: (1) every call whose target is not `asset()` names a strategy the protocol's `StrategyFactory` holds as registered with unchanged code (`NotARegisteredStrategy(target)` otherwise; fail-closed through `governor → tierRegistry → strategyFactory → isRegisteredStrategy`); (2) on `asset()`, a call is either a metered transfer (`transfer`, `transferFrom` from the vault only — `TransferFromNotVault(from)` otherwise) or allowance-shaped: it carries at least 36 bytes (`MalformedAssetCall(selector)` otherwise) and its first argument is recorded as a spender, whatever the selector; (3) every recorded spender is `forceApprove(spender, 0)`'d after the batch, so no allowance survives the transaction — `approve`, `increaseAllowance`, Paxos's `increaseApproval` (the launch asset's shape) and any future grant shape alike, with no selector enumerated; (4) the net-outflow meter, queue reserve and buffer floor are unchanged. The selector constants, the recipient decoding, the callee gate, the class vault-binding probe, the benign-read list, the privileged-target denylist and the errors `DisallowedTransferTarget`, `DisallowedBatchCallee`, `UnrecognizedAssetSelector`, `DisallowedTransferFromSource`, `AdapterVaultMismatch`, `MalformedCall`, `TierRegistryUnresolved`, `DisallowedBatchTarget` and the view `isPrivilegedBatchTarget` are deleted.
- **BREAKING** — `StrategyFactory` becomes the permissionless strategy registry: `registerStrategy(strategy)` (any caller, no fee; requires code and one-word answers to `IStrategy`'s `vault()`, `proposer()`, `executed()`, else `NotAStrategy`), `isRegisteredStrategy(strategy)` (registered and codehash unchanged), `StrategyRegistered` event; minted clones are registered automatically.
- **BREAKING** — `SyndicateGovernor.propose` requires `strategy` to be a registered strategy (`StrategyNotRegistered(strategy)`; `address(0)` is no longer accepted) and refuses any non-asset batch target that is not registered (`NotARegisteredStrategy(target)`) before storing the proposal. The `proposer()`/`vault()` consistency probe and `StrategyProposerMismatch` / `StrategyVaultMismatch` are deleted.
- **BREAKING** — `TierRegistry` loses the callee and recipient axes: `setAdapterAllowed`, `setCallable`, `setClassAllowed`, `setClassCallable`, `isAdapterAllowed`, `isCallableTarget`, `isClassAllowed`, `isClassAllowDenied` and their events/storage. Tier certification (address and class), `isCounterpartyAllowed`, `isPriceSourceForToken`, `classOf` and `strategyFactory` stay. `isCounterpartyAllowed` no longer falls back to adapter standing; demotion clears the counterparty entry and the tier, nothing else.
- **BREAKING** — `StrategyFactory.cloneAndInit` / `cloneAndInitDeterministic` are permissionless: the vault-owner / vault-agent gate is deleted. The template allowlist, the vault-registered check and `cloneTemplate` provenance stay.
- The three shipped templates bind their venues through `isCounterpartyAllowed` (Morpho singleton; Portfolio swap adapter and price feeds; CL swap adapter). `PortfolioStrategy` keeps the per-token `isPriceSourceForToken` pairing.
- Deploy scripts seed venues and feeds as counterparties only; no script calls `setAdapterAllowed`.
- Governor: tiering and coverage unchanged; `strategy` stays informational beyond registration.
- **BREAKING** — `settleProposal` and `unstick` run the settle batch with a net-outflow budget of zero: a settle batch brings assets home or moves nothing, so `effectiveMaxCapital` bounds the whole lifecycle's egress rather than each leg. `finalizeEmergencySettle` keeps `effectiveMaxCapital` (guardian-reviewed, owner-bonded owner unwinds may need to fund a repay).
- `DeployStrategyFactory` wires `TierRegistry.setStrategyFactory` mandatorily (no `ALLOW_UNWIRED_TIER_REGISTRY` path) and runs before the multisig accepts TierRegistry ownership; the Plan B TierRegistry-redeploy runbook lists `setStrategyFactory`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `syndicate-vault`: batch guard requirements replaced by the structural rules; the privileged-target guard is removed (subsumed by the registered-strategy rule).
- `tier-policy`: the callee axis and adapter allowlist requirements are removed; demotion no longer touches an allowlist; the counterparty axis is specified as the only address axis; the external read surface is restated; permissionless strategy registration on the `StrategyFactory` is added here (no separate strategy-factory spec exists).
- `syndicate-governor`: proposal creation validation requires a registered `strategy` and registered batch targets; the strategy consistency probe is removed.
- `deployment-docs`: the launch set seeds counterparties and feeds through `setCounterpartyAllowed` only.

## Impact

- `src/SyndicateVault.sol`, `src/interfaces/ISyndicateVault.sol` — guard rewrite (~200 lines → ~40), allowance reset, registered-strategy read.
- `src/StrategyFactory.sol`, `src/interfaces/IStrategyFactory.sol` — permissionless registration.
- `src/SyndicateGovernor.sol`, `src/interfaces/ISyndicateGovernor.sol` — registered `strategy` field, propose-time target mirror.
- `src/TierRegistry.sol`, `src/interfaces/ITierRegistry.sol` — axes deleted.
- `src/StrategyFactory.sol` — `_authClone` deleted.
- `src/strategies/{MorphoSupplyStrategy,PortfolioStrategy,ConcentratedLiquidityStrategy}.sol` — venue binding via `isCounterpartyAllowed`.
- `script/Deploy.s.sol`, `script/DeployPlanB.s.sol`, `script/robinhood-mainnet/*.s.sol` — ceremony text and seeding.
- Tests: `SelectorGuard`, `CalleeGate`, `Vault_assetSelectorGuard`, the registry allowlist suites and every fixture calling `setAdapterAllowed` are deleted or re-pinned; new `test/vault/StructuralBatchRules.t.sol`.
- Storage: `SyndicateVault` and `SyndicateGovernor` layouts unchanged (only constants and functions are deleted). `TierRegistry` is constructor-deployed, not golden-guarded.
