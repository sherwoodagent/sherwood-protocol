# tier-policy (delta)

## ADDED Requirements

### Requirement: The deterministic clone address binds the vault and the deployer
`StrategyFactory.cloneAndInitDeterministic(template, vault, proposer, data, salt)` SHALL deploy at the CREATE2 address with salt `keccak256(abi.encode(vault, msg.sender, salt))`, so a third party replaying `salt` from the mempool lands at a different address and cannot seat its own init data where the proposer's propose expects the clone. Off-chain predictors SHALL fold the deployer the same way.

#### Scenario: A front-run lands elsewhere
- **WHEN** a stranger calls `cloneAndInitDeterministic` with the proposer's `salt` before the proposer does
- **THEN** the stranger's clone lands at a different address, and the proposer's call still lands at `predictDeterministicAddress(template, keccak256(abi.encode(vault, proposer, salt)), factory)`
