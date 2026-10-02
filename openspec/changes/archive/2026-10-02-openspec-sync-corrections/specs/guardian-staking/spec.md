## MODIFIED Requirements

### Requirement: Stake-age re-anchor on top-up
A top-up SHALL re-anchor `stakedAt` to the stake-weighted average timestamp `ceil((oldStake * stakedAt + amount * now) / newTotal)`, rounding toward `now`, so new WOOD matures pro-rata rather than inheriting the position's age. Rounding MUST never grant free age. The anchor feeds only the age-weighted `getPastVotes` read, which no protocol contract consumes; every on-chain vote weighs raw stake.

#### Scenario: Top-up ages in pro-rata
- **WHEN** an aged guardian tops up an existing stake
- **THEN** `stakedAt` moves forward to the stake-weighted average of the old anchor and now, and the position's `getPastVotes` age factor drops proportionally

### Requirement: Unstake cancel
`cancelUnstakeGuardian()` SHALL revert `UnstakeNotRequested` when no request is pending, and `NoActiveStake` when the guardian was fully slashed between request and cancel (a cancel must not resurrect a ghost guardian with no stake). A successful cancel SHALL clear the request, re-add the stake to `totalGuardianStake`, restore the votable-stake checkpoint to the current staked amount, push the total-stake checkpoint, and emit `GuardianUnstakeCancelled`. A request-then-cancel round trip leaves the `getPastVotes` age measured from the request timestamp, not from the original stake and not from the cancel.

#### Scenario: Cancel restores votability
- **WHEN** a guardian with a pending request cancels it
- **THEN** its votable-stake checkpoint and its contribution to the quorum denominator are restored, and its `getPastVotes` age is measured from the request timestamp

#### Scenario: Cancel after full slash
- **WHEN** a guardian was slashed to zero while its unstake request was pending and then calls `cancelUnstakeGuardian`
- **THEN** the call reverts `NoActiveStake`

### Requirement: Unstake claim gated by cooldown and open coverage
`claimUnstakeGuardian()` SHALL revert `UnstakeNotRequested` without a pending request and `CooldownNotElapsed` before `unstakeRequestedAt + cooldownAtRequest`. When an exposure ledger is wired (`exposureLedger != address(0)`), the claim SHALL additionally revert `CoverageStillOpen` while the guardian has either non-zero open underwriting exposure (`openExposure != 0`, in WOOD) or any frozen or pinned coverage (`hasFrozenCoverage == true`). The gate binds the claim, not the request. When no ledger is wired the coverage gate SHALL be skipped (deliberate fail-open for the deploy/upgrade window; the post-deploy verification asserts the wiring). A successful claim SHALL delete the guardian record entirely (deregistration — a later re-stake may record a different `agentId` and starts a fresh age clock), push a zero liability checkpoint (the moment liability actually ends), transfer the WOOD to the guardian, and emit `GuardianUnstakeClaimed`.

#### Scenario: Claim before cooldown
- **WHEN** a guardian claims before the frozen cooldown has elapsed
- **THEN** the call reverts `CooldownNotElapsed`

#### Scenario: Claim blocked by open exposure
- **WHEN** the cooldown has elapsed but the exposure ledger reports non-zero `openExposure` for the guardian
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

### Requirement: Dual checkpoint traces — votability versus liability
sWOOD SHALL maintain two per-guardian timestamp-keyed traces answering different questions. The votable trace (`getPastStake` basis) is pushed on stake, unstake request (to 0), cancel, and on a non-zero slash of a still-active guardian. The liability trace — what the guardian is on the hook for at a past instant — is pushed on stake, on a non-zero slash, and on claim (to 0), and deliberately NOT on request or cancel, which change only votability. Sharing one trace would let an approver discharge its liability with a free, reversible `requestUnstakeGuardian` sent before the drain it voted for executed, so a later conviction sized at or after execution would recover nothing.

#### Scenario: Exit pre-positioning does not void a conviction
- **WHEN** an approver requests unstake after approving a proposal and a slash is later sized at an anchor after the request
- **THEN** the slash basis reads the liability trace, which still carries the full bond, and the conviction recovers against it

### Requirement: Staking and slash parameters
All parameters SHALL be owner-set (the protocol Safe, with any delay enforced off-chain — no on-chain timelock), each setter emitting `ParameterChangeFinalized(paramKey, oldValue, newValue)`. Setter bounds: `minGuardianStake >= 1e18`; `coolDownPeriod` in `[1 days, 30 days]` AND, once the registry is wired, `>= registry.reviewPeriod()` (revert `CooldownBelowReviewPeriod`) — the cross-contract invariant that closes slash-evasion, so a guardian who voted in an unresolved review cannot claim out before `resolveReview` runs; `minOwnerStake` either 0 (open onboarding) or at least `MIN_OWNER_BOND_FLOOR` (1,000 WOOD); `minSlashBps <= maxSlashBps` and `maxSlashBps <= 10_000` (a full 100% own-stake ceiling is legal — the own bond is a plain integer subtraction with no share math to brick); `ageFloorBps` in `[1, 10_000]`; `maturationPeriod` in `[7 days, 90 days]`. Violations revert `InvalidParameter`. `initialize` SHALL reject zero owner/wood/factory addresses (`ZeroAddress`) and enforce the `minOwnerStake`, slash-envelope, `ageFloorBps` and `maturationPeriod` bounds on its seed values; it does not bound `minGuardianStake` or `coolDownPeriod`, so a deployment must seed them within the setter bounds. The registry enforces the same cooldown/review invariant from its side (`setReviewPeriod` rejects a review window exceeding sWOOD's cooldown).

#### Scenario: Cooldown below the review window
- **WHEN** the owner attempts to set `coolDownPeriod` below the wired registry's `reviewPeriod`
- **THEN** the call reverts `CooldownBelowReviewPeriod`

#### Scenario: Envelope ordering preserved
- **WHEN** the owner attempts `setMinSlashBps(v)` with `v > maxSlashBps`, or `setMaxSlashBps(v)` with `v < minSlashBps` or `v > 10_000`
- **THEN** the call reverts `InvalidParameter`

#### Scenario: Maturation bounds
- **WHEN** the owner attempts to set `maturationPeriod` outside `[7 days, 90 days]` or `ageFloorBps` to 0 or above 10,000
- **THEN** the call reverts `InvalidParameter`

### Requirement: authorizedSlasher role
`setAuthorizedSlasher(slasher)` SHALL be owner-only and freely re-wireable (not set-once); zero is a valid value and disables the verdict path, since no caller matches a zero slasher. The setter SHALL emit `AuthorizedSlasherSet`. The verdict-slash role is intended to be distinct from the registry role — the review slash and the verdict slash must never share a caller, so the registry's appeal reserve can never refund a proven-malice verdict — but the setter does not reject the registry's address: keeping them distinct is an owner obligation. The verdict takes no sink parameter — proceeds burn inside sWOOD, so there is no destination a caller could name and no allowance against the protocol's WOOD custody to hand out. The role is intended for the challenge game; until it is wired, a verdict is effectively a governance action by the owner-set slasher.

#### Scenario: Verdict path disabled
- **WHEN** `authorizedSlasher` is zero
- **THEN** no caller can reach `slashVerdict` — it reverts `NotAuthorizedSlasher`

#### Scenario: Role separation
- **WHEN** the authorized slasher is the challenge game and the registry attempts to call `slashVerdict`, or the authorized slasher attempts `slashGuardians`
- **THEN** each reverts (`NotAuthorizedSlasher` / `NotRegistry`) — the two slash paths do not share a caller while the roles are wired to different contracts

### Requirement: Coverage-freezer interaction surface
The coverage freezer is a role on the exposure ledger (`coverageFreezer`, held by the challenge game), not on sWOOD; its effect on staking SHALL flow exclusively through the ledger reads sWOOD consumes at claim time (`openExposure`, `hasFrozenCoverage`). A freeze pins one proposal's committed coverage — never the guardian's whole stake — and while any coverage naming the guardian is frozen, or a pin set by a re-armed challenge window is in force (through its deadline, inclusive), the guardian's `claimUnstakeGuardian` SHALL revert `CoverageStillOpen`. A freeze MUST NOT block `requestUnstakeGuardian`, `cancelUnstakeGuardian`, or review voting eligibility (those depend only on sWOOD-local state); it binds only the moment stake would actually leave custody. Open exposure ages out on the ledger's clock, but a freeze does not — it holds until the freezer unfreezes, so an accused approver cannot wait out a challenge on wall-clock alone.

#### Scenario: Frozen guardian can still request but not claim
- **WHEN** a guardian's coverage is frozen by the challenge game
- **THEN** the guardian may request unstake (going inactive and taking no new commitments) but its claim reverts `CoverageStillOpen` until the freeze is lifted

#### Scenario: Freeze lifted, exposure clear
- **WHEN** the freezer unfreezes the guardian's last frozen coverage, no pin on the guardian is in force, and its open exposure has run down to zero
- **THEN** a claim after the frozen cooldown succeeds
