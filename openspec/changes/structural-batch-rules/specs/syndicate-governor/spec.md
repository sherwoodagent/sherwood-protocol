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

### Requirement: Settlement and P&L
`settleProposal` SHALL be callable on an `Executed` proposal by anyone after `executedAt + strategyDuration`, and by the proposer after only `executedAt + 1 hours` (the minimum self-settle delay that prevents a single-block execute-and-skim). Settlement SHALL run the pre-committed settlement calls via `executeGovernorBatch` with a net-outflow budget of ZERO: the settle batch may bring assets home (net inflow or zero) and SHALL revert `MaxNetOutflowExceeded(netOutflow, 0)` on any net asset egress, so the proposal's `effectiveMaxCapital` bounds the whole lifecycle's egress rather than each leg. Per-call settlement caps still meter the gross a settlement call may move. Then finalize: P&L SHALL be computed as the vault's asset-balance delta versus the capital snapshot minus the vault's interim LP net flow (deposits/withdrawals during the strategy are principal, not performance); state SHALL move to `Settled`, the active-proposal marker cleared, and the open count decremented before external fee transfers; the vault SHALL be notified via `onProposalSettled` after fees so queued flows settle against post-fee NAV.

#### Scenario: Non-proposer must wait full duration
- **WHEN** a caller other than the proposer calls `settleProposal` before `executedAt + strategyDuration`
- **THEN** the call SHALL revert with `StrategyDurationNotElapsed`

#### Scenario: Proposer early settle
- **WHEN** the proposer calls `settleProposal` at least 1 hour after execution but before `strategyDuration` elapses
- **THEN** settlement SHALL proceed

#### Scenario: A settle batch cannot move assets out
- **WHEN** the settlement calls approve a registered strategy and it pulls one unit of the asset from the vault
- **THEN** `settleProposal` reverts `MaxNetOutflowExceeded(1, 0)` and the proposal stays `Executed`

#### Scenario: A settle batch that brings assets home succeeds
- **WHEN** the settlement calls make the strategy return what the execute batch deployed
- **THEN** `settleProposal` succeeds and the vault's balance is back to its pre-execute level

### Requirement: Emergency settlement paths
For a proposal stuck in `Executed` past `executedAt + strategyDuration`, the vault owner SHALL have two escape hatches. (1) `unstick`: run the governance-approved pre-committed settlement calls (no guardian review required, no owner stake required — the calls were already voted on) under the same zero net-outflow budget as `settleProposal`, then finalize settlement. (2) Owner-supplied calls: `emergencySettleWithCalls` SHALL require the owner's bonded stake in the guardian registry to meet the required owner bond, and SHALL open a guardian review on the registry keyed by the hash of the supplied calls; `cancelEmergencySettle` withdraws an open review; `finalizeEmergencySettle` SHALL, after the registry review resolves, revert with `EmergencySettleBlocked` if guardians blocked it, otherwise execute the registry-stored calls under the proposal's `effectiveMaxCapital` net-outflow budget — the one settle path with egress, because an owner unwind may need to fund a repay from the vault to free stuck collateral, and it is guardian-reviewed and owner-bonded for that — and finalize settlement. All emergency entrypoints SHALL require the caller to be the vault owner, the proposal to be in `Executed` state, and SHALL share the governor's reentrancy lock.

#### Scenario: Unstick before duration elapses is rejected
- **WHEN** the vault owner calls `unstick` or `emergencySettleWithCalls` before `executedAt + strategyDuration`
- **THEN** the call SHALL revert with `StrategyDurationNotElapsed`

#### Scenario: Guardians block owner-supplied emergency calls
- **WHEN** the guardian review of an emergency settle reaches block quorum
- **THEN** `finalizeEmergencySettle` SHALL revert with `EmergencySettleBlocked` and the owner-supplied calls SHALL never execute

#### Scenario: Unstick replays the settle batch with zero egress
- **WHEN** the pre-committed settlement calls would move assets out of the vault, at any coverage level
- **THEN** `unstick` reverts `MaxNetOutflowExceeded(netOutflow, 0)` exactly as `settleProposal` does
