# Guardian Staking Specification

## Purpose

Defines the guardian-side economic core of Sherwood held in `StakedWood` (sWOOD), the sole WOOD custodian: guardian registration and staking, the unstake request/cancel/claim lifecycle, age-weighted vote checkpoints, the review-path and verdict-path slash mechanics with their severity envelope, the `authorizedSlasher` role, and the exposure-ledger/coverage-freezer gates on stake release.

## Requirements

### Requirement: Guardian staking and registration
`stakeAsGuardian(amount, agentId)` SHALL transfer `amount` WOOD from the caller into sWOOD custody and credit the caller's guardian stake. On a first stake (previous stake zero) it SHALL record `agentId` and anchor the stake-age clock (`stakedAt`) to the current timestamp; on top-ups the `agentId` argument SHALL be ignored. The resulting total stake MUST be at least `minGuardianStake`, or the call SHALL revert `InsufficientStake`. A guardian with a pending unstake request MUST NOT top up (revert `UnstakeAlreadyRequested`) — topping up while inactive would grow the quorum denominator without creating votable weight. Staking SHALL NOT be gated by any pause mechanism. Each stake SHALL push the guardian's votable-stake checkpoint, the guardian's liability checkpoint, and the global total-stake checkpoint, increase `totalGuardianStake`, and emit `GuardianStaked(guardian, amount, agentId)`.

#### Scenario: First stake registers the guardian
- **WHEN** an address with no stake calls `stakeAsGuardian` with `amount >= minGuardianStake`
- **THEN** the WOOD is pulled into sWOOD, `stakedAt` is set to now, the `agentId` is recorded, the guardian becomes active, and `GuardianStaked` is emitted

#### Scenario: Stake below the minimum
- **WHEN** a caller stakes such that their resulting total would be below `minGuardianStake`
- **THEN** the call reverts `InsufficientStake`

#### Scenario: Top-up while unstake is pending
- **WHEN** a guardian with a pending unstake request calls `stakeAsGuardian`
- **THEN** the call reverts `UnstakeAlreadyRequested`; the guardian must first cancel the request

### Requirement: Stake-age re-anchor on top-up
A top-up SHALL re-anchor `stakedAt` to the stake-weighted average timestamp `ceil((oldStake * stakedAt + amount * now) / newTotal)`, rounding toward `now`, so new WOOD matures pro-rata rather than inheriting the position's age. This closes the "stake dust early, top up the whale position later, inherit full maturity" hole. Rounding MUST never grant free age.

#### Scenario: Top-up ages in pro-rata
- **WHEN** an aged guardian tops up an existing stake
- **THEN** `stakedAt` moves forward to the stake-weighted average of the old anchor and now, and the position's age factor drops proportionally

### Requirement: Active-guardian status
A guardian SHALL be active if and only if `stakedAmount > 0` and no unstake request is pending (`unstakeRequestedAt == 0`). `isActiveGuardian(guardian)` SHALL expose this predicate; the guardian registry consults it to gate review voting.

#### Scenario: Requesting unstake deactivates
- **WHEN** an active guardian calls `requestUnstakeGuardian`
- **THEN** `isActiveGuardian` returns false immediately, before any cooldown elapses

### Requirement: Unstake request
`requestUnstakeGuardian()` SHALL revert `NoActiveStake` when the caller has no stake and `UnstakeAlreadyRequested` when a request is already pending. A successful request SHALL: stamp `unstakeRequestedAt = now`; freeze the current `coolDownPeriod` into the request (`cooldownAtRequest`) so the owner cannot retroactively extend a guardian's lockup by raising the cooldown mid-request; re-anchor `stakedAt = now` (pre-request age is forfeited, but maturation keeps accruing from the request instant, including through the cooldown); subtract the guardian's stake from `totalGuardianStake`; push a zero votable-stake checkpoint and an updated total-stake checkpoint; and emit `GuardianUnstakeRequested`. The liability checkpoint SHALL NOT be pushed on request — a request revokes votability, not what the guardian already underwrote. Requesting SHALL remain open at any time; only the release (claim) waits on obligations.

#### Scenario: Request revokes voting power immediately
- **WHEN** a guardian requests unstake
- **THEN** its votable-stake checkpoint drops to 0 and `totalGuardianStake` excludes it, while WOOD remains in sWOOD custody

#### Scenario: Cooldown frozen at request time
- **WHEN** the owner raises `coolDownPeriod` after a guardian has requested unstake
- **THEN** the guardian's claim eligibility still uses the cooldown value frozen at request time

#### Scenario: Liability survives the request
- **WHEN** a guardian requests unstake
- **THEN** its liability checkpoint at any past or current instant is unchanged, so a slash sized after the request still recovers against the full bond

### Requirement: Unstake cancel
`cancelUnstakeGuardian()` SHALL revert `UnstakeNotRequested` when no request is pending, and `NoActiveStake` when the guardian was fully slashed between request and cancel (a cancel must not resurrect a ghost guardian with no stake). A successful cancel SHALL clear the request, re-add the stake to `totalGuardianStake`, restore the votable-stake checkpoint to the current staked amount, push the total-stake checkpoint, and emit `GuardianUnstakeCancelled`. A request-then-cancel round trip yields a stake aged from the request timestamp, not from the original stake and not from the cancel.

#### Scenario: Cancel restores votability
- **WHEN** a guardian with a pending request cancels it
- **THEN** its votable weight (aged from the request timestamp) and its contribution to the quorum denominator are restored

#### Scenario: Cancel after full slash
- **WHEN** a guardian was slashed to zero while its unstake request was pending and then calls `cancelUnstakeGuardian`
- **THEN** the call reverts `NoActiveStake`

### Requirement: Unstake claim gated by cooldown and open coverage
`claimUnstakeGuardian()` SHALL revert `UnstakeNotRequested` without a pending request and `CooldownNotElapsed` before `unstakeRequestedAt + cooldownAtRequest`. When an exposure ledger is wired (`exposureLedger != address(0)`), the claim SHALL additionally revert `CoverageStillOpen` while the guardian has either non-zero open underwriting exposure (`openExposureUsd != 0`) or any frozen coverage (`hasFrozenCoverage == true`). The gate binds the claim, not the request. When no ledger is wired the coverage gate SHALL be skipped (deliberate fail-open for the deploy/upgrade window; the deploy script asserts the wiring). A successful claim SHALL delete the guardian record entirely (deregistration — a later re-stake may record a different `agentId` and starts a fresh age clock), push a zero liability checkpoint (the moment liability actually ends), transfer the WOOD to the guardian, and emit `GuardianUnstakeClaimed`.

#### Scenario: Claim before cooldown
- **WHEN** a guardian claims before the frozen cooldown has elapsed
- **THEN** the call reverts `CooldownNotElapsed`

#### Scenario: Claim blocked by open exposure
- **WHEN** the cooldown has elapsed but the exposure ledger reports non-zero `openExposureUsd` for the guardian
- **THEN** the claim reverts `CoverageStillOpen` until the exposure runs down

#### Scenario: Claim blocked by frozen coverage
- **WHEN** the coverage freezer (the challenge game, via the ledger's `onlyFreezer` role) has frozen coverage naming the guardian, and the guardian's cooldown has elapsed
- **THEN** `hasFrozenCoverage` is true and the claim reverts `CoverageStillOpen` — an accused approver cannot exit its bond before the challenge resolves, because the frozen commitment does not expire on a clock

#### Scenario: Claim with no ledger wired
- **WHEN** `exposureLedger` is unset (zero) and the cooldown has elapsed
- **THEN** the claim succeeds without any coverage check (documented fail-open state)

#### Scenario: Successful claim deregisters
- **WHEN** all gates pass and the guardian claims
- **THEN** the guardian struct is deleted, the liability checkpoint drops to zero at that instant, and the WOOD leaves sWOOD

### Requirement: Age-weighted vote weight
A guardian's vote weight SHALL be its raw votable own-stake checkpoint discounted by a linear age factor: the factor ramps from `ageFloorBps` (bps of raw stake) at age 0 to par (10,000 bps) at `maturationPeriod`, then plateaus at par. Age is measured from the live `stakedAt` anchor (not checkpointed); a past read whose timestamp precedes the current anchor saturates to age 0, so anchor drift is deflation-only — a past read can only report less weight than was live, never more. Weight MUST never exceed raw stake. `getPastVotes(guardian, ts)` SHALL return `rawOwnCheckpoint(ts) * ageFactorBps(stakedAt, ts) / 10_000`; `getVotes(account)` SHALL return the live equivalent (`getPastVotes` at the current timestamp). A guardian with a pending unstake request has a zero votable checkpoint and therefore zero weight.

#### Scenario: Fresh stake votes at the floor
- **WHEN** a guardian's stake was anchored at the read timestamp (age 0)
- **THEN** its vote weight is `ageFloorBps` of its raw checkpointed stake

#### Scenario: Matured stake votes at par
- **WHEN** the stake's age at the read timestamp is at least `maturationPeriod`
- **THEN** its vote weight equals its raw checkpointed stake

#### Scenario: Unstake-requested guardian has zero weight
- **WHEN** `getPastVotes` is evaluated at a timestamp after the guardian's unstake request
- **THEN** the result is 0 (the request pushed a zero votable checkpoint)

### Requirement: Distinct vote-read bases — aged, raw, and total
sWOOD SHALL expose three deliberately distinct historical reads. `getPastVotes` is the AGE-WEIGHTED per-guardian weight (correct for weighing a vote). `getPastStake(guardian, ts)` is the RAW votable own-stake checkpoint — the same basis `getPastTotalVotes` sums, so the two are comparable and subtractable; it reads the checkpoint directly with no live, re-anchorable factor, denying an accused approver the lever of requesting unstake to shrink its own contribution to a participation floor. `getPastTotalVotes(ts)` (and its alias `getPastTotalSupply(ts)`) SHALL return the raw total-active-stake checkpoint: totals stay RAW because aging only shrinks numerators, so the raw denominator is a conservative (upper-bound) quorum denominator — the aged per-account weights sum to at most the total. `getPastVotes` is NOT a term of `getPastTotalVotes`; consumers subtracting from the total MUST use `getPastStake`. sWOOD SHALL NOT implement the full OZ `IVotes` interface (no `delegate`/`delegates`/`delegateBySig`); the read surface exists for Snapshot's `erc20-votes` strategy and on-chain consumers.

#### Scenario: Raw and aged reads diverge on young stake
- **WHEN** a guardian's stake is younger than `maturationPeriod` at timestamp `ts`
- **THEN** `getPastStake(g, ts)` returns the full raw checkpoint while `getPastVotes(g, ts)` returns the age-discounted fraction

#### Scenario: Conservative quorum denominator
- **WHEN** any set of guardians' aged weights (`getPastVotes`) at `ts` are summed
- **THEN** the sum never exceeds `getPastTotalVotes(ts)`

#### Scenario: Unstake request cannot shrink the raw basis retroactively
- **WHEN** a guardian requests unstake after timestamp `ts`
- **THEN** `getPastStake(g, ts)` still returns the pre-request checkpointed amount

### Requirement: Dual checkpoint traces — votability versus liability
sWOOD SHALL maintain two per-guardian timestamp-keyed traces answering different questions. The votable trace (`getPastStake` basis) is pushed on stake, unstake request (to 0), cancel, and slash. The liability trace — what the guardian is on the hook for at a past instant — is pushed on stake, on slash, and on claim (to 0), and deliberately NOT on request or cancel, which change only votability. Sharing one trace would let an approver discharge its liability with a free, reversible `requestUnstakeGuardian` sent before the drain it voted for executed, so a later conviction sized at or after execution would recover nothing.

#### Scenario: Exit pre-positioning does not void a conviction
- **WHEN** an approver requests unstake after approving a proposal and a slash is later sized at an anchor after the request
- **THEN** the slash basis reads the liability trace, which still carries the full bond, and the conviction recovers against it

### Requirement: Review-path slash (registry-only)
`slashGuardians(reviewKey, openedAt, approvers, slashBps)` SHALL be callable only by the wired guardian registry (revert `NotRegistry` otherwise). For each approver it SHALL burn `slashBps` (bps of 10,000) of the approver's own stake, sized off the greater of the liability and votable checkpoints at `openedAt` and clamped to live stake (a concurrent slash may already have reduced it). Age discounts voting power, not liability: the slash basis is raw staked amount, never age-discounted. For a still-active approver the slash decrements `totalGuardianStake` and re-checkpoints votable stake; for an unstake-requested approver the aggregate was already decremented at request time, and a slash to zero clears the request stamp so no ghost guardian survives. The liability trace re-checkpoints on both branches. `GuardianSlashed(reviewKey, approver, ownSlash, delegatedSlash)` SHALL be emitted only when a non-zero amount was slashed; `delegatedSlash` is always 0 (DPoS delegation removed; parameter retained for ABI compatibility). The aggregate total-stake checkpoint is pushed once after the loop and the total is burned in a single transfer. The severity supplied by the registry is deterministic — a quadratic ramp of block-side decisiveness bounded to `[minSlashBps, maxSlashBps]` (see the guardian-review capability).

#### Scenario: Non-registry caller
- **WHEN** any address other than the wired registry calls `slashGuardians`
- **THEN** the call reverts `NotRegistry`

#### Scenario: Slash sized at review open, clamped to live
- **WHEN** an approver's checkpointed stake at `openedAt` exceeds its live stake at slash time
- **THEN** the slash is computed on the live (smaller) amount

#### Scenario: Fully slashed guardian mid-request
- **WHEN** an unstake-requested approver is slashed to zero stake
- **THEN** its `unstakeRequestedAt` stamp is cleared, so a later `cancelUnstakeGuardian` cannot resurrect it

#### Scenario: Slashed WOOD burns
- **WHEN** `slashGuardians` slashes a non-zero total
- **THEN** the total is transferred to the dead burn address in one transfer

### Requirement: Verdict-path slash to escrow (authorizedSlasher-only)
`slashToEscrow(caseKey, openedAt, approvers, slashBpsPer, vault, snapshotTimestamp, bountyTo, bountyBps)` SHALL be callable only by `authorizedSlasher` (revert `NotAuthorizedSlasher` otherwise) and SHALL route slash proceeds to victim compensation instead of burning. Preconditions, each reverting: `compensationEscrow` unset → `CompensationEscrowNotSet`; `openedAt` in the future → `VerdictNotPast`; `snapshotTimestamp > openedAt` → `SnapshotAfterVerdict`; `slashBpsPer.length != approvers.length` → `SlashBpsLengthMismatch`; `bountyBps > MAX_CONVICTION_BOUNTY_BPS` → `InvalidParameter` (enforced unconditionally, even with a zero `bountyTo`); `vault` not factory-deployed (`governorOf(vault) == 0`) → `VaultNotFactoryDeployed`; any address repeated within `approvers` → `DuplicateApprover` (zero-rate entries are not exempt from the duplicate scan). The timestamp bounds are honest-caller sanity checks only — they do not constrain a compromised slasher, which chooses both timestamps freely. Per approver: a zero rate SHALL be skipped entirely (zero is the absence of liability, not a severity to floor); an approver already slashed under the same `caseKey` by an earlier call SHALL revert `ApproverAlreadySlashed`; each non-zero rate SHALL be clamped per-element to `[minSlashBps, maxSlashBps]`; the slash leg is the same own-stake leg as the review path (sized at `openedAt` off `max(liability, votable)`, clamped to live). The per-`(caseKey, approver)` mark SHALL be recorded only when the slash actually recovered a non-zero amount, so a zero take does not consume the verdict's one slash and foreclose a retry after re-stake. The mark (readable via `verdictSlashed(caseKey, approver)`) makes the severity envelope bind per VERDICT, not merely per call — splitting a quorum-sized batch across transactions stays legal, replaying an approver does not. The event topic key SHALL be namespaced (`keccak256("sherwood.verdict" ‖ caseKey)`) so a crafted `caseKey` cannot make a verdict slash collide with a review key in `GuardianSlashed` topics.

#### Scenario: Unauthorized caller
- **WHEN** an address other than `authorizedSlasher` calls `slashToEscrow`
- **THEN** the call reverts `NotAuthorizedSlasher`

#### Scenario: Rate clamped to the envelope
- **WHEN** the slasher passes a non-zero per-approver rate outside `[minSlashBps, maxSlashBps]`
- **THEN** the rate is silently clamped into the envelope before the slash is applied

#### Scenario: Zero rate slashes nothing
- **WHEN** an approver's `slashBpsPer` entry is 0
- **THEN** that approver is skipped — no slash, no floor applied, and its one-slash-per-verdict mark is not consumed

#### Scenario: Replay within one verdict
- **WHEN** a second `slashToEscrow` call under the same `caseKey` names an approver whose earlier slash recovered WOOD
- **THEN** the call reverts `ApproverAlreadySlashed`, so severity cannot compound past the ceiling by splitting a verdict across transactions

#### Scenario: Retry after a zero take
- **WHEN** an earlier call under the `caseKey` found the approver with no live stake (zero take) and the approver later re-stakes
- **THEN** a retried call may slash them — the at-open basis is unchanged and the mark was never set

### Requirement: Conviction bounty and escrow routing
When `slashToEscrow` recovers a non-zero total: if `bountyTo != address(0)` and `bountyBps != 0`, a bounty of `total * bountyBps / 10_000` SHALL be transferred to `bountyTo` first and `ConvictionBountyPaid` emitted; the remainder is what funds compensation. The bounty rate is bounded by `MAX_CONVICTION_BOUNTY_BPS = 2_000` (20%) enforced in sWOOD itself, so a compromised slasher can divert at most that fraction of any one call to a caller-named address — the remainder can only ever reach the owner-set escrow or the burn address (per call, not per guardian: fresh case keys compound across calls). The net total SHALL be approved to `compensationEscrow` and `openCase(vault, snapshotTimestamp, total)` invoked; on success the allowance is zeroed and `VerdictSlashRouted(caseKey, vault, total, caseId)` is emitted with the NET total. If `openCase` reverts with a recoverable input/wiring error (`SnapshotNotPast`, `ZeroAddress`, `NothingToCompensate`, `NotAuthorizedFunder`, `EmptySnapshot`), the whole transaction SHALL re-revert so the corrected call can be resubmitted (the slash rolls back too). Any other failure (missing ERC20Votes surface, block-number clock mode, empty returndata) SHALL NOT brick the verdict: the slash stands, the net proceeds burn, and `VerdictSlashUncompensated(caseKey, vault, total)` marks the case as never funded. The bounty is deliberately not clawed back on the burn fallback — depositors recover nothing on that path either way. When nothing was recovered across all approvers, no case is opened and `(0, 0)` is returned.

#### Scenario: Successful verdict funds a case
- **WHEN** `slashToEscrow` recovers WOOD and `openCase` succeeds
- **THEN** the net-of-bounty total funds the escrow case pinned to `snapshotTimestamp` and `VerdictSlashRouted` reports the net figure and case id

#### Scenario: Excessive bounty rate
- **WHEN** the slasher passes `bountyBps > 2_000`
- **THEN** the call reverts `InvalidParameter` — it is never silently clamped, because a caller-chosen payout address must not be laundered into a smaller diversion

#### Scenario: Unpriceable vault burns instead of bricking
- **WHEN** `openCase` fails for a vault the escrow can never apportion against
- **THEN** the guardians stay slashed, the net proceeds burn, and `VerdictSlashUncompensated` is emitted

#### Scenario: Recoverable escrow error re-reverts
- **WHEN** `openCase` reverts with a fixable caller/wiring error such as `SnapshotNotPast`
- **THEN** the entire transaction reverts (including the slash marks) so a corrected call runs clean, and nothing burns

### Requirement: authorizedSlasher and compensationEscrow roles
`setAuthorizedSlasher(slasher)` and `setCompensationEscrow(escrow)` SHALL be owner-only and freely re-wireable (not set-once); zero is a valid value for either and disables the verdict path (`slashToEscrow` reverts `CompensationEscrowNotSet` when the escrow is zero; no caller matches a zero slasher). Each setter SHALL emit its event (`AuthorizedSlasherSet`, `CompensationEscrowSet`). The verdict-slash role SHALL be distinct from the registry role by design: the review slash and the verdict slash must never share a caller, so the registry's appeal reserve can never refund a proven-malice verdict. The escrow is owner-set STATE, deliberately not a `slashToEscrow` parameter — sWOOD custodies every WOOD bond in the protocol, and a caller-named sink would hand the slasher an allowance against that whole balance. The role is intended for the challenge game; until it is wired, a verdict is effectively a governance action by the owner-set slasher.

#### Scenario: Verdict path disabled
- **WHEN** `compensationEscrow` is zero
- **THEN** `slashToEscrow` reverts `CompensationEscrowNotSet` regardless of caller

#### Scenario: Role separation
- **WHEN** the registry attempts to call `slashToEscrow`, or the authorized slasher attempts `slashGuardians`
- **THEN** each reverts (`NotAuthorizedSlasher` / `NotRegistry`) — the two slash paths never share a caller role

### Requirement: Burn resilience
Slashed WOOD SHALL be burned by transfer to the dead address `0x…dEaD`. A WOOD transfer that reverts or returns false MUST NOT brick the slash: the amount is queued in a pending-burn balance, `PendingBurnRecorded` is emitted, and the permissionless `flushBurn()` retries the transfer atomically (`BurnFlushed` on success; state update and transfer revert together on failure). `pendingBurn()` exposes the queued amount.

#### Scenario: Broken token cannot block slashing
- **WHEN** the burn transfer inside a slash fails
- **THEN** the slash accounting stands, the amount is queued, and anyone may later call `flushBurn` to retry

### Requirement: Staking and slash parameters
All parameters SHALL be owner-set (the parameter-setter multisig, with an external delay — no on-chain timelock), each setter emitting `ParameterChangeFinalized(paramKey, oldValue, newValue)`. Bounds: `minGuardianStake >= 1e18`; `coolDownPeriod` in `[1 days, 30 days]` AND, once the registry is wired, `>= registry.reviewPeriod()` (revert `CooldownBelowReviewPeriod`) — the cross-contract invariant that closes slash-evasion, so a guardian who voted in an unresolved review cannot claim out before `resolveReview` runs; `minSlashBps <= maxSlashBps` and `maxSlashBps <= 10_000` (a full 100% own-stake ceiling is legal — the own bond is a plain integer subtraction with no share math to brick); `ageFloorBps` in `[1, 10_000]`; `maturationPeriod` in `[7 days, 90 days]`. Violations revert `InvalidParameter`. `initialize` SHALL enforce the same bounds on its seed values and reject zero owner/wood/factory addresses. The registry enforces the same cooldown/review invariant from its side (`setReviewPeriod` rejects a review window exceeding sWOOD's cooldown).

#### Scenario: Cooldown below the review window
- **WHEN** the owner attempts to set `coolDownPeriod` below the wired registry's `reviewPeriod`
- **THEN** the call reverts `CooldownBelowReviewPeriod`

#### Scenario: Envelope ordering preserved
- **WHEN** the owner attempts `setMinSlashBps(v)` with `v > maxSlashBps`, or `setMaxSlashBps(v)` with `v < minSlashBps` or `v > 10_000`
- **THEN** the call reverts `InvalidParameter`

#### Scenario: Maturation bounds
- **WHEN** the owner attempts to set `maturationPeriod` outside `[7 days, 90 days]` or `ageFloorBps` to 0 or above 10,000
- **THEN** the call reverts `InvalidParameter`

### Requirement: Registry and ledger wiring
`setRegistry(registry)` SHALL be owner-only and set-once (revert `RegistryAlreadySet` on a second call; zero rejected) — the registry deploys after sWOOD, so it cannot be an `initialize` argument. `setExposureLedger(ledger)` SHALL be owner-only and SHALL accept zero deliberately: zero is the documented fail-open state for the claim gate, reachable if the ledger is ever replaced or found broken; the deploy pipeline, not the contract, asserts a non-zero wiring. It SHALL emit `ExposureLedgerSet`.

#### Scenario: Registry cannot be rewired
- **WHEN** the owner calls `setRegistry` a second time
- **THEN** the call reverts `RegistryAlreadySet`

#### Scenario: Ledger can be unset
- **WHEN** the owner calls `setExposureLedger(address(0))`
- **THEN** the pointer clears and `claimUnstakeGuardian` reverts to ungated (cooldown-only) behavior

### Requirement: Coverage-freezer interaction surface
The coverage freezer is a role on the exposure ledger (`coverageFreezer`, held by the challenge game), not on sWOOD; its effect on staking SHALL flow exclusively through the ledger reads sWOOD consumes at claim time (`openExposureUsd`, `hasFrozenCoverage`). A freeze pins one proposal's committed coverage — never the guardian's whole stake — and while any coverage naming the guardian is frozen, the guardian's `claimUnstakeGuardian` SHALL revert `CoverageStillOpen`. A freeze MUST NOT block `requestUnstakeGuardian`, `cancelUnstakeGuardian`, or review voting eligibility (those depend only on sWOOD-local state); it binds only the moment stake would actually leave custody. Open exposure ages out on the ledger's clock, but a freeze does not — it holds until the freezer unfreezes, so an accused approver cannot wait out a challenge on wall-clock alone.

#### Scenario: Frozen guardian can still request but not claim
- **WHEN** a guardian's coverage is frozen by the challenge game
- **THEN** the guardian may request unstake (going inactive and taking no new commitments) but its claim reverts `CoverageStillOpen` until the freeze is lifted

#### Scenario: Freeze lifted, exposure clear
- **WHEN** the freezer unfreezes the guardian's last frozen coverage and its open exposure has run down to zero
- **THEN** a claim after the frozen cooldown succeeds
