## 1. Vault — structural batch rules

- [ ] 1.1 Rewrite `_guardBatchCalls` to the four rules (design D1): privileged denylist over the resolved protocol set, asset-only-`approve`, spender collection, everything else admitted. Return the spenders.
- [ ] 1.2 After the delegatecall in `executeGovernorBatch`, `forceApprove(spender, 0)` for every collected spender, before the meters.
- [ ] 1.3 Delete the fifteen `_SEL_*` constants, `_Permit2BatchDetail`, `_requireRecipientVaultBinding`, `_readVaultOf`, `_isBenignAssetRead`, and the guard doc block.
- [ ] 1.4 `ISyndicateVault`: delete `DisallowedTransferTarget`, `DisallowedBatchCallee`, `UnrecognizedAssetSelector`, `DisallowedTransferFromSource`, `AdapterVaultMismatch`, `MalformedCall`, `TierRegistryUnresolved`; add `DisallowedAssetSelector(bytes4)`; restate `DisallowedBatchTarget` and `isPrivilegedBatchTarget` for the widened set.
- [ ] 1.5 Governor: confirm no `isAdapterAllowed` / `isCallableTarget` read remains (grep); `_rejectPrivilegedTargets` unchanged.
- [ ] 1.6 `./script/check-layout-goldens.sh` passes without regeneration.

## 2. Registry — pricing and template binding only

- [ ] 2.1 Delete `_adapterAllowed`, `_adapterAllowedCodehash`, `_calleeAllowed`, `_calleeRevoked`, `_classAllowed`, `_classCalleeAllowed`, `_classAllowDenied`, `setAdapterAllowed`, `setCallable`, `setClassAllowed`, `setClassCallable`, `isAdapterAllowed`, `isCallableTarget`, `isClassAllowed`, `isClassAllowDenied`, `_classFp` if orphaned, and the events `AdapterAllowedSet`, `CalleeAllowedSet`, `ClassAllowedSet`, `ClassCalleeAllowedSet`, `ClassMemberAllowDenied`.
- [ ] 2.2 `isCounterpartyAllowed` reads only the counterparty flag + snapshot; `_demote` clears the tier config, the pending entry, the bond timelock and the counterparty entry; `_demoteClass` clears only the class config.
- [ ] 2.3 `ITierRegistry`: `tierOf`, `isCounterpartyAllowed`, `classOf`, `strategyFactory`.
- [ ] 2.4 Templates: `MorphoSupplyStrategy`, `PortfolioStrategy`, `ConcentratedLiquidityStrategy` bind venues via `isCounterpartyAllowed`; update each `ITierBindingPath`.
- [ ] 2.5 Every registry stand-in reached by a strategy gains `isCounterpartyAllowed` (grep `function isCounterpartyAllowed` test/).
- [ ] 2.6 Deploy scripts: `_seedAdapter` deleted, feeds and Morpho seeded as counterparties, `_attestAdapter` → `setCounterpartyAllowed`, runbook text updated.

## 3. Factory — permissionless clone

- [ ] 3.1 Delete `_authClone`'s owner/agent gate, `IVaultMembership`, `Unauthorized`; keep the vault-registered check, the template allowlist and `proposer == msg.sender`.

## 4. Tests

- [ ] 4.1 New `test/vault/StructuralBatchRules.t.sol`: privileged-target loop, every non-approve asset selector, allowance reset, approve-then-drain-next-block, arbitrary contract admitted and metered, two-leg tier pricing, uncertified tier 2, certified class clone via permissionless `cloneAndInit`, the three templates through the real governor with counterparty grants only, emergency batch.
- [ ] 4.2 Delete `SelectorGuard.t.sol`, `CalleeGate.t.sol`, `Vault_assetSelectorGuard.t.sol`, `TierRegistryAdapterAllowlist.t.sol`, `TierRegistryClassMemberDenial.t.sol`, `Registry_demoteKeepsCalleeStanding.t.sol`, `PortfolioStrategyAdapterAllowlist.t.sol`'s allowlist cases, `StrategyFactory_auth.t.sol`'s gate cases, and every test whose only subject was the allowlist or recipient decoding.
- [ ] 4.3 Re-pin `Vault_batchQueueTargets.t.sol` (privileged denylist), `OutflowMetering.t.sol`, the SHE-209 binding suites, `TierRegistryClassCertification.t.sol`, the direct-protocol governor proposals (now admitted and metered), the fizz handler and the deploy tests.
- [ ] 4.4 Mutation table: reset dropped; asset rule admits `transfer`; denylist misses the queue; `isAdapterAllowed` symbol gone (compile); `cloneAndInit` gate restored.
- [ ] 4.5 Full `forge test --no-match-path 'test/integration/**'`, `forge fmt`, `forge build` incl. integration, `openspec validate --all --strict`.
