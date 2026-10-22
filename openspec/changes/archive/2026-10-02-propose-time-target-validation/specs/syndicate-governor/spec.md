# syndicate-governor (delta)

## MODIFIED Requirements

### Requirement: Proposal creation validation
`propose` SHALL only be callable by a registered agent of the governor's vault, and SHALL validate: the `vault` argument equals the governor's bound vault; `strategyDuration` is within `[minStrategyDuration, maxStrategyDuration]`; `executeCalls` and `settlementCalls` are both non-empty and each at most 64 calls; `metadataURI` is at most 512 bytes; `envelope.maxCapital` is nonzero and at most `totalAssets() * maxCapitalBps / 10_000` at propose time; and `envelope.maxDrawdownBps` is at most 10_000. The proposal SHALL snapshot at propose time: the agent performance fee (clamped to `maxPerformanceFeeBps`), the protocol and guardian fee bps and recipients from ProtocolConfig, the strategy's `selfManagesFees` flag, and the risk envelope — all immutable for the proposal's lifetime.

`propose` SHALL additionally reject any entry of `executeCalls` or `settlementCalls` whose `target` the vault's privileged-batch-target predicate flags (the vault itself or its bound withdrawal queue), reverting `DisallowedBatchTarget(target)` — the same error the vault's execution-time guard raises for the same violation. The check SHALL consume the vault's own predicate view rather than restating the address set in the governor, so the propose-time and execution-time answers cannot diverge. The check covers ONLY the unconditional privileged-target denylist: the registry-gated selector half of the batch guard depends on mutable state (allowlist demotion; codehash-sensitive `isAdapterAllowed`) and SHALL NOT be evaluated at propose, because a propose-time pass over it proves nothing about settle time. If the vault does not expose the predicate view (a pre-upgrade vault), `propose` SHALL skip this check rather than revert — the execution-time guard in `executeGovernorBatch` remains the authoritative enforcement on every batch path regardless of whether the propose-time check ran.

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

#### Scenario: Settlement call naming the withdrawal queue rejected at propose
- **WHEN** a registered agent calls `propose` with a `settlementCalls` entry whose `target` is the vault's bound withdrawal queue
- **THEN** the call SHALL revert with `DisallowedBatchTarget(queue)` at propose — the proposal is never stored, voted, or executed, instead of being discovered only when `settleProposal` reverts permanently with the proposal stuck in `Executed` and redemptions locked

#### Scenario: Execute call naming the vault rejected at propose
- **WHEN** a registered agent calls `propose` with an `executeCalls` entry whose `target` is the vault itself
- **THEN** the call SHALL revert with `DisallowedBatchTarget(vault)` at propose, sparing a vote cycle on a proposal `executeProposal` could never run

#### Scenario: Vault without the predicate view degrades open
- **GIVEN** a governor upgraded ahead of a vault that does not expose the privileged-target predicate view
- **WHEN** a registered agent calls `propose` with calls that name the withdrawal queue
- **THEN** `propose` SHALL accept the proposal (the propose-time check is skipped, never a hard failure), and `executeGovernorBatch` SHALL still reject the batch with `DisallowedBatchTarget` when it runs — the authoritative layer is unchanged

### Requirement: Fee distribution waterfall
On a positive P&L, unless the proposal's snapshotted `selfManagesFees` flag is true (which skips the entire governor fee waterfall), the governor SHALL distribute, in order: (1) protocol fee = gross profit × snapshotted `protocolFeeBps` to the snapshotted protocol recipient; (2) guardian fee = gross profit × snapshotted `guardianFeeBps` to the snapshotted guardians recipient, emitting `GuardianFeeAccrued` only when the transfer actually delivers; (3) agent performance fee = net profit × the propose-time performance fee, re-clamped at settle to the live `maxPerformanceFeeBps` (emitting `FeeClamped` when the clamp fires), split across active co-proposers by their `splitBps` with the remainder to the lead proposer; (4) management fee = remaining net × the vault's live `managementFeeBps` to the vault owner. Any individual fee transfer that reverts (e.g. a blacklisted recipient) SHALL be escrowed against `(vault, recipient, token)` instead of reverting settlement, emitting `FeeTransferFailed`; recipients pull escrowed amounts later via `claimUnclaimedFees`, which SHALL zero the escrow slot before transferring and only pay from the vault that owes it.

`claimUnclaimedFees` SHALL carry the governor's reentrancy latch (`nonReentrant`) like every other state-changing governor entrypoint. This is uniformity and defence-in-depth, not the closure of a live hole: the CEI ordering (escrow slot zeroed before the external transfer) remains the primary defense, and the traced reentrant path is inert under real configurations (a mid-batch caller resolves to the vault address, whose escrow slot is only populated if a fee recipient literally equals the vault). The accompanying code documentation SHALL state this honestly rather than implying a vulnerability was fixed.

#### Scenario: Settlement never bricks on a bad recipient
- **WHEN** a fee recipient's transfer reverts during settlement
- **THEN** the amount SHALL be recorded in the unclaimed-fees escrow, the rest of the waterfall SHALL continue, and the proposal SHALL still reach `Settled`

#### Scenario: Guardian fee attribution only on delivery
- **WHEN** the guardian-fee transfer escrows instead of delivering
- **THEN** `GuardianFeeAccrued` SHALL NOT be emitted (preventing the off-chain airdrop bot from double-paying)

#### Scenario: Inactive co-proposer skipped
- **WHEN** a co-proposer is no longer a registered agent at settlement
- **THEN** their share SHALL be skipped, and the co-proposer distribution SHALL never pay out more than the total agent fee

#### Scenario: Self-managed fees opt out
- **WHEN** the proposal's strategy declared `selfManagesFees() == true` at propose time
- **THEN** settlement SHALL skip the entire fee waterfall, reading the propose-time snapshot rather than a live strategy call

#### Scenario: Mid-batch reentrant claim reverts instead of no-oping
- **GIVEN** a governor entrypoint holding the reentrancy latch through `executeGovernorBatch` (execute, settle, or an emergency path)
- **WHEN** a batch sub-call re-enters `claimUnclaimedFees`
- **THEN** the call SHALL revert `Reentrancy` (previously it returned harmlessly on an empty escrow slot), failing the batch that attempted it

#### Scenario: Ordinary escrow claim unaffected by the latch
- **WHEN** a recipient with a populated escrow slot calls `claimUnclaimedFees` outside any governor call frame
- **THEN** the claim SHALL pay out exactly as before — the latch changes nothing for the legitimate pull path
