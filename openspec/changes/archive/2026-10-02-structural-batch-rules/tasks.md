## 1. Vault — structural batch rules

- [x] 1.1 Rewrite `_guardBatchCalls` to the four rules (design D1): every non-asset target is a registered strategy (fail-closed factory read); on the asset a call is a metered transfer (`transferFrom` from the vault only) or allowance-shaped (>= 36 bytes, first argument recorded as a spender, no selector enumerated); meters unchanged. Return the spenders.
- [x] 1.8 `settleProposal` and `unstick` pass `maxNetOutflow = 0` (design D10); `finalizeEmergencySettle` keeps `effectiveMaxCapital` and says why.
- [x] 1.9 `DeployStrategyFactory`: wiring mandatory, `deploy(...)` drivable from a test, no `ALLOW_UNWIRED_TIER_REGISTRY`; Plan B redeploy runbook lists `setStrategyFactory` (design D11).
- [x] 1.2 After the delegatecall in `executeGovernorBatch`, `forceApprove(spender, 0)` for every collected spender, before the meters.
- [x] 1.3 Delete the fifteen `_SEL_*` constants, `_Permit2BatchDetail`, `_requireRecipientVaultBinding`, `_readVaultOf`, `_isBenignAssetRead`, and the guard doc block.
- [x] 1.4 `ISyndicateVault`: delete `DisallowedTransferTarget`, `DisallowedBatchCallee`, `UnrecognizedAssetSelector`, `DisallowedTransferFromSource`, `AdapterVaultMismatch`, `MalformedCall`, `TierRegistryUnresolved`, `DisallowedBatchTarget`, `isPrivilegedBatchTarget`; add `NotARegisteredStrategy(address)` and `TransferFromNotVault(address)`.
- [x] 1.5 `StrategyFactory`: `registerStrategy`, `isRegisteredStrategy`, `StrategyRegistered`, `NotAStrategy`; clones register on mint. `IStrategyFactory.isRegisteredStrategy`.
- [x] 1.7 Governor: `propose` requires a registered `strategy` (`StrategyNotRegistered`), refuses unregistered non-asset batch targets (`NotARegisteredStrategy`); the `proposer()`/`vault()` probe and its two errors are deleted.
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

- [x] 4.1 New `test/vault/StructuralBatchRules.t.sol`: unregistered targets refused (Morpho, queue, governor, vault, registry, stub), registered strategy admitted with any selector, registration shape check, de-registration on code change, unwired factory, factory without the selector, registered `strategy` field at propose, asset `transferFrom` from LP refused / from vault metered, `transfer` metered, allowance reset over `approve` and `increaseAllowance`, approve-then-drain-next-block, two-leg tier pricing, uncertified tier 2, certified class clone via permissionless `cloneAndInit`, the three templates through the real governor, emergency batch (in `GovernorEmergency`). Registration unit tests in `test/StrategyFactory.t.sol`.
- [ ] 4.2 Delete `SelectorGuard.t.sol`, `CalleeGate.t.sol`, `Vault_assetSelectorGuard.t.sol`, `TierRegistryAdapterAllowlist.t.sol`, `TierRegistryClassMemberDenial.t.sol`, `Registry_demoteKeepsCalleeStanding.t.sol`, `PortfolioStrategyAdapterAllowlist.t.sol`'s allowlist cases, `StrategyFactory_auth.t.sol`'s gate cases, and every test whose only subject was the allowlist or recipient decoding.
- [ ] 4.3 Re-pin `Vault_batchQueueTargets.t.sol` (privileged denylist), `OutflowMetering.t.sol`, the SHE-209 binding suites, `TierRegistryClassCertification.t.sol`, the direct-protocol governor proposals (now admitted and metered), the fizz handler and the deploy tests.
- [x] 4.4 Mutation table: registration check dropped; codehash check dropped; `transferFrom` rule dropped; reset dropped; reset back to a selector list (Paxos drain); `arg0` decode dropped (unknown selector); length check dropped (short calldata); propose field check dropped; `executed()` probe dropped; deploy wiring skipped; settle budget restored to `effectiveMaxCapital`.
- [x] 4.6 `test/mocks/GlobalDollarMock.sol` (Paxos shape) and the asset-rule tests in `StructuralBatchRules`; `StrategyFactory` partial-interface permutations; `test/deploy/DeployStrategyFactory_wiring.t.sol`; settle zero-egress pair.
- [ ] 4.5 Full `forge test --no-match-path 'test/integration/**'`, `forge fmt`, `forge build` incl. integration, `openspec validate --all --strict`.
