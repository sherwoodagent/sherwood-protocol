## MODIFIED Requirements

### Requirement: Proposal creation validation
`propose` SHALL only be callable by a registered agent of the governor's vault, and SHALL validate: the `vault` argument equals the governor's bound vault; `strategyDuration` is within `[minStrategyDuration, maxStrategyDuration]`; `executeCalls` and `settlementCalls` are both non-empty and each at most 64 calls; no call in either batch targets a privileged protocol contract (`DisallowedBatchTarget`, answered by the vault's `isPrivilegedBatchTarget`); `metadataURI` is at most 512 bytes; `envelope.maxCapital` is nonzero and at most `totalAssets() * maxCapitalBps / 10_000` at propose time; and `envelope.maxDrawdownBps` is at most 10_000. The proposal SHALL snapshot at propose time: the agent performance fee (clamped to `maxPerformanceFeeBps`), the protocol and guardian fee bps and recipients from ProtocolConfig, the strategy's `selfManagesFees` flag, the risk envelope, and the tier and required coverage priced per call through `tierOf` — all immutable for the proposal's lifetime. The `strategy` field is informational: it names the proposal's strategy for observers and the vault's `strategyOf`, and confers no admission. Batch admission is structural (privileged denylist, asset-only-`approve`); the governor SHALL NOT consult any registry allowlist for a call's target or recipient.

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

#### Scenario: Uncertified strategy is admitted at full coverage
- **WHEN** a proposal's execute batch calls a contract no registry entry names
- **THEN** `propose` succeeds and the proposal prices at tier 2 with full-notional coverage
