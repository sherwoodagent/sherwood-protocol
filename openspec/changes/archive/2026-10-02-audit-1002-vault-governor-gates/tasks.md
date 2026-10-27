## 1. Rescue recipient (FP-04 token leg)

- [x] 1.1 `rescueERC20` admits only a factory clone whose `vault()` is this vault, read fail-closed; `ISyndicateVault.RescueRecipientNotStrategy(address)`.
- [x] 1.2 Regression test `test/audit-fixes/Vault_rescueERC20StrategyOnly.t.sol`; the two tests that rescued to an arbitrary address changed direction.

## 2. Protocol duration ceiling at propose (FP-13)

- [x] 2.1 `propose` compares against the vault maximum and `_protocolMaxStrategyDuration()` (now `internal`).
- [x] 2.2 Regression test `test/audit-fixes/Governor_protocolDurationCeilingAtPropose.t.sol`.

## 3. Queued-deposit claim gate (FP-17)

- [x] 3.1 `settleDeposit` is `whenNotPaused` and checks the receiver against the whitelist rule.
- [x] 3.2 Regression test `test/audit-fixes/Vault_queuedDepositClaimGate.t.sol`.

## 4. Docs

- [x] 4.1 `docs/deposit-withdraw-flow.md` and the `SyndicateVault` natspec.
