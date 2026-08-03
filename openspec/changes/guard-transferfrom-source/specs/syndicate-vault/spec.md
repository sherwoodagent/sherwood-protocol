## ADDED Requirements

### Requirement: transferFrom source guard on batches

Every governor batch call carrying the `transferFrom(address,address,uint256)` selector, OR one of the alternate-signature "pull tokens via delegated allowance" selectors this guard recognizes — Permit2 `AllowanceTransfer.transferFrom(address,address,uint160,address)` (`0x36c78516`), DSToken `pull(address,uint256)` (`0xf2d5d56b`), and DSToken `move(address,address,uint256)` (`0xbb35783b`) — SHALL have its source address (`from`/`usr`/`src`, calldata bytes 4..36 in every recognized case) equal to the vault itself; otherwise the batch SHALL revert `DisallowedTransferFromSource(target, from)`. Calldata for any of these selectors too short to hold both address arguments (fewer than 68 bytes) SHALL revert `MalformedCall`. Both checks SHALL be enforced **unconditionally on every call in the batch, independently of whether a TierRegistry is wired** — they SHALL NOT be skipped by the degrade-open path that gates the value-moving selector guard. Because the guard runs inside `executeGovernorBatch`, it SHALL apply on the execute, settlement, and both emergency batch paths alike.

A post-merge security review (Pashov 12-agent audit of PR #157, confidence 90, 3-agent independent convergence) found that limiting recognition to the single legacy `transferFrom` selector left the identical "pull via delegated allowance" capability, exposed under a different selector by Permit2 or DSToken, completely unguarded — reproducing the exact confiscation primitive this requirement exists to close, just routed through a different target. The guard is extended selector-by-selector (documented follow-up: a target-based redesign, gating every batch call regardless of selector, was assessed as more durable but was deferred because it would require re-plumbing the tier-pricing/TierRegistry relationship for every non-value-moving adapter call, outside this change's footprint).

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

#### Scenario: Permit2-routed confiscation is rejected identically to legacy transferFrom

- **WHEN** a governor batch contains `Permit2.transferFrom(victim, attacker, amount, token)` where `victim` is any address other than the vault and `victim` has a standing Permit2 allowance recorded for `token`
- **THEN** `executeGovernorBatch` reverts `DisallowedTransferFromSource(permit2, victim)`, exactly as it would for the equivalent legacy `token.transferFrom(victim, attacker, amount)` call

#### Scenario: DSToken pull/move from a non-vault source is rejected

- **WHEN** a governor batch contains `DSToken.pull(victim, amount)` or `DSToken.move(victim, attacker, amount)` where `victim` is not the vault
- **THEN** the batch reverts `DisallowedTransferFromSource(dstoken, victim)`

## MODIFIED Requirements

### Requirement: Value-moving selector guard on batches

When the calling governor exposes a nonzero TierRegistry, every batch call carrying one of the guarded value-moving selectors — legacy `approve`, `increaseAllowance`, `transfer`, `transferFrom`, plus Permit2 `AllowanceTransfer.approve(address,address,uint160,uint48)` (`0x87517c45`), Permit2 `AllowanceTransfer.transferFrom` (`0x36c78516`), and DSToken `move` (`0xbb35783b`) — SHALL have its spender/recipient (arg 1, calldata bytes 4..36, for legacy `approve`/`increaseAllowance`/`transfer`; arg 2, calldata bytes 36..68, for legacy `transferFrom`, Permit2 `transferFrom`'s `to`, Permit2 `approve`'s `spender`, and DSToken `move`'s `dst`) be either the vault itself or an adapter allowlisted in the TierRegistry; otherwise the batch SHALL revert `DisallowedTransferTarget`. Guarded-selector calldata too short to hold the guarded argument SHALL revert `MalformedCall`. The guard SHALL run on every governor batch (execute, settlement, and emergency paths). When the governor has no tier registry wired (getter missing or returning zero), this destination guard SHALL be skipped by design; the transferFrom **source** guard is unconditional and is specified separately.

The self-transfer fast-path (destination decodes to the vault itself) SHALL apply **only** when the call's target is `asset()` — the one token whose balance the outer net-outflow meter in `executeGovernorBatch` independently verifies via a balance diff. For every other token the vault holds (e.g. a strategy position), a destination that decodes to the vault SHALL still be routed through the TierRegistry check like any other destination; a non-standard token could otherwise execute arbitrary logic under a vault-to-vault call shape with zero verification anywhere in the pipeline.

#### Scenario: Balance-invisible exfiltration blocked

- **WHEN** a batch call is `token.approve(attacker, max)` and `attacker` is not the vault or an allowlisted adapter
- **THEN** the batch reverts `DisallowedTransferTarget` even though the call itself moves no balance

#### Scenario: Registry-less governor degrades open

- **WHEN** the governor's tier registry is unset
- **THEN** the destination guard does not run and the batch proceeds under the transferFrom source guard, the privileged-target guard, and the outflow/reserve/buffer checks only

#### Scenario: Permit2 approve to a non-allowlisted spender is rejected

- **WHEN** a governor batch contains `Permit2.approve(token, attacker, amount, expiration)` and `attacker` is not the vault or an allowlisted adapter
- **THEN** the batch reverts `DisallowedTransferTarget(permit2, PERMIT2_APPROVE_SELECTOR, attacker)`, closing the two-transaction poison-then-drain route through Permit2 identically to the legacy `approve` guard

#### Scenario: Self-transfer fast-path does not exempt non-asset() tokens

- **WHEN** a governor batch contains `EvilToken.transferFrom(vault, vault, amount)` where `EvilToken` is not `asset()` and is not allowlisted in the TierRegistry
- **THEN** the batch reverts `DisallowedTransferTarget(EvilToken, TRANSFER_FROM_SELECTOR, vault)` — the destination decoding to the vault no longer skips the registry check for any token other than `asset()`

#### Scenario: Self-transfer fast-path still exempts asset()

- **WHEN** a governor batch contains `asset().transferFrom(vault, vault, amount)` (a self-approve/self-transfer of the vault's own underlying asset)
- **THEN** the destination guard's fast-path exempts it exactly as before, since `asset()` is the token the outer net-outflow meter independently verifies
