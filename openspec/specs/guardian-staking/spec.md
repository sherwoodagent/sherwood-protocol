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
`slashVerdict(caseKey, openedAt, approvers, slashBpsPer, contestors, bountyTo, bountyBps)` SHALL be callable only by `authorizedSlasher` (revert `NotAuthorizedSlasher` otherwise) and SHALL BURN its proceeds — the protocol makes no compensation promise to depositors. Preconditions, each reverting: `openedAt` in the future → `VerdictNotPast`; `slashBpsPer.length != approvers.length`, or `contestors.length != approvers.length` → `SlashBpsLengthMismatch`; `bountyBps > MAX_CONVICTION_BOUNTY_BPS` → `InvalidParameter` (enforced unconditionally, even with a zero `bountyTo`); any address repeated within `approvers` → `DuplicateApprover` (zero-rate entries are not exempt from the duplicate scan). The verdict takes no vault address and no snapshot timestamp: nothing is apportioned, so it needs no opinion about which vault the verdict concerned. The `openedAt` bound is an honest-caller sanity check only — it does not constrain a compromised slasher, which chooses it freely. Per approver: a zero rate SHALL be skipped entirely (zero is the absence of liability, not a severity to floor); an approver already slashed under the same `caseKey` by an earlier call SHALL revert `ApproverAlreadySlashed`; each non-zero rate SHALL be clamped per-element to `[minSlashBps, maxSlashBps]`; the slash leg is the same own-stake leg as the review path (sized at `openedAt` off `max(liability, votable)`, clamped to live). The per-`(caseKey, approver)` mark SHALL be recorded only when the slash actually recovered a non-zero amount, so a zero take does not consume the verdict's one slash and foreclose a retry after re-stake. The mark (readable via `verdictSlashed(caseKey, approver)`) makes the severity envelope bind per VERDICT, not merely per call — splitting a quorum-sized batch across transactions stays legal, replaying an approver does not. The event topic key SHALL be namespaced (`keccak256("sherwood.verdict" ‖ caseKey)`) so a crafted `caseKey` cannot make a verdict slash collide with a review key in `GuardianSlashed` topics.

#### Scenario: Unauthorized caller
- **WHEN** an address other than `authorizedSlasher` calls `slashVerdict`
- **THEN** the call reverts `NotAuthorizedSlasher`

#### Scenario: Rate clamped to the envelope
- **WHEN** the slasher passes a non-zero per-approver rate outside `[minSlashBps, maxSlashBps]`
- **THEN** the rate is silently clamped into the envelope before the slash is applied

#### Scenario: Zero rate slashes nothing
- **WHEN** an approver's `slashBpsPer` entry is 0
- **THEN** that approver is skipped — no slash, no floor applied, and its one-slash-per-verdict mark is not consumed

#### Scenario: Replay within one verdict
- **WHEN** a second `slashVerdict` call under the same `caseKey` names an approver whose earlier slash recovered WOOD
- **THEN** the call reverts `ApproverAlreadySlashed`, so severity cannot compound past the ceiling by splitting a verdict across transactions

#### Scenario: Retry after a zero take
- **WHEN** an earlier call under the `caseKey` found the approver with no live stake (zero take) and the approver later re-stakes
- **THEN** a retried call may slash them — the at-open basis is unchanged and the mark was never set

### Requirement: Conviction bounty and escrow routing
When `slashVerdict` recovers a non-zero total: if `bountyTo != address(0)` and `bountyBps != 0`, a bounty of `min(total × bountyBps / 10_000, contestorSlash)` SHALL be transferred to `bountyTo` and `ConvictionBountyPaid` emitted, where `contestorSlash` is the SUMMED slash of the approvers flagged in `contestors` — those who funded the counter-bond. That cap is load-bearing: the bounty is only owed when an approver funded the defence, a rule meant to price a staged contest by forcing the stager into the cohort its own conviction slashes, and the punitive rate breaks that pricing because the bounty is a share of the WHOLE cohort's bonds while a faker risks only its own. Capping at the contestors' own slash makes staging break-even at best for any parameter set. A contestor whose own slash landed at zero contributes nothing to the cap and so unlocks no bounty. The rate is additionally bounded by `MAX_CONVICTION_BOUNTY_BPS = 2_000` (20%) enforced in sWOOD itself, so a compromised slasher can divert at most that fraction of any ONE call to a caller-named address — the remainder can only ever reach `BURN_ADDRESS` (per call, not per guardian: fresh case keys compound across calls). The net remainder SHALL be burned via `_burnWood`, which parks the amount in `_pendingBurn` for a permissionless `flushBurn` retry if the WOOD transfer reverts or returns false, so a hostile token cannot brick a conviction whose accounting already landed. `VerdictSlashBurned(caseKey, gross, bounty, burned)` SHALL be emitted with `gross == bounty + burned`. When nothing was recovered across all approvers, `0` is returned and nothing is paid or burned.

#### Scenario: Successful verdict burns the remainder
- **WHEN** `slashVerdict` recovers WOOD
- **THEN** the net-of-bounty total is burned and `VerdictSlashBurned` reports gross, bounty and burned and case id

#### Scenario: Excessive bounty rate
- **WHEN** the slasher passes `bountyBps > 2_000`
- **THEN** the call reverts `InvalidParameter` — it is never silently clamped, because a caller-chosen payout address must not be laundered into a smaller diversion

#### Scenario: Staged contest cannot out-earn its own cost
- **WHEN** the only approver flagged in `contestors` forfeited less than `total × bountyBps / 10_000`
- **THEN** the bounty is capped at that approver's own slash, so manufacturing a contest is break-even at best

#### Scenario: Genuine defence is paid in full
- **WHEN** approvers whose summed slash exceeds the fee funded the counter-bond
- **THEN** the cap does not bind and the challenger receives the whole `bountyBps` share

### Requirement: authorizedSlasher role
`setAuthorizedSlasher(slasher)` SHALL be owner-only and freely re-wireable (not set-once); zero is a valid value and disables the verdict path, since no caller matches a zero slasher. The setter SHALL emit `AuthorizedSlasherSet`. The verdict-slash role SHALL be distinct from the registry role by design: the review slash and the verdict slash must never share a caller, so the registry's appeal reserve can never refund a proven-malice verdict. The verdict takes no sink parameter — proceeds burn inside sWOOD, so there is no destination a caller could name and no allowance against the protocol's WOOD custody to hand out. The role is intended for the challenge game; until it is wired, a verdict is effectively a governance action by the owner-set slasher.

#### Scenario: Verdict path disabled
- **WHEN** `authorizedSlasher` is zero
- **THEN** no caller can reach `slashVerdict` — it reverts `NotAuthorizedSlasher`

#### Scenario: Role separation
- **WHEN** the registry attempts to call `slashVerdict`, or the authorized slasher attempts `slashGuardians`
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

### Requirement: Incoming-owner consent for owner-stake slot transfer
Binding a prepared owner stake to a vault through the slot-transfer path (the factory's owner-rotation flow) SHALL require the incoming owner's prior, vault-specific consent, recorded on sWOOD by the incoming owner themselves. Adversary: a current vault owner who "gifts" a vault to a victim to spend the victim's escrowed prepared stake — locking it behind the owner-unstake cooldown and exposing it to an emergency-review owner-bond slash — must be unable to do so without the victim's opt-in.

`approveOwnerStakeBinding(vault)` SHALL record `vault` as the single vault the caller consents to have their prepared stake bound to via slot transfer; it SHALL reject the zero vault. Calling it again SHALL overwrite the previous approval (at most one approved vault per address). `revokeOwnerStakeBinding()` SHALL clear the caller's approval. Both SHALL emit events naming the approver and the vault.

`transferOwnerStakeSlot(vault, newOwner)` SHALL revert with `BindingNotApproved` unless `newOwner`'s recorded approval equals exactly `vault`, in addition to its existing guards (factory-only caller, prior slot cleared, prepared stake present, unbound, and at or above the floor). A successful transfer SHALL consume the approval (clear it), so one consent authorizes at most one bind.

Consent SHALL be scoped to a single escrow lifetime and never replayable against a later one: the approval SHALL also be cleared by `cancelPreparedStake` and by a fresh `prepareOwnerStake`. An approval standing without a live prepared stake SHALL be inert — the transfer's existing prepared-stake guards still reject the bind.

The creation-time bind (`bindOwnerStake`, reached only from the factory's `createSyndicate`) SHALL NOT require an approval: the bound stake there belongs to the creator who initiated the call, so consent is structural.

#### Scenario: Non-consensual rotation cannot spend a third party's escrow (issue #98 trace)
- **WHEN** Alice has a prepared, unbound stake at or above the floor and has never called `approveOwnerStakeBinding`, and the owner of a vault with an empty bond slot and no open proposals attempts the factory owner-rotation naming Alice as the new owner
- **THEN** the slot transfer SHALL revert with `BindingNotApproved`, Alice's prepared stake SHALL remain unbound, `cancelPreparedStake` SHALL still refund it, and Alice's own vault creation SHALL remain possible

#### Scenario: Consented rotation binds and consumes the approval
- **WHEN** the incoming owner has called `approveOwnerStakeBinding(vault)` and the factory rotation for that vault executes
- **THEN** the prepared stake SHALL bind to the vault under the incoming owner's name and the approval SHALL be cleared, so a second slot transfer naming the same incoming owner reverts (`BindingNotApproved` or the prepared-stake guards)

#### Scenario: Approval is vault-specific
- **WHEN** the incoming owner approved vault A and the factory rotation targets vault B
- **THEN** the slot transfer SHALL revert with `BindingNotApproved`

#### Scenario: Revocation restores the safe state
- **WHEN** an incoming owner approves a vault and then calls `revokeOwnerStakeBinding()` before the rotation lands
- **THEN** a subsequent slot transfer naming them SHALL revert with `BindingNotApproved`

#### Scenario: Stale approval does not survive the escrow lifecycle
- **WHEN** an address approves a vault, then cancels its prepared stake (or prepares a fresh stake after the prior one was bound)
- **THEN** the approval SHALL be cleared, and a slot transfer against the new escrow SHALL revert with `BindingNotApproved` until a fresh approval is given

