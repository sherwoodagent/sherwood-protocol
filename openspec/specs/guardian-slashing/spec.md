# guardian-slashing Specification

## Purpose
Defines how much a convicted guardian loses, where that value goes, and what the
protocol does and does not promise depositors. Slashing is punitive and
deterrent: it makes approving a malicious proposal strictly loss-making for the
approver. It is not an indemnity mechanism, and the protocol does not reimburse
depositors for losses.
## Requirements
### Requirement: All slashed WOOD is burned

Every slash path SHALL send its proceeds to the burn address, net of the
conviction bounty where one applies. No slash path SHALL route proceeds to any
depositor, shareholder, claimant, treasury, or address chosen by the caller.

#### Scenario: Verdict slash proceeds

- **WHEN** a verdict slash convicts one or more approvers
- **THEN** the proceeds net of the conviction bounty are transferred to the burn address
- **AND** no compensation case, claim, or escrow entry is created

#### Scenario: Review slash proceeds

- **WHEN** the registry slashes approvers for a blocked review
- **THEN** 100% of the proceeds are transferred to the burn address

#### Scenario: Owner bond slash proceeds

- **WHEN** an owner bond is slashed on emergency settlement
- **THEN** 100% of the bond is transferred to the burn address

#### Scenario: Burn transfer fails

- **WHEN** the burn transfer reverts or returns false
- **THEN** the slash accounting still takes effect
- **AND** the amount is recorded as pending burn for later permissionless retry

### Requirement: Verdict slash rate is punitive and independent of the loss

The verdict slash rate SHALL be the configured severity ceiling for every
approver the exposure ledger names, and SHALL NOT be derived from the proposal's
required coverage, the realized loss, or any per-approver allocation of either.

#### Scenario: Approver convicted

- **WHEN** an approver is convicted on a verdict
- **THEN** their slash is the severity ceiling applied to their bond snapshotted at the verdict anchor

#### Scenario: Proposal understates its required coverage

- **WHEN** a proposal declares required coverage below the value actually extractable
- **THEN** the slash applied to each convicted approver is unchanged
- **AND** the approver's loss does not shrink as a result of the understatement

#### Scenario: Approver released their commitment

- **WHEN** an approver changed their vote and their reservation was released before the verdict
- **THEN** that approver is not slashed

### Requirement: Conviction bounty is paid from gross proceeds

Where a conviction bounty applies, it SHALL be computed from gross proceeds
before the burn and SHALL be bounded by the protocol's bounty ceiling. The
bounty ceiling SHALL be enforced by the slashing contract itself and not
delegated to the caller.

#### Scenario: Contested challenge convicts

- **WHEN** a contested challenge results in conviction with a bounty recipient and rate
- **THEN** the bounty is transferred to that recipient
- **AND** the remaining proceeds are burned

#### Scenario: Bounty rate exceeds the ceiling

- **WHEN** a caller supplies a bounty rate above the protocol ceiling
- **THEN** the slash reverts

#### Scenario: Uncontested settlement

- **WHEN** a settlement is uncontested and names no bounty recipient
- **THEN** 100% of the proceeds are burned

### Requirement: The protocol does not compensate depositors

The protocol SHALL NOT provide any on-chain mechanism by which a depositor,
shareholder, or withdrawal-queue participant claims value originating from a
slash. Guardian coverage SHALL NOT be represented as insurance, indemnity, or
reimbursement of depositor losses in specifications, natspec, or user-facing
documentation.

#### Scenario: Depositor seeks recovery after a loss

- **WHEN** a vault suffers a loss from a proposal that was later convicted
- **THEN** no claim, redemption, or distribution path exists for the depositor to recover slashed value

#### Scenario: Guardian holds shares in the vault they approved

- **WHEN** a convicted guardian also holds shares in the affected vault
- **THEN** they receive no portion of their own slash

### Requirement: Approver coverage is an eligibility floor, not an indemnity

The exposure ledger SHALL continue to require that an executing proposal's
committed approvers jointly meet the proposal's required coverage, as a minimum
bonding threshold for the proposal's tier. This threshold SHALL NOT be
interpreted or documented as a guarantee that the loss can be recovered.

#### Scenario: Approvers are under-bonded for the tier

- **WHEN** the committed approvers' aggregate slashable bond is below the required coverage at execution
- **THEN** execution reverts

#### Scenario: Approvers meet the floor

- **WHEN** the committed approvers' aggregate slashable bond meets the required coverage
- **THEN** execution proceeds
- **AND** no promise is made that a subsequent slash recovers the loss

### Requirement: Slash accounting is independent of any external sink contract

Verdict slashing SHALL NOT depend on a call into an external compensation,
escrow, or distribution contract, and SHALL NOT accept a vault address or
snapshot timestamp for the purpose of apportioning proceeds.

#### Scenario: Slash executes with no external sink wired

- **WHEN** a verdict slash executes
- **THEN** it completes without calling any escrow or distribution contract
- **AND** it cannot fail for reasons originating in such a contract

#### Scenario: Gas reserved for the slash call

- **WHEN** the challenge game forwards gas to the slash call
- **THEN** the reserved amount reflects the absence of an external sink call and is derived from measured cost

