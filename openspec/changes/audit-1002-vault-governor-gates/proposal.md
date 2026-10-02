# Audit 2026-10-02 vault and governor gates (FP-04 token leg, FP-13, FP-17 claim gate)

## Why

- **FP-04 (Medium, token leg).** `rescueERC20` sent any non-asset token to any address the owner named. After an emergency batch rescued a strategy's position tokens into the vault and finalized, the owner could take the whole basket while LPs booked it as a loss. `StrategyFactory.registerStrategy` is permissionless, so "registered strategy" is not a safe recipient test; `cloneTemplate` is written only by the factory's own clone functions from an approved template.
- **FP-13 (Low).** `propose` checked `strategyDuration` only against the vault's stored `maxStrategyDuration`. A lowered `ProtocolConfig.maxStrategyDuration` bound the owner's setter but no proposal, on existing vaults or new ones (the factory seeds 30 days and `initialize` validates before `protocolConfig` is set).
- **FP-17 (Low, deposit-claim gate).** A queued-deposit claim minted while the vault was paused and for a receiver the owner had removed from the whitelist; the whitelist was checked only at `requestDeposit`.

## What Changes

- `SyndicateVault.rescueERC20` requires the recipient to be a strategy clone of this vault: `IStrategyFactory(strategyFactory).cloneTemplate(to) != address(0)` and `IStrategy(to).vault() == address(this)`, both read fail-closed (an unwired factory, a codeless recipient or one that does not answer reverts). Otherwise it reverts `RescueRecipientNotStrategy(to)`. A token sent there is returned to the vault only by a later proposal's batch (`settle` / `rescueTo`, both vault-only on every shipped template). `rescueEth` and `rescueERC721` are unchanged.
- `SyndicateGovernor.propose` reverts `StrategyDurationTooLong` when `strategyDuration` exceeds either the vault's stored maximum or the live protocol ceiling (`_protocolMaxStrategyDuration()`, unlimited when the ceiling is 0). The factory default and the order in `initialize` are unchanged, so creating a vault never reverts on a lowered ceiling.
- `SyndicateVault.settleDeposit` is `whenNotPaused` and re-runs the depositor whitelist rule against the receiver. A refused claim reverts whole; the receiver's exit is the queue's `cancel`, which a deposit request keeps until it is claimed and which works while the vault is paused.

## Impact

- Specs: `syndicate-vault` (depositor access control, request cancellation, pause and emergency behavior) and `epoch-nav` (the protocol ceiling clamps at propose). The governor's proposal-validation requirement is left to `epoch-nav` because four open changes already amend it.
- `src/SyndicateVault.sol`, `src/SyndicateGovernor.sol`, `src/GovernorParameters.sol` (`_protocolMaxStrategyDuration` becomes `internal`), `src/interfaces/ISyndicateVault.sol` (new error). No storage change, no new external function.
- Operations: a stray token in the vault can no longer be handed to the owner or a third party. To recover one, rescue it to a clone of the vault and settle that clone in a later proposal.
