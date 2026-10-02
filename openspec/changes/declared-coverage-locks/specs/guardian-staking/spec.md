## MODIFIED Requirements

### Requirement: Review-path slash (registry-only)
`slashGuardians(reviewKey, openedAt, approvers, slashBps)` SHALL be callable only by the wired guardian registry (revert `NotRegistry` otherwise). For each approver it SHALL burn `slashBps` (bps of 10,000) of the approver's slash basis — the greater of the liability and votable checkpoints at `openedAt`, clamped to live stake (a concurrent slash may already have reduced it). The rate supplied for each approver SHALL be computed by the registry as `clamp(ceil(lockBps × severity / 10_000), minSlashBps, maxSlashBps)`, where `lockBps` is the approver's WOOD lock for the review over that same basis (the ledger's `slashBpsForAt` at the review-open instant, see the guardian-coverage capability) and `severity` is the review's deterministic severity — so the amount burned is `min(lock, basis) × severity / 10_000` unless the envelope binds, never a fraction of the whole bond chosen independently of the lock. The envelope `[minSlashBps, maxSlashBps]` SHALL be the one SNAPSHOTTED AT REVIEW OPEN — never the live values — so `minSlashBps` is the floor a guardian cannot declare their way under, while the owner cannot raise what an already-decided review costs between open and resolve. The staking contract SHALL NOT apply the live envelope in either direction: not the live floor (the owner could raise what a decided review costs) and not the live ceiling (the owner could zero `maxSlashBps` between open and resolve and nullify the burn). Its only cap SHALL be the arithmetic saturation at 10,000 bps, a constant no role controls. The adversary of both rules is the sWOOD owner — the same multisig that owns the registry — changing the envelope after a review has opened to punish, or to spare, a specific cohort against the terms they voted under. A rate whose lock-times-severity product is zero SHALL be passed as zero, never as the raw lock rate. Age discounts voting power, not liability: the slash basis is raw staked amount, never age-discounted. For a still-active approver the slash decrements `totalGuardianStake` and re-checkpoints votable stake; for an unstake-requested approver the aggregate was already decremented at request time, and a slash to zero clears the request stamp so no ghost guardian survives. The liability trace re-checkpoints on both branches. `GuardianSlashed(reviewKey, approver, ownSlash, delegatedSlash)` SHALL be emitted only when a non-zero amount was slashed; `delegatedSlash` is always 0 (parameter retained for ABI compatibility). The aggregate total-stake checkpoint is pushed once after the loop and the total is burned in a single transfer. The severity is a quadratic ramp of block-side decisiveness bounded to the at-open envelope. The adversary is a guardian who backed a bad proposal with a small lock while holding a large bond: they lose the lock scaled by severity, and never less than `minSlashBps` of the basis.

#### Scenario: Non-registry caller
- **WHEN** any address other than the wired registry calls `slashGuardians`
- **THEN** the call reverts `NotRegistry`

#### Scenario: Slash sized at review open, clamped to live
- **WHEN** an approver's checkpointed stake at `openedAt` exceeds its live stake at slash time
- **THEN** the slash is computed on the live (smaller) amount

#### Scenario: Burn tracks the lock, not the bond
- **WHEN** an approver whose basis is 2,000 WOOD locked 500 WOOD on the reviewed proposal, the review's severity is 10,000 bps, and the envelope does not bind
- **THEN** 500 WOOD is burned and 1,500 WOOD remains staked, covering the approver's other locks

#### Scenario: Envelope floors a small lock
- **WHEN** an approver's lock-and-severity rate is below the `minSlashBps` snapshotted at review open
- **THEN** the burn is that at-open `minSlashBps` of the basis, not the smaller lock

#### Scenario: Owner cannot raise the floor on a decided review
- **WHEN** the owner raises `minSlashBps` after a review has opened and before it resolves Blocked
- **THEN** the approvers are floored at the value in force at open; the raise applies only to reviews opened afterwards

#### Scenario: Fully slashed guardian mid-request
- **WHEN** an unstake-requested approver is slashed to zero stake
- **THEN** its `unstakeRequestedAt` stamp is cleared, so a later `cancelUnstakeGuardian` cannot resurrect it

#### Scenario: Slashed WOOD burns
- **WHEN** `slashGuardians` slashes a non-zero total
- **THEN** the total is transferred to the dead burn address in one transfer

### Requirement: Verdict-path slash to escrow (authorizedSlasher-only)
`slashVerdict(caseKey, openedAt, approvers, slashBpsPer)` SHALL be callable only by `authorizedSlasher` (revert `NotAuthorizedSlasher` otherwise) and SHALL BURN its proceeds — the protocol makes no compensation promise to depositors. Preconditions, each reverting: `openedAt` in the future → `VerdictNotPast`; `openedAt == 0` → `InvalidParameter` (a real verdict never anchors at the zero timestamp, and that key has no checkpoint, so the call would silently void itself); `slashBpsPer.length != approvers.length` → `SlashBpsLengthMismatch`; any address repeated within `approvers` → `DuplicateApprover` (zero-rate entries are not exempt from the duplicate scan). The verdict takes no vault address, no snapshot timestamp and no payee: nothing is apportioned, so it needs no opinion about which vault the verdict concerned. The `openedAt` bound is an honest-caller sanity check only — it does not constrain a compromised slasher, which chooses it freely. Per approver: a zero rate SHALL be skipped entirely (zero is the absence of liability, not a severity to floor); an approver already slashed under the same `caseKey` by an earlier call SHALL revert `ApproverAlreadySlashed`; each non-zero rate SHALL be clamped per-element to `[minSlashBps, maxSlashBps]`; the slash leg is the same own-stake leg as the review path (sized off `max(liability, votable)` looked up one second before `openedAt`, clamped to live). The rate the challenge game supplies is the approver's WOOD lock for the case over that basis, so the amount is `min(lock, basis)` unless the envelope binds. The per-`(caseKey, approver)` mark SHALL be recorded only when the slash actually recovered a non-zero amount, so a zero take does not consume the verdict's one slash and foreclose a retry after re-stake. The mark (readable via `verdictSlashed(caseKey, approver)`) makes the severity envelope bind per VERDICT, not merely per call — splitting a quorum-sized batch across transactions stays legal, replaying an approver does not. The event topic key SHALL be namespaced (`keccak256("sherwood.verdict" ‖ caseKey)`) so a crafted `caseKey` cannot make a verdict slash collide with a review key in `GuardianSlashed` topics.

#### Scenario: Unauthorized caller
- **WHEN** an address other than `authorizedSlasher` calls `slashVerdict`
- **THEN** the call reverts `NotAuthorizedSlasher`

#### Scenario: Rate clamped to the envelope
- **WHEN** the slasher passes a non-zero per-approver rate outside `[minSlashBps, maxSlashBps]`
- **THEN** the rate is silently clamped into the envelope before the slash is applied

#### Scenario: Burn tracks the lock, not the bond
- **WHEN** a convicted approver's lock over its basis is 2,500 bps and the envelope does not bind
- **THEN** a quarter of their basis — the lock — is burned, and the remainder stays staked behind their other locks

#### Scenario: Zero rate slashes nothing
- **WHEN** an approver's `slashBpsPer` entry is 0
- **THEN** that approver is skipped — no slash, no floor applied, and its one-slash-per-verdict mark is not consumed

#### Scenario: Replay within one verdict
- **WHEN** a second `slashVerdict` call under the same `caseKey` names an approver whose earlier slash recovered WOOD
- **THEN** the call reverts `ApproverAlreadySlashed`, so severity cannot compound past the ceiling by splitting a verdict across transactions

#### Scenario: Retry after a zero take
- **WHEN** an earlier call under the `caseKey` found the approver with no live stake (zero take) and the approver later re-stakes
- **THEN** a retried call may slash them — the at-open basis is unchanged and the mark was never set
