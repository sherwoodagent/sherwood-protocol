## MODIFIED Requirements

### Requirement: Proposal creation validation
`propose` SHALL only be callable by a registered agent of the governor's vault and, while the factory's `ownerOnlyProposals` is true, only by the vault owner and only without co-proposers; the flag SHALL be read live at propose time, so it binds agents registered before it was set. `propose` SHALL check, in this order: the `vault` argument equals the governor's bound vault (`VaultNotRegistered`); the caller is a registered agent (`NotRegisteredAgent`); the owner-only rule (`ProposerNotOwner`, `CollaborationDisabled`); the vault's owner bond is live (`OwnerBondNotLive`); no proposal is open on the vault (`VaultHasOpenProposal`); the settle cooldown has elapsed (`CooldownNotElapsed`); `strategy` is a strategy the protocol's `StrategyFactory` (resolved through the governor's tier registry) holds as registered with unchanged code (`StrategyNotRegistered(strategy)` — `address(0)`, an EOA and an unregistered contract are all refused); `strategyDuration` is at most both the vault's `maxStrategyDuration` and the protocol ceiling (`StrategyDurationTooLong`) and at least `minStrategyDuration` (`StrategyDurationTooShort`); `executeCalls` and `settlementCalls` are both non-empty (`EmptyExecuteCalls`, `EmptySettlementCalls`) and each at most 64 calls (`TooManyCalls`); every call in either batch obeys the vault's structural batch rules — a call whose target is not the vault's `asset()` names a registered strategy (`NotARegisteredStrategy(target)`, the vault's own error), and a call on the asset passes the same asset-call predicate the vault applies; `metadataURI` is at most 512 bytes (`MetadataURITooLong`); `envelope.maxCapital` is nonzero (`ZeroMaxCapital`); `envelope.maxDrawdownBps` is at most 10_000 (`InvalidDrawdown`); and the co-proposer rules. It SHALL then require one cap per call in each batch (`CallCapsLengthMismatch`), each batch's caps to sum to at most `maxCapital` (`CallCapsExceedMaxCapital`; zero caps are legal), `maxCapital` to be at most `totalAssets() * maxCapitalBps / 10_000` (`MaxCapitalExceedsCeiling`), and every call resolving to tier 2 to declare a cap at most `totalAssets() * tier2CallCapBps / 10_000` (`Tier2CallCapExceedsCeiling(index)`, the index within its own batch; checked at propose only). The proposal SHALL snapshot at propose time: the agent performance fee (clamped to `maxPerformanceFeeBps`, emitting `FeeClamped` when the clamp fires), the protocol and guardians fee recipients and the management and performance fee splits from ProtocolConfig, the risk envelope, the per-call caps, and the tier and required coverage priced per call through `tierOf` — all immutable for the proposal's lifetime. Beyond registration the `strategy` field names the proposal's strategy for observers and the vault's `strategyOf`, and settlement refuses to finish while it still answers `executed() == true`; the governor SHALL NOT probe the strategy's `proposer()` or `vault()` and SHALL NOT consult any registry allowlist for a call's target or recipient. The factory read SHALL be fail-closed: an unwired factory or one that does not answer registers nothing.

#### Scenario: Non-agent proposer rejected
- **WHEN** an address that is not a registered agent of the vault calls `propose`
- **THEN** the call SHALL revert with `NotRegisteredAgent`

#### Scenario: Owner-only proposals
- **WHEN** the factory's `ownerOnlyProposals` is true and a registered agent other than the vault owner calls `propose`
- **THEN** the call SHALL revert with `ProposerNotOwner`
- **AND** the vault owner, registered as an agent, SHALL propose as usual, while a proposal with co-proposers SHALL revert with `CollaborationDisabled`
- **AND** `setOwnerOnlyProposals(false)` SHALL restore proposing by every registered agent

#### Scenario: maxCapital ceiling enforced
- **WHEN** a proposer declares `envelope.maxCapital` greater than `totalAssets() * maxCapitalBps / 10_000`
- **THEN** the call SHALL revert with `MaxCapitalExceedsCeiling`

#### Scenario: Batch size and metadata caps
- **WHEN** `executeCalls.length` or `settlementCalls.length` exceeds 64, or `metadataURI` exceeds 512 bytes
- **THEN** the call SHALL revert with `TooManyCalls` or `MetadataURITooLong` respectively

#### Scenario: Caps must cover every call and fit the envelope
- **WHEN** a batch's caps array is shorter or longer than its calls array, or its caps sum to more than `maxCapital`
- **THEN** the call SHALL revert with `CallCapsLengthMismatch` or `CallCapsExceedMaxCapital` respectively

#### Scenario: Fee configuration snapshotted at propose
- **WHEN** the protocol multisig changes the fee splits or recipients in ProtocolConfig after a proposal is created
- **THEN** that proposal's settlement SHALL use the splits and recipients snapshotted at propose time, not the changed values

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
`settleProposal` SHALL be callable on an `Executed` proposal by anyone after `executedAt + strategyDuration`, and by the proposer after only `executedAt + 1 hours` (the minimum self-settle delay that prevents a single-block execute-and-skim). Settlement SHALL run the pre-committed settlement calls via `executeGovernorBatch` carrying the effective (coverage-scaled) settlement caps stored at execute and a net-outflow budget of ZERO: the settle batch may bring assets home (net inflow or zero) and SHALL revert `MaxNetOutflowExceeded(netOutflow, 0)` on any net asset egress, so the proposal's `effectiveMaxCapital` bounds the whole lifecycle's egress rather than each leg. Per-call settlement caps still meter the gross a settlement call may move. Settlement SHALL then revert `StrategyNotSettled(strategy)` while the proposal's strategy still answers `executed() == true`, and `SettlePriceBelowFloor(ppsNow, ppsFloor)` when the vault's price per share sits below the execute-time price less the proposal's declared `maxDrawdownBps` (capped at `MAX_STAMP_DRAWDOWN_BPS`, 9_000). Then finalize: P&L SHALL be computed as the vault's asset-balance delta versus the capital snapshot taken at execute; the management fee and then the performance fee SHALL be charged; the vault SHALL be notified via `onProposalSettled` after fees so queued flows settle against post-fee NAV; then the active-proposal marker SHALL be cleared, the state moved to `Settled`, and the open count decremented.

#### Scenario: Non-proposer must wait full duration
- **WHEN** a caller other than the proposer calls `settleProposal` before `executedAt + strategyDuration`
- **THEN** the call SHALL revert with `StrategyDurationNotElapsed`

#### Scenario: Proposer early settle
- **WHEN** the proposer calls `settleProposal` at least 1 hour after execution but before `strategyDuration` elapses
- **THEN** settlement SHALL proceed

#### Scenario: Interim LP flow excluded from P&L
- **WHEN** depositors try to add or remove principal while a strategy is live
- **THEN** instant deposits and redemptions are locked and queued requests sit in the withdrawal queue until the settle stamp, so the asset-balance delta settlement measures carries no interim LP flow and fees are charged only on strategy performance

#### Scenario: Settlement leg that does not unwind the strategy
- **WHEN** the settlement calls leave the proposal's strategy answering `executed() == true`
- **THEN** `settleProposal` and `unstick` SHALL revert with `StrategyNotSettled`; only the guardian-reviewed, owner-bonded `finalizeEmergencySettle` MAY close the proposal with the strategy still executed

#### Scenario: A settle batch cannot move assets out
- **WHEN** the settlement calls approve a registered strategy and it pulls one unit of the asset from the vault, within that call's cap
- **THEN** `settleProposal` reverts `MaxNetOutflowExceeded(1, 0)` and the proposal stays `Executed`

#### Scenario: A settle batch that brings assets home succeeds
- **WHEN** the settlement calls make the strategy return what the execute batch deployed and settle it, and the price per share is above the floor
- **THEN** `settleProposal` succeeds and the vault's balance is back to its pre-execute level
