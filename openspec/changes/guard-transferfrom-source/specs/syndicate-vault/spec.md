## ADDED Requirements

### Requirement: transferFrom source guard on batches

Every governor batch call carrying the `transferFrom(address,address,uint256)` selector SHALL have its `from` argument (calldata bytes 4..36) equal to the vault itself; otherwise the batch SHALL revert `DisallowedTransferFromSource(target, from)`. `transferFrom` calldata too short to hold both address arguments (fewer than 68 bytes) SHALL revert `MalformedCall`. Both checks SHALL be enforced **unconditionally on every call in the batch, independently of whether a TierRegistry is wired** — they SHALL NOT be skipped by the degrade-open path that gates the value-moving selector guard. Because the guard runs inside `executeGovernorBatch`, it SHALL apply on the execute, settlement, and both emergency batch paths alike.

The adversary is a governor batch that spends a third party's ERC-20 allowance: batches execute via `delegatecall`, so every sub-call carries `msg.sender == vault`, and `token.transferFrom(victim, vault, victimBalance)` spends `allowance[victim][vault]` — the standing (routinely unlimited) allowance every LP grants in order to deposit. No other meter sees it: the vault's balance rises so net-outflow reads 0, tier coverage prices only vault capital (`maxCapital`) and never third-party wallets, and the privileged-target denylist does not fire because the call target is the token. Confiscation is not a priced capability but a refused one, which is why the check is unconditional — the same posture as the privileged-target guard.

The permitted source is exactly the vault itself, NOT the TierRegistry adapter allowlist. `isAdapterAllowed` encodes destination consent — an address the vault may *send* funds to — and an entry there is no consent to having its own allowances seized. No honest batch pulls from any third party: capital deploys via a guarded `approve` to an adapter that pulls in its own code, and returns are pushes from the adapter.

#### Scenario: LP-allowance confiscation is rejected

- **WHEN** a governor batch contains `token.transferFrom(victim, vault, amount)` where `victim` is any address other than the vault (e.g. an LP holding a `type(uint256).max` deposit allowance to the vault)
- **THEN** `executeGovernorBatch` reverts `DisallowedTransferFromSource(token, victim)`, even though the destination is the vault and the vault's balance would have risen

#### Scenario: Allowlisted adapter is not a permitted source

- **WHEN** a governor batch contains `token.transferFrom(adapter, vault, amount)` where `adapter` is allowlisted in the TierRegistry
- **THEN** the batch reverts `DisallowedTransferFromSource(token, adapter)` — destination consent does not confer source consent

#### Scenario: Guard fires even without a wired TierRegistry

- **WHEN** the calling governor exposes no TierRegistry (getter missing or returning `address(0)`) and a batch contains `transferFrom` with a non-vault source
- **THEN** the batch still reverts `DisallowedTransferFromSource` — the source guard runs outside the registry-less degrade-open path that skips the selector guard

#### Scenario: Vault-sourced transferFrom still flows through the destination guard

- **WHEN** a governor batch contains `token.transferFrom(vault, x, amount)`
- **THEN** the source guard passes it, and `x` remains subject to the value-moving selector guard (vault or allowlisted adapter, else `DisallowedTransferTarget`) and the batch to the net-outflow meter — exactly as if the call were `transfer(x, amount)`

#### Scenario: Short transferFrom calldata is rejected unconditionally

- **WHEN** a governor batch contains a call whose selector is `transferFrom` but whose calldata cannot hold both address arguments (length below 68 bytes), and no TierRegistry is wired
- **THEN** the batch reverts `MalformedCall` — the source guard's calldata bound does not degrade open with the registry

## MODIFIED Requirements

### Requirement: Value-moving selector guard on batches

When the calling governor exposes a nonzero TierRegistry, every batch call carrying one of the four value-moving ERC-20 selectors — `approve`, `increaseAllowance`, `transfer`, `transferFrom` — SHALL have its spender/recipient (arg 1 for the first three; the `to` arg for `transferFrom`) be either the vault itself or an adapter allowlisted in the TierRegistry; otherwise the batch SHALL revert `DisallowedTransferTarget`. Guarded-selector calldata too short to hold the guarded argument SHALL revert `MalformedCall`. The guard SHALL run on every governor batch (execute, settlement, and emergency paths). When the governor has no tier registry wired (getter missing or returning zero), this destination guard SHALL be skipped by design; the transferFrom **source** guard is unconditional and is specified separately.

#### Scenario: Balance-invisible exfiltration blocked

- **WHEN** a batch call is `token.approve(attacker, max)` and `attacker` is not the vault or an allowlisted adapter
- **THEN** the batch reverts `DisallowedTransferTarget` even though the call itself moves no balance

#### Scenario: Registry-less governor degrades open

- **WHEN** the governor's tier registry is unset
- **THEN** the destination guard does not run and the batch proceeds under the transferFrom source guard, the privileged-target guard, and the outflow/reserve/buffer checks only
