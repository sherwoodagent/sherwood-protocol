## MODIFIED Requirements

### Requirement: Proposal creation validation
`propose` SHALL only be callable by a registered agent of the governor's vault, and SHALL validate: the `vault` argument equals the governor's bound vault; `strategy` is a strategy the protocol's `StrategyFactory` (resolved through the governor's tier registry) holds as registered with unchanged code (`StrategyNotRegistered(strategy)` otherwise — `address(0)`, an EOA and an unregistered contract are all refused); `strategyDuration` is within `[minStrategyDuration, maxStrategyDuration]`; `executeCalls` and `settlementCalls` are both non-empty and each at most 64 calls; every call in either batch whose target is not the vault's `asset()` names a registered strategy (`NotARegisteredStrategy(target)`, the vault's own error, read through the same factory path); `metadataURI` is at most 512 bytes; `envelope.maxCapital` is nonzero and at most `totalAssets() * maxCapitalBps / 10_000` at propose time; and `envelope.maxDrawdownBps` is at most 10_000. The proposal SHALL snapshot at propose time: the agent performance fee (clamped to `maxPerformanceFeeBps`), the protocol and guardian fee bps and recipients from ProtocolConfig, the strategy's `selfManagesFees` flag, the risk envelope, and the tier and required coverage priced per call through `tierOf` — all immutable for the proposal's lifetime. Beyond registration the `strategy` field is informational: it names the proposal's strategy for observers, the vault's `strategyOf` and the emergency `rescueTo`, and confers no admission; the governor SHALL NOT probe the strategy's `proposer()` or `vault()` and SHALL NOT consult any registry allowlist for a call's target or recipient. The factory read SHALL be fail-closed: an unwired factory or one that does not answer registers nothing.

#### Scenario: Non-agent proposer rejected
- **WHEN** an address that is not a registered agent of the vault calls `propose`
- **THEN** the call SHALL revert with `NotRegisteredAgent`

#### Scenario: maxCapital ceiling enforced
- **WHEN** a proposer declares `envelope.maxCapital` greater than `totalAssets() * maxCapitalBps / 10_000`
- **THEN** the call SHALL revert with `MaxCapitalExceedsCeiling`

#### Scenario: Batch size and metadata caps
- **WHEN** `executeCalls.length` or `settlementCalls.length` exceeds 64, or `metadataURI` exceeds 512 bytes
- **THEN** the call SHALL revert with `TooManyCalls` or `MetadataURITooLong` respectively

#### Scenario: Fee configuration snapshotted at propose
- **WHEN** the protocol multisig changes `protocolFeeBps` or `guardianFeeBps` after a proposal is created
- **THEN** that proposal's settlement SHALL use the rates and recipients snapshotted at propose time, not the changed values

#### Scenario: Two legs priced at their own tiers
- **WHEN** a proposal's execute batch calls a certified class-member clone (tier 1, bound `b1`) and an uncertified custom contract (tier 2, bound 10_000), with per-call caps `c1` and `c2`
- **THEN** `requiredCoverage == c1 * b1 / 10_000 + c2` and `envelopeTier == 2`

#### Scenario: Uncertified registered strategy is admitted at full coverage
- **WHEN** a proposal's execute batch calls a registered strategy no certification names
- **THEN** `propose` succeeds and the proposal prices at tier 2 with full-notional coverage

#### Scenario: The strategy field must be registered
- **WHEN** `strategy` is `address(0)`, an EOA, or a contract nobody registered
- **THEN** `propose` reverts `StrategyNotRegistered(strategy)`; once the contract is registered the same call succeeds and `getProposal(pid).strategy` is the address verbatim

#### Scenario: Unregistered batch target refused at propose
- **WHEN** any call in `executeCalls` or `settlementCalls` names the vault, the queue, the governor or any unregistered contract
- **THEN** `propose` reverts `NotARegisteredStrategy(target)` and nothing is stored
