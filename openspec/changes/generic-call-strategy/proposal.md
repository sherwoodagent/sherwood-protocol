## Why

Since `structural-batch-rules` (SHE-271, PR #315) a proposal batch reaches a third-party protocol only through a strategy registered in `StrategyFactory`: `SyndicateVault._guardBatchCalls` reverts `NotARegisteredStrategy(target)` for every other non-asset target, and `SyndicateGovernor._mirrorBatchLeg` mirrors it at propose. That rule closes NM-0999 6.8 by construction and stays. Its cost is that an agent wanting a venue the three shipped templates do not cover (a Seaport order, a DEX router swap, a lending deposit) must write, compile, deploy and register Solidity. For Sherwood Arena, where agents propose on their own, that is a blocker (SHE-510).

`registerStrategy` is already permissionless, so a hand-written forwarder is admitted today. What is missing is a Sherwood-shipped forwarder: one reviewed code shape that guardians can recognise by provenance (`StrategyFactory.cloneTemplate`), read through fixed getters, and that agents use by encoding call lists instead of writing a contract.

## What Changes

- New template `src/strategies/GenericCallStrategy.sol` (extends `BaseStrategy`, ERC-1167 clone source). Init data is `abi.encode(uint256 pullAmount, Call[] executeCalls, Call[] settleCalls, address[] sweepTokens)` with `Call = BatchExecutorLib.Call (address target, bytes data, uint256 value)`. Everything is fixed at `initialize` for the clone's life; `updateParams` always reverts `NoTunableParams`.
- Init-time rules on every call: `value == 0`; target has code and is none of zero, the clone, the vault, the governor, the SyndicateFactory, the TierRegistry or the StrategyFactory (resolved fail-closed); on the vault asset only `approve` and `transfer` are allowed, so the clone cannot spend the vault's allowance beyond its own pull. Leg length, leg calldata size and the sweep list are capped. Each target's codehash is pinned.
- `execute()`: re-checks every pinned codehash (both legs), pulls `pullAmount` of the asset (skipped at zero), runs the execute leg (a failed call reverts `CallFailed(leg, index, revertData)`), then revokes the allowances and operator approvals the legs grant.
- `settle()`: runs the settle leg, revokes the same grants, then pushes the whole asset balance and every declared sweep token to the vault. No codehash check at settle. The price floor stays the governor's existing `maxDrawdownBps` check in `settleProposal`; the template adds no second one.
- Recovery: `BaseStrategy.rescueTo(token)` for any ERC-20; new vault-only `rescueERC721To(token, tokenId)`; `onERC721Received` so venues that deliver NFTs with `safeTransferFrom` work.
- Read-back for guardians: `executeCalls()`, `settleCalls()`, `sweepTokens()`, `grants()`, `pullAmount()`, `asset()`, `pinnedCodehash(target)`, `configHash()`, `name()`.
- Deploy: a `DeployGenericCallStrategy` template phase in `DeployAll`, a `GENERIC_CALL_TEMPLATE` CREATE3 salt and address-book key, and the key added to `DeployStrategyFactory._templateKeys()`. Nothing is run or deployed by this change.
- Docs: `docs/generic-call-strategy.md`, the README template table and the audit-scope page list the template as unaudited and at the fund's own risk, tier 2 forever.

## Capabilities

### New Capabilities

- `generic-call-strategy`: the template's init rules, execute and settle flows, approval revocation, recovery hooks, guardian read-back and tier-2 posture.

### Modified Capabilities

- `deployment-docs`: the ceremony gains the generic-call template phase and the template allowlist names four templates.

## Impact

- New: `src/strategies/GenericCallStrategy.sol`, `script/robinhood-mainnet/DeployGenericCallStrategy.s.sol`, `test/strategies/GenericCallStrategy*.t.sol`, `docs/generic-call-strategy.md`.
- Edited: `script/DeploySalts.sol`, `script/robinhood-mainnet/DeployTypes.sol`, `script/robinhood-mainnet/DeployAll.s.sol`, `script/DeployStrategyFactory.s.sol`, the deploy tests pinning the template set, `README.md`, `docs/audit-scope-and-accepted-risks.md`.
- Untouched: `SyndicateVault`, `SyndicateGovernor`, `StrategyFactory`, `TierRegistry`, `BaseStrategy`, storage-layout goldens, `chains/*.json`.
- On-chain (owner GO, not this change): deploy the template on 4663, `StrategyFactory.setTemplateApproval(template, true)` from the Safe, and the `GENERIC_CALL_TEMPLATE` address-book entry.
- Consumers (follow-ups): `sherwood` CLI/SDK/skill encoder and a guardian `TEMPLATE_ABIS` entry; Sherwood Arena catalog entry.
