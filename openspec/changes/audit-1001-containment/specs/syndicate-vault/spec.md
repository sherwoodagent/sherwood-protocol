## MODIFIED Requirements

### Requirement: On the asset, a call is a metered transfer or allowance-shaped, and no allowance survives the batch

For every governor-batch call whose `target` is `asset()`: calldata shorter than 36 bytes SHALL revert `MalformedAssetCall(selector)` before any call executes. `transfer(to, n)` and `transferFrom(vault, to, n)` SHALL be admitted as metered egress; `transferFrom` whose first argument word is not the vault's address SHALL revert `TransferFromNotVault(from)`. The approve family — `approve(address,uint256)`, `increaseAllowance(address,uint256)`, `increaseApproval(address,uint256)`, `decreaseAllowance(address,uint256)` and `decreaseApproval(address,uint256)` — SHALL be admitted as allowance-shaped: the guard SHALL record the first argument word as a spender, and after the batch's delegatecall returns — before the outflow, reserve and buffer checks — the vault SHALL `forceApprove(spender, 0)` on `asset()` for each recorded spender. Every other selector, reads included, SHALL revert `UnrecognizedAssetSelector(selector)` before any call executes: a token's own extensions (Paxos's `transferFromBatch`, for one) can spend allowances held by the vault, so the asset surface is a named set. The governor SHALL apply the same predicate at propose to both batches, so no proposal can reach `Executed` on an asset leg that execute or settle would refuse. The rule SHALL apply on the execute, settlement and emergency batch paths alike.

#### Scenario: transferFrom from an LP is refused
- **WHEN** a batch contains `asset.transferFrom(lp, x, n)` where `lp` holds a standing deposit allowance to the vault
- **THEN** the batch reverts `TransferFromNotVault(lp)` before any call executes and the LP's allowance is untouched

#### Scenario: transferFromBatch naming an LP is refused
- **WHEN** the asset exposes `transferFromBatch(address[],address[],uint256[])` and a batch or a proposal's execute or settlement leg calls it with an LP as `from[0]`
- **THEN** `executeGovernorBatch` and `propose` revert `UnrecognizedAssetSelector(transferFromBatch.selector)` before any call executes, and the LP's balance and allowance to the vault are untouched

#### Scenario: Reads and unknown grant shapes are refused
- **WHEN** a batch calls the asset with `balanceOf`, `allowance`, `permit`, `transferAndCall` or any selector outside the admitted set
- **THEN** the batch reverts `UnrecognizedAssetSelector(selector)` before any call executes

#### Scenario: Short asset calldata is refused
- **WHEN** a batch contains an asset call of fewer than 36 bytes (empty, `decimals()`, a bare `transferFrom` selector, an `approve` truncated to 35 bytes)
- **THEN** the batch reverts `MalformedAssetCall(selector)` before any call executes

#### Scenario: A Paxos-shaped asset's increaseApproval is reset
- **WHEN** the asset grants through `increaseApproval(address,uint256)` and has no `increaseAllowance` (the launch asset's shape) and a batch grants two spenders through it, one of which pulls inside the batch
- **THEN** after `executeGovernorBatch` returns, `asset.allowance(vault, spender)` is zero for both, and in the next block `transferFrom(vault, attacker, n)` by the idle spender reverts for insufficient allowance

#### Scenario: transferFrom from the vault is admitted and metered
- **WHEN** a batch approves the vault itself and calls `asset.transferFrom(vault, x, n)`
- **THEN** the batch executes iff `n <= maxNetOutflow`, else reverts `MaxNetOutflowExceeded`

#### Scenario: transfer is admitted and metered
- **WHEN** a batch contains `asset.transfer(x, n)`
- **THEN** the batch executes iff `n <= maxNetOutflow`, else reverts `MaxNetOutflowExceeded`

#### Scenario: Every recorded spender reads zero allowance after the batch
- **WHEN** a batch grants two spenders via `approve` or `increaseAllowance`, one of which pulls inside the batch and one of which does not
- **THEN** after `executeGovernorBatch` returns, `asset.allowance(vault, spender)` is zero for both

#### Scenario: Approve-then-drain in a later block is impossible
- **WHEN** a batch approves `attacker` for `type(uint256).max` and no call pulls
- **THEN** in the next block `asset.transferFrom(vault, attacker, 1)` by `attacker` reverts for insufficient allowance
