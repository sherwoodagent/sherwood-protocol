## Why

The vault's batch guard grew into an enumeration: fifteen ERC-20-shaped selectors decoded for a spender or recipient, a callee allowlist consulted per target, a recipient allowlist consulted per decoded address, a class-member vault-binding probe, and a benign-read list for the asset. Every audit round found a sibling selector the enumeration missed (Permit2, DSToken, ERC1363, ERC4626), and every fix widened the list without changing the shape of the problem: an allowlist over calldata the proposer writes is a list of what someone thought of. Meanwhile the callee allowlist turned "anyone can write a strategy" into "the registry owner must bless every address a proposal touches", which is the opposite of the protocol's premise — uncertified code is admitted and PRICED (tier 2, full notional), and the guardian network is the judgement.

## What Changes

- **BREAKING** — `SyndicateVault._guardBatchCalls` is exactly four structural rules: (1) a fixed privileged-target denylist (vault, queue, governor, tier registry, guardian registry, sWOOD, ledger, game, both factories); (2) on `asset()` only `approve(spender, n)` is admitted; (3) every spender approved inside a batch is `forceApprove(spender, 0)`'d after the batch, so no allowance survives the transaction; (4) any other target with any selector is admitted. The net-outflow meter, queue reserve and buffer floor are unchanged. The selector constants, the recipient decoding, the callee gate, the class vault-binding probe, the benign-read list and the errors `DisallowedTransferTarget`, `DisallowedBatchCallee`, `UnrecognizedAssetSelector`, `DisallowedTransferFromSource`, `AdapterVaultMismatch`, `MalformedCall`, `TierRegistryUnresolved` are deleted. A new `DisallowedAssetSelector(bytes4)` names the asset rule.
- **BREAKING** — `TierRegistry` loses the callee and recipient axes: `setAdapterAllowed`, `setCallable`, `setClassAllowed`, `setClassCallable`, `isAdapterAllowed`, `isCallableTarget`, `isClassAllowed`, `isClassAllowDenied` and their events/storage. Tier certification (address and class), `isCounterpartyAllowed`, `isPriceSourceForToken`, `classOf` and `strategyFactory` stay. `isCounterpartyAllowed` no longer falls back to adapter standing; demotion clears the counterparty entry and the tier, nothing else.
- **BREAKING** — `StrategyFactory.cloneAndInit` / `cloneAndInitDeterministic` are permissionless: the vault-owner / vault-agent gate is deleted. The template allowlist, the vault-registered check and `cloneTemplate` provenance stay.
- The three shipped templates bind their venues through `isCounterpartyAllowed` (Morpho singleton; Portfolio swap adapter and price feeds; CL swap adapter). `PortfolioStrategy` keeps the per-token `isPriceSourceForToken` pairing.
- Deploy scripts seed venues and feeds as counterparties only; no script calls `setAdapterAllowed`.
- Governor: no change to `propose`, tiering or coverage. `strategy` stays informational.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `syndicate-vault`: batch guard requirements replaced by the structural rules; the privileged-target set is widened to every protocol contract the vault can resolve.
- `tier-policy`: the callee axis and adapter allowlist requirements are removed; demotion no longer touches an allowlist; the counterparty axis is specified as the only address axis; the external read surface is restated.
- `syndicate-governor`: proposal creation validation states that batch admission is structural and that `strategy` is informational.
- `deployment-docs`: the launch set seeds counterparties and feeds through `setCounterpartyAllowed` only.

## Impact

- `src/SyndicateVault.sol`, `src/interfaces/ISyndicateVault.sol` — guard rewrite (~200 lines → ~40), allowance reset, privileged set.
- `src/TierRegistry.sol`, `src/interfaces/ITierRegistry.sol` — axes deleted.
- `src/StrategyFactory.sol` — `_authClone` deleted.
- `src/strategies/{MorphoSupplyStrategy,PortfolioStrategy,ConcentratedLiquidityStrategy}.sol` — venue binding via `isCounterpartyAllowed`.
- `script/Deploy.s.sol`, `script/DeployPlanB.s.sol`, `script/robinhood-mainnet/*.s.sol` — ceremony text and seeding.
- Tests: `SelectorGuard`, `CalleeGate`, `Vault_assetSelectorGuard`, the registry allowlist suites and every fixture calling `setAdapterAllowed` are deleted or re-pinned; new `test/vault/StructuralBatchRules.t.sol`.
- Storage: `SyndicateVault` and `SyndicateGovernor` layouts unchanged (only constants and functions are deleted). `TierRegistry` is constructor-deployed, not golden-guarded.
