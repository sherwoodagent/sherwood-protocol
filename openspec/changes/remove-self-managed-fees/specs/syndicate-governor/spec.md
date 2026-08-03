# syndicate-governor (delta)

Deletes the `selfManagesFees` mechanism (#151): the propose-time snapshot of
the strategy's self-reported flag, and the settlement exemption it drove. Two
requirements change; no requirement is added or removed wholesale. The
remaining stale waterfall wording (pre-two-number model) is intentionally
untouched — see design.md "Spec debt noted, not taken".

## MODIFIED Requirements

### Requirement: Proposal creation validation

`propose` SHALL only be callable by a registered agent of the governor's vault, and SHALL validate: the `vault` argument equals the governor's bound vault; `strategyDuration` is within `[minStrategyDuration, maxStrategyDuration]`; `executeCalls` and `settlementCalls` are both non-empty and each at most 64 calls; `metadataURI` is at most 512 bytes; `envelope.maxCapital` is nonzero and at most `totalAssets() * maxCapitalBps / 10_000` at propose time; and `envelope.maxDrawdownBps` is at most 10_000. The proposal SHALL snapshot at propose time: the agent performance fee (clamped to `maxPerformanceFeeBps`), the protocol and guardian fee bps and recipients from ProtocolConfig, and the risk envelope — all immutable for the proposal's lifetime. `propose` SHALL NOT call the agent-supplied `strategy` address: the strategy carries no fee-exemption attestation to read, and no other agent-chosen code SHALL execute during proposal creation.

#### Scenario: Non-agent proposer rejected
- **WHEN** an address that is not a registered agent of the vault calls `propose`
- **THEN** the call SHALL revert with `NotRegisteredAgent`

#### Scenario: maxCapital ceiling enforced
- **WHEN** a proposer declares `envelope.maxCapital` greater than `totalAssets() * maxCapitalBps / 10_000`
- **THEN** the call SHALL revert with `MaxCapitalExceedsCeiling`

#### Scenario: Batch size and metadata caps
- **WHEN** `executeCalls.length` or `settlementCalls.length` exceeds 64, or `metadataURI` exceeds 512 bytes
- **THEN** the call SHALL revert with `TooManyCalls` or `MetadataURITooLong` respectively

#### Scenario: Strategy address is not probed at propose
- **WHEN** an agent calls `propose` with a `strategy` address that is an EOA or otherwise carries no code
- **THEN** proposal creation SHALL NOT revert on that account — the governor makes no call into the strategy at propose time (strategy provenance validation is deferred to the #58 clone-registry / #118 call-target-validation track, not a fee concern)

### Requirement: Fee distribution waterfall

On a positive P&L the governor SHALL distribute, in order: (1) protocol fee = gross profit × snapshotted `protocolFeeBps` to the snapshotted protocol recipient; (2) guardian fee = gross profit × snapshotted `guardianFeeBps` to the snapshotted guardians recipient, emitting `GuardianFeeAccrued` only when the transfer actually delivers; (3) agent performance fee = net profit × the propose-time performance fee, re-clamped at settle to the live `maxPerformanceFeeBps` (emitting `FeeClamped` when the clamp fires), split across active co-proposers by their `splitBps` with the remainder to the lead proposer; (4) management fee = remaining net × the vault's live `managementFeeBps` to the vault owner. No strategy-declared attribute SHALL exempt a proposal from any leg of the waterfall; whether a performance fee is charged SHALL depend only on vault-measured profit (the high-water mark), never on a strategy self-report. The performance-fee routine SHALL run on every settlement — even when no new above-high-water-mark fee is due — so that performance fees already crystallized from instant exiters are released and paid rather than stranded in the vault, permanently excluded from `totalAssets()`; the `chargeNew` seam that carries this rule is retained until the Lane A crystallization retirement (#54) determines its fate. Any individual fee transfer that reverts (e.g. a blacklisted recipient) SHALL be escrowed against `(vault, recipient, token)` instead of reverting settlement, emitting `FeeTransferFailed`; recipients pull escrowed amounts later via `claimUnclaimedFees`, which SHALL zero the escrow slot before transferring and only pay from the vault that owes it.

#### Scenario: Settlement never bricks on a bad recipient
- **WHEN** a fee recipient's transfer reverts during settlement
- **THEN** the amount SHALL be recorded in the unclaimed-fees escrow, the rest of the waterfall SHALL continue, and the proposal SHALL still reach `Settled`

#### Scenario: Guardian fee attribution only on delivery
- **WHEN** the guardian-fee transfer escrows instead of delivering
- **THEN** `GuardianFeeAccrued` SHALL NOT be emitted (preventing the off-chain airdrop bot from double-paying)

#### Scenario: Inactive co-proposer skipped
- **WHEN** a co-proposer is no longer a registered agent at settlement
- **THEN** their share SHALL be skipped, and the co-proposer distribution SHALL never pay out more than the total agent fee

#### Scenario: No strategy self-report can skip a fee leg
- **WHEN** a proposal whose `strategy` is any contract — including one that formerly would have attested to managing its own fees — settles with positive P&L
- **THEN** every fee leg SHALL be charged exactly as for a proposal with no strategy attached; the governor SHALL NOT read any fee-exemption signal from the strategy at propose or settle

#### Scenario: Crystallized instant-exit fees released on every settlement
- **WHEN** a proposal settles while the vault holds performance fees crystallized from instant exiters, and no new above-high-water-mark fee is due
- **THEN** settlement SHALL still release and distribute the crystallized amount through the performance-fee split, and SHALL still ratchet the high-water mark
