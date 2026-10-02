## RENAMED Requirements

- FROM: `### Requirement: Verdict slash rate is punitive and independent of the loss`
- TO: `### Requirement: The slash is the approver's lock, floored at minSlashBps`

## MODIFIED Requirements

### Requirement: The slash is the approver's lock, floored at minSlashBps

An approver's slash SHALL be sized from its own WOOD lock on the proposal, not from the proposal's required coverage, the realized loss, or any pro-rata allocation of either. The slash basis is `min(max(liability, votable stake) one second before the anchor, live stake)`, anchored at `executedAt` for a verdict and at review open for a blocked review.

- **Verdict.** `ExposureLedger.slashBpsFor` returns `ceil(lock × 10_000 / basis)`, saturating at 10_000 when the lock meets or exceeds the basis. `StakedWood.slashVerdict` clamps it into `[minSlashBps, maxSlashBps]` and burns `basis × clampedRate / 10_000`, so the burn is `min(lock, basis)` rounded up to whole bps, raised to `minSlashBps × basis` and capped at `maxSlashBps × basis`.
- **Blocked review.** The registry multiplies the same lock rate by the block's severity (a quadratic ramp from `minSlashBps` at the block quorum to `maxSlashBps` at a 66.67% block), rounds up, and clamps the result into the `[minSlashBps, maxSlashBps]` envelope snapshotted at review open. An approver whose lock is its whole basis loses all of it only when the severity reaches 10,000 bps, which takes a block of at least 66.67% with `maxSlashBps` at 10,000.

A zero lock owes nothing and is skipped. `minSlashBps` is the single deterrence floor: a negligible lock still costs `minSlashBps` of the basis. Only an approver whose lock meets or exceeds its basis can lose its whole basis on a verdict, and only when `maxSlashBps` is 10,000.

#### Scenario: Approver convicted
- **WHEN** an approver with a 1,000,000 WOOD basis locked 50,000 WOOD and the proposal is convicted at `minSlashBps` = 10%
- **THEN** the rate is 500 bps, clamped up to 1,000 bps, and 100,000 WOOD is burned

#### Scenario: Approver convicted with a whole-stake lock
- **WHEN** an approver locked its entire basis and the proposal is convicted
- **THEN** the rate is 10_000 bps and, with `maxSlashBps` at 10,000, its whole basis is burned

#### Scenario: Proposal understates its required coverage
- **WHEN** a proposal declares required coverage below the value actually extractable
- **THEN** each convicted approver still loses its lock floored at `minSlashBps` of its basis; the understatement does not change the rate, and the burn is not raised to the whole bond

#### Scenario: Approver released their commitment
- **WHEN** an approver changed their vote and their lock was released before the verdict
- **THEN** that approver is not slashed

### Requirement: All slashed WOOD is burned

Every slash path SHALL send its proceeds to the burn address. No slash path SHALL route proceeds to any depositor, shareholder, claimant, treasury, challenger, or address chosen by the caller. The challenger's prosecutor fee is paid from the forfeited proposer bond, not from slash proceeds.

#### Scenario: Verdict slash proceeds

- **WHEN** a verdict slash convicts one or more approvers
- **THEN** 100% of the proceeds are transferred to the burn address
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

### Requirement: Approver coverage is an eligibility floor, not an indemnity

The exposure ledger SHALL measure, at execute, the covering approvers' locks, each valued at `min(lock, slashable stake) × woodPriceX8()`, against the proposal's required coverage. An empty approver set or a zero aggregate SHALL revert `InsufficientApproveCoverage`; a partial aggregate SHALL scale the proposal's executable capital and every per-call cap by `raised / required`. This measurement SHALL NOT be interpreted or documented as a guarantee that the loss can be recovered.

#### Scenario: Approvers are under-bonded for the tier

- **WHEN** the committed approvers' aggregate coverage is a nonzero fraction of the required coverage at execution
- **THEN** execution proceeds with `effectiveMaxCapital = maxCapital × raised / required`

#### Scenario: No covering approver

- **WHEN** a proposal with non-zero required coverage reaches execute with no approver or a zero aggregate
- **THEN** execution reverts `InsufficientApproveCoverage`

#### Scenario: Approvers meet the floor

- **WHEN** the committed approvers' aggregate coverage meets the required coverage
- **THEN** execution proceeds at full capital
- **AND** no promise is made that a subsequent slash recovers the loss

## REMOVED Requirements

### Requirement: Conviction bounty is paid from gross proceeds
**Reason**: No slash path pays a bounty. `StakedWood.slashVerdict` takes no recipient and burns every slashed unit; the challenger is paid a prosecutor fee from the forfeited proposer bond.
**Migration**: None. Readers looking for the challenger's reward read the challenge-game capability's prosecutor fee.
