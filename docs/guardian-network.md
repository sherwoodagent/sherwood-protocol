# Guardian Network

> **Operating a guardian?** This file is the mechanism reference. The agent-facing
> runbook — per-proposal intake, Approve/Block policy, how to encode the vote —
> is the `network-guardian` skill in
> [`sherwoodagent/skill`](https://github.com/sherwoodagent/skill/blob/main/skills/network-guardian/SKILL.md).
> Vault-owner duties (veto, unstick, emergency settle) are the separate `guardian` skill there.

Guardians are staked-WOOD reviewers who inspect every strategy proposal's calldata
before it can execute, and who underwrite the capital it may extract. Their economics
run through these contracts:

| Contract | Role |
|---|---|
| `StakedWood.sol` (sWOOD) | sole WOOD custodian — guardian stake, owner bonds, vote checkpoints, slashing |
| `GuardianRegistry.sol` | review lifecycle + slash-appeal reserve; holds **zero assets** |
| `ExposureLedger.sol` | the exposure book — how much guardian stake backs which strategy |
| `TierRegistry.sol` | adapter-selector certification + the vault's adapter allowlist |
| `ChallengeGame.sol` | post-execution accountability: challenge, guardian vote, slash |

## Who runs the guardians today

Registration is permissionless in the contracts, and this section is about who
has actually registered. **Today the cohort is operator-run: one party operates
every guardian and holds essentially all staked WOOD.** That is a statement
about the current deployment, not about the mechanism.

Three consequences, recorded because each one is easy to overstate in the other
direction:

- **The review is a security service over third-party proposals**, not a check
  on the operator. It inspects calldata submitted by agents and vault owners. It
  provides no assurance against the operator, because the same party runs every
  reviewer.
- **Block quorum is not the binding constraint while that holds.** The operator
  clears `blockQuorumBps` from its own stake, so the veto's availability is an
  uptime question rather than a governance one. What *is* binding is dilution:
  `stakeAsGuardian` has no cap and no allowlist, so a third party parking stake
  raises the absolute weight the cohort must clear, costing them only capital.
- **A fleet of identically-configured daemons is not a quorum of independent
  reviewers.** They share one verdict path, so they agree by construction.
  Dissent between them comes only from differing policy — what warnings each
  accepts, how much each will underwrite — and not from posture.

Write it up as an operator-run cohort. Calling it a decentralised guardian
network would overstate what the layer currently provides.

The operational side — roles, key isolation, and the shared-simulation design —
is documented in the
[`sherwood-guardian`](https://github.com/sherwoodagent/sherwood-guardian) README.

## Becoming a guardian

Registration is permissionless: `StakedWood.stakeAsGuardian(amount, agentId)`
(`StakedWood.stakeAsGuardian`). No registry gate, no cap — only a stake floor. Active
means `stakedAmount > 0` and no pending unstake request.

| Parameter | Default | Min | Max | Setter |
|---|---|---|---|---|
| `minGuardianStake` | 10 000 WOOD | 1 WOOD | — | `StakedWood.setMinGuardianStake` |
| `coolDownPeriod` (unstake delay) | 7 d | 1 d | 30 d, and ≥ `registry.reviewPeriod` | `StakedWood.setCooldownPeriod` |
| `minOwnerStake` (vault-owner bond at creation) | 10 000 WOOD | 0 (open onboarding) or ≥ 1 000 | — | `StakedWood.setMinOwnerStake` |
| `minSlashBps` — the **deterrence floor**: the least a convicted approver loses, as a fraction of their whole bond, whatever WOOD they declared. Launch value is a governance decision; `DeployPlanB` refuses zero. | 10% | 0 | ≤ `maxSlashBps` | `StakedWood.setMinSlashBps` |
| `maxSlashBps` — must be 100%: a guardian may lock their entire stake behind one proposal, and a ceiling below that would cap the burn beneath the lock. `DeployPlanB` pre-flight asserts it. | 100% | ≥ `minSlashBps` | 100% | `StakedWood.setMaxSlashBps` |
| `ageFloorBps` (new-stake weight in `getPastVotes`; no on-chain reader) | 25% | > 0 | 100% | `StakedWood.setAgeFloorBps` |
| `maturationPeriod` (ramp to full weight in `getPastVotes`; no on-chain reader) | 30 d | 7 d | 90 d | `StakedWood.setMaturationPeriod` |

**Every guardian vote weighs raw stake.** No vote path applies an age discount:

| Vote | Ballot weight | Quorum base |
|---|---|---|
| Guardian review (`GuardianRegistry.voteOnProposal`) | `getPastStake(voter, snapshotAt)` | `getPastTotalVotes(snapshotAt)` at `openReview` |
| Emergency block (`GuardianRegistry.voteBlockEmergencySettle`) | `getPastStake(voter, snapshotAt)` (stored as `er.openedAt`) | `getPastTotalVotes(snapshotAt)` at `openEmergency` |
| Challenge (`ChallengeGame.voteOnChallenge`) | `min(getPastStake(voter, filedAt − 1), getPastStake(voter, snapshotAt))` | `getPastTotalVotes(filedAt − 1)`, accused capped, at `file` |

`snapshotAt` is the proposal's snapshot, one second before the block in which it
entered Pending, so stake checkpointed before that block votes at full weight.
The age-weighted getter `getPastVotes` (fresh stake at `ageFloorBps`, rising
linearly to full weight over `maturationPeriod`) is read by no contract on this
branch; it exists for off-chain Snapshot reads. The `getPastVotes` calls in
`SyndicateGovernor` read vault shares for the LP veto, not sWOOD.

**Cooldown binds review evasion:** `coolDownPeriod ≥ reviewPeriod` is enforced on
both sides, so a guardian can never unstake faster than a review they might be
slashed for.

## Guardian review of proposals

Timeline per proposal: `registerReview` (governor pushes the window at propose) →
`openReview` (permissionless, at `voteEnd`) → guardian votes → `resolveReview`
(permissionless, at `reviewEnd`).

| Parameter | Default | Min | Max | Where |
|---|---|---|---|---|
| `reviewPeriod` | 24 h | 6 h (mainnet immutable floor) | 3 d | `GuardianRegistry.setReviewPeriod` |
| `blockQuorumBps` | 30% | 10% | 100% | `GuardianRegistry.setBlockQuorumBps` |
| `LATE_VOTE_LOCKOUT_BPS` | last 10% of window | const | const | `GuardianRegistry` constant |
| `MAX_APPROVERS_PER_PROPOSAL` | 100 | const | const | `GuardianRegistry` constant — approvers only; blockers are uncapped (SHE-207) |

Mechanics worth knowing:

- Both sides of the block quorum are measured at the proposal's **snapshot**,
  `snapshotAt`: one second before the block in which the proposal entered
  Pending (`GuardianRegistry.registerReview`). That block is the
  `propose` block, or for a collaborative proposal the block of the last
  co-proposer approval (`ownerOnlyProposals`, on at launch, refuses
  collaborative proposals). `openReview` stores `getPastTotalVotes(snapshotAt)`
  as the denominator (`openReview`) and each vote weighs
  `getPastStake(voter, snapshotAt)` (`voteOnProposal`). Stake checkpointed at a timestamp
  earlier than that block counts; stake added in that block or later neither
  votes nor moves the bar. Stake that counts is in the denominator whether or
  not it votes. `blockQuorumBps` and the slash envelope
  are snapshotted at `openReview`.
- A thin cohort still decides its own reviews. There is no stake floor at open.
  Only a **zero** denominator fails open: `_isBlocked` returns false when
  `totalStakeAtOpen == 0` (`GuardianRegistry._isBlocked`), because
  `0 * 10_000 >= q * 0` would otherwise resolve Blocked with nobody participating
  and slash every approver. Any positive at-open stake, however small, can reach
  the block quorum.
- Votes are locked in the final 10% of the window (first votes *and* changes).
- **Approve votes are underwriting**, not just signaling: an approve vote carries a
  WOOD amount (`voteOnProposal(governor, proposalId, support, lockWood)`), and the
  `ExposureLedger` locks that WOOD behind the proposal, clamped to the guardian's
  free budget. See [Declared coverage locks](#declared-coverage-locks).
- A **blocked** review slashes every approver, and what is at stake is the
  **lock**, not the bond. The rate handed to `StakedWood` is the guardian's lock
  over their live stake; the block's severity — a deterministic quadratic ramp of
  block-side decisiveness, saturating at a 66.67% supermajority (`GuardianRegistry._severityBps`) — multiplies that lock-derived rate, and the result
  is clamped into `[minSlashBps, maxSlashBps]`. A guardian who backed a bad
  proposal with a small lock while holding a large bond loses the lock, and never
  less than `minSlashBps` of the bond.
- Slashed WOOD is **burned** (`0x…dEaD`) — the slash pays nobody. A funded
  slash-appeal reserve can refund at most 20% per 7-day epoch
  (`GuardianRegistry.MAX_REFUND_PER_EPOCH_BPS`).
- Registry pause has a dead-man switch: anyone can unpause after 7 days
  (`GuardianRegistry.DEADMAN_UNPAUSE_DELAY`).

## The exposure ledger — economic security sizing

`ExposureLedger.sol` is the coverage book: it prices what a strategy could
extract, in USD, and records the WOOD each approving guardian has locked behind
it. Full detail: [coverage.md](coverage.md).

- **Coverage requirement:** at propose, each call's tier bound prices its
  extractable value: `requiredCoverage = Σ (cap_i × boundBps_i) / 10 000`. Untiered
  calls default to tier 2 = full notional. Written by
  `_snapshotTierAndGate`; read with `getRequiredCoverage`.
- **Approve is underwriting:** `voteOnProposal(…, lockWood)` →
  `recordApproval(governor, proposalId, guardian, lockWood)`. The ledger locks
  `min(lockWood, free budget)` WOOD, where free budget is
  `kNumerator × slashableStake − openExposure(guardian)`. The vote reverts
  `ApproveLockBelowFloor` when that lock is worth less than one slot's share of
  the need (see `coverage.md`), so an approver slot always carries a lock.
- **Approve quorum at execute:** `requireApproveQuorum` is a coverage
  **measurement**, not an all-or-nothing gate. It values each approver's lock
  live — `Σ min(lock_i, live stake_i) × woodPriceX8()` — and returns
  `(coverageRaisedUsd, requiredCoverageUsd)` so the governor can size execution
  to a coverage-proportional `effectiveMaxCapital`. This is the one place WOOD is
  converted to USD for coverage; a guardian whose lock is now worth less than
  when they declared it (unstake, WOOD price fall) counts at the shrunken live
  value. It reverts
  `InsufficientApproveCoverage` **only** when the approver set is empty
  or the raised aggregate is exactly zero (`ExposureLedger.requireApproveQuorum`). A nonzero-but-partial book is
  the shortfall case: it **scales** capital via
  `SyndicateGovernor._deriveAndStoreEffectiveCapital` —
  `effectiveMaxCapital = floor(maxCapital * coverageRaisedUsd / requiredCoverageUsd)` —
  and the same ratio scales every per-call cap. The gate applies at every
  tier. An empty or
  zero book is "no underwriter on the hook," not a shortfall; the proposal stays
  `Approved` until `executeBy`. Guardian daemons that treat any shortfall as
  disqualifying are wrong.
- **Proposer bond:** `coverageUsd × proposerBondBps (default 1%) / woodPrice`,
  locked in `ProposerBondEscrow` for the life of the proposal + challenge window.
  See [proposer-bond.md](proposer-bond.md).

### Declared coverage locks

A guardian **declares** how much WOOD stands behind each approve. The lock is the
declaration; there is no USD conversion on the approval path and no later pass that
rewrites it. One number per (proposal, guardian) — `lockOf(governor, proposalId,
guardian)` — is at once the guardian's booking, their pledge, and the base a
conviction burns. It is written once by `recordApproval` and erased only by release
(vote change) or retirement; a filed challenge blocks both. The adversary this shape
removes is anyone who could move a guardian's slash base while a challenge is live:
with booking and pledge the same storage, no permissionless step exists that can
shrink or grow it.

- **No cohort cap.** The locks on a proposal may sum to more than its requirement.
  An over-subscribed proposal is a well-covered one; nothing is pro-rated, nothing
  is collapsed, and each lock stays each guardian's own liability. Under-coverage
  needs no new machinery — `effectiveMaxCapital` already scales the proposal down.
- **Capacity is WOOD, with no price.** Free budget is
  `kNumerator × slashableStake − Σ live locks`, where `openExposure(guardian)`
  walks the epoch buckets in WOOD. A WOOD-feed outage or manipulation cannot starve
  or inflate a guardian's capacity. The approve vote itself does need prices:
  `recordApproval` values the need with `coverageUsd` and the lock with
  `woodPriceX8()` for the slot floor, both unwrapped
  (`ExposureLedger.recordApproval`), so an approve vote reverts while the WOOD
  price or the vault-asset feed is unavailable. A block vote reads no price.
  Budget recycles when a bucket ages past `bucketEnd + challengeWindow`, or
  earlier on release or retirement.
- **Frozen and pinned locks keep counting.** A challenge freezes a lock, and a
  re-armed challenge window pins it, and both keep it slashable past its
  bucket's wall-clock expiry — so the freeze and the pin *move* the lock
  (`_rebucket`) into the bucket containing the challenge's worst-case end
  (`filedAt + voteWindow`, sent on EVERY filing so a later concurrent challenge
  extends it) or the pin deadline, raise-only. The
  unfreeze returns it to ordinary decay: the later of the bucket it was booked
  into and any standing pin — never earlier than the bucket covering
  settlement, and never held past the last legal filing. Release and retirement unwind from the bucket the
  lock currently occupies. `openExposure` is unchanged and there is no second
  accumulator; the scan simply sees the lock where its liability actually ends.
  That end is HARD: from `filedAt + voteWindowAtFiling` on, no further ballot is
  accepted (`voteOnChallenge` reverts `WindowClosed`), so a filing that has not
  reached the convict quorum by then can only fail — `resolve` returns the bond
  net of `forfeitBurnBps` instead of settling — and a filing nobody resolves
  stops being slashable exactly when its bucket stops counting. With concurrent
  filings the key is slashable until the latest live filing's window end, which
  is what the raise-only freeze booked.
  Residual: a move target past the 60-day horizon is clamped to the horizon's
  edge (a bucket outside the scan would un-count the lock), so a challenge at
  the game's 60-day ceiling stops counting at the edge rather than its true
  end; `hasFrozenCoverage` still blocks exit throughout.
- **`k = 1` contains a conviction.** At the default `kNumerator = 1`,
  `Σ locks ≤ stake`, so burning proposal A's lock leaves
  `stake − lock_A ≥ Σ other locks`: every other proposal the guardian backs stays
  fully covered. Raising `k` is deliberate leverage — a guardian may then lock more
  across proposals than they hold, and one conviction can leave the others
  under-covered by exactly the excess. The adversary is a future operator who
  raises `k` for capital efficiency without seeing that it reintroduces
  cross-proposal contagion.
- **Slash = the lock, floored by `minSlashBps`.** On conviction (review-path block
  or challenge verdict) the burn for (proposal, guardian) is `min(lock, slash
  basis)`, expressed to `StakedWood` as bps of that basis, rounded up, then clamped
  into `[minSlashBps, maxSlashBps]`. The basis is `min(stake at the anchor, live
  stake)` — `openedAt` for a review block, `executedAt` for a verdict — so a top-up
  after the fact neither shields the lock nor is burned. `minSlashBps` is the
  **single deterrence floor**: a 1-wei declaration adds nothing to quorum and still
  costs `minSlashBps` of everything the guardian holds. Its launch value is a
  governance decision, not a code default; `DeployPlanB` refuses zero and requires
  `maxSlashBps = 100%` so a full-stake lock can burn in full.
- **Fee attribution is the lock.** `GuardianRegistry.getApproverCoverage` reads
  `coverageUsdOf` — `min(lock, live stake) × woodPriceX8()`, **uncapped**: a
  guardian who locked more took more risk and earns proportionally more, even when
  the cohort over-subscribed. There is no settlement step before payout; the lock a
  guardian holds at payout is their attribution. `priced == false` means retry, not
  pay zeros.
- **Challenger bonds are sized at need.** `liabilityUsd` is
  `min(needUsd, Σ min(lock_i, live stake_i) × woodPriceX8())`. The cap applies to
  bond sizing only — full locks still burn on conviction — and exists so a cohort
  cannot lock surplus WOOD to price challengers out.

| Parameter | Default | Min | Max | Setter |
|---|---|---|---|---|
| `kNumerator` (exposure budget multiplier) | 1 | 1 (zero reverts `InvalidParameter`) | — | `ExposureLedger.setKNumerator` |
| `challengeWindow` | 14 d | > 0 and ≥ `reviewPeriod` + 7 d | scan-bounded (16 buckets) | `ExposureLedger.setChallengeWindow` |
| `epochLength` | 28 d (immutable) | — | — | ctor |
| `MAX_COVERAGE_HORIZON` | 60 d | const | const | `ExposureLedger.MAX_COVERAGE_HORIZON` |
| `proposerBondBps` | 100 (1%) | 0 | 100% | `ExposureLedger.setProposerBondBps` |
| `coveredTvlCapUsd` | 0 = fail-closed (nothing proposable until set) | — | — | `ExposureLedger.setCoveredTvlCapUsd` |
| `woodHaircutBps` | 100% (no haircut — deploy script refuses this; safe value set at deploy) | 50% | 100% | `ExposureLedger.setWoodHaircutBps` |
| `woodUsdPriceX8` | owner-set cap (0 = hard stop `NoWoodPrice`) | — | — | `ExposureLedger.setWoodUsdPrice` |

## Adapter certification — TierRegistry

Two independent axes:

1. **Tier axis** (prices risk): tier is a property of `(target, selector)`.
   Tier 0 = closed-loop, tier 1 = oracle-bounded, tier 2 = arbitrary calldata
   (the default for anything uncertified). Each certification pins an
   `extractableBoundBps` and the adapter's **codehash**.
2. **Counterparty axis** (bounds which venues a strategy may bind):
   `isCounterpartyAllowed` checks both the flag *and* that the live codehash
   still equals the one snapshotted at grant time; strategy templates read it
   when they bind a venue (for example the Morpho singleton and the Portfolio
   swap adapter). Code changes self-revoke lazily. A Morpho market is admitted
   separately, by its market id: `TierRegistry.setMorphoMarketAllowed(id, true)`,
   read through `isMorphoMarketAllowed` at init and again at execute. The vault's batch
   guard does not read this axis: `_guardBatchCalls` requires every non-asset
   callee to be a strategy registered with the `StrategyFactory` (registration
   is permissionless) and every call on the asset to be `transfer`,
   `transferFrom` from the vault, or the approve family, to any recipient
   (`SyndicateVault._guardBatchCalls`, `AssetCallRules.spenderOf`).

Certification is a single owner call: `certify` pins the reviewed codehash and
takes effect in the same transaction. Revocation is instant: owner `demote`,
challenge-driven `demoteByChallenge`, or a codehash mismatch, which every read
re-verifies. A demotion affects only that `(target, selector)`: it deletes the
certification and denies the class tier to that address, and leaves the
counterparty allowlist untouched (`TierRegistry._demote`).

Known blind spot (documented in-contract): EXTCODEHASH attestation catches
same-address bytecode swaps, but not proxy implementation swaps or storage rewiring.
Governance discipline: never certify proxied or storage-mutable adapters at tier 0/1.

## Post-execution accountability — ChallengeGame

Anyone can challenge an executed proposal during the challenge window by posting a
bond. The window closes at `max(executedAt + strategyDuration + challengeWindow,
challengeableUntil)` (`ChallengeGame.file`). A filing freezes the accused cohort's
coverage and opens a guardian vote; the vote decides it.

```
file (bond = 1.5% of liability)
  → coverage frozen, guardians vote convict/acquit for voteWindow (7 d)
      ├─ convict weight reaches the quorum (30% of the TOTAL staked WOOD)
      │  and outweighs the acquit side
      │    → SETTLED: approvers' locks burned, proposer bond forfeited,
      │      adapter demoted, challenger paid bond − settleBurn
      │      plus the prosecutor fee out of the proposer's bond
      └─ the window closes short of that
           → FAILED: forfeitBurnBps (20%) of the bond burns, the rest returns.
             An acquittal that itself reached the quorum does not
             re-arm the window; anything less is silence and re-arms
             it, once.
```

`resolve` is permissionless and exercises no discretion. Before the window closes it
settles only when `convictWeight × 10 000 ≥ quorumBpsAtFiling × totalStakeAtFiling`
**and** `2 × convictWeight > votableAtFiling` — the convict side outweighs every
acquit ballot still castable; otherwise it reverts `DelayNotElapsed`. At or after
`filedAt + voteWindowAtFiling` it settles on the quorum plus
`convictWeight > acquitWeight` and fails otherwise (`ChallengeGame.resolve`). The
majority clause matters on its own: 30% convict against 70% acquit convicts nobody. Settling a reached quorum has no deadline
of its own: `resolve` is permissionless and the challenger, whose bond returns only
on settlement, is the party paid to call it, and until the last live challenge terminates, the freeze keeps the approvers' locks
unreleasable and unretirable and blocks their unstake claims (`ChallengeGame._releaseFreeze`;
`ExposureLedger.releaseApproval` / `retireApproval` revert `CoverageFrozen`);
`filedAt + voteWindow` only sets the bucket the frozen lock counts in. No transfer anywhere in the game reaches
an approver or the proposer: the challenger's burns go to `0x…dEaD`, the slash
burns inside sWOOD, and the prosecutor fee comes out of the convicted proposer's
own escrowed bond.

### The vote

- **Entrypoint:** `voteOnChallenge(challengeId, convict)`.
  One ballot per guardian per challenge, no changes, and only while the challenge is
  `Filed` and inside its pinned window.
- **Weight:** the lower of the voter's staked WOOD at `filedAt − 1` and at the
  proposal's snapshot (`swood.getPastStake`; the governor's `snapshotTimestamp`,
  pinned on the challenge as `snapshotAt`), stamped when the proposal entered
  Pending — at `propose`, or at the last co-proposer approval on the collaborative
  path (disabled while `ownerOnlyProposals` is on). This is the same electorate the
  guardian review uses. Stake added after that carries no ballot, so a guardian who
  joined later cannot vote on its challenge;
  that stake still counts in the denominator and in `votableAtFiling`, so it
  raises the bar the eligible electorate must clear and the early-settle bar. The filing stamp is one second back because an sWOOD checkpoint
  is keyed on the second a stake changes and a same-second push overwrites — reading
  the filing instant itself would let stake planted in that very block count in the
  numerator while the denominator missed it.
- **Denominator:** pinned once, at filing, to `getPastTotalVotes(filedAt − 1)` — the
  TOTAL staked WOOD, accused included (each accused counted at no more than its
  stake at the approve snapshot and at execution). Subtracting the accused made a
  conviction cheaper the wider the cohort that had approved, so a proposal 90% of
  the stake approved could be convicted by a few percent of it. The accused lose
  their ballot, not their weight. The same base also holds stake that has no ballot
  on this challenge: stake added after `snapshotAt`, and the stake of the
  challenger, the proposer and the co-proposers, and of any guardian that requests
  unstake after the filing (`voteOnChallenge` requires `isActiveGuardian`).
- **Who cannot vote:** the challenger (`ChallengerCannotVote`), the challenged
  proposal's pinned proposer and each of its co-proposers (`ProposerCannotVote`), and
  the accused approvers (`AccusedCannotVote`). Co-proposers are named on-chain and
  take a share of the performance fee, so they are the same interested party as the
  lead. The identity checks are floors, not ceilings — a second, unlinked address
  defeats all of them — but they close the plain case where a filer convicts its own
  accusation, or a proposer votes on the challenge that would take its bond. What
  BOUNDS a sybil is that its ballot counts only stake held since the proposal
  entered Pending: it must have staked by then, and that
  stake must still reach 30% of the TOTAL staked WOOD and outweigh the acquit side.
- **Quorum:** `challengeQuorumBps` of that pinned total, and the convict side must
  also outweigh the acquit side. Abstention still adds nothing to either tally, so a
  challenge carries on an active convicting majority reaching the bar, or not at all.
  `file` refuses a filing (`NoVotableStake`) only when the stake outside the
  accused cohort is below the quorum share of the base — see below. That check
  does not prove the quorum is reachable.

D6 parameters. These are launch defaults and await an economics run:

| Parameter | Value | Bounds | Pinned at filing |
|---|---|---|---|
| `voteWindow` (`setVoteWindow`) | 7 d | `MIN_VOTE_WINDOW` = 2 d – `MAX_VOTE_WINDOW` = 60 d (the ledger's `MAX_COVERAGE_HORIZON`) | yes |
| `challengeQuorumBps` (`setChallengeQuorumBps`) | 3 000 bps (30%) of the TOTAL staked WOOD | owner-set in [1 000, 10 000] | yes |
| denominator — `totalStakeAtFiling` | total staked WOOD at `filedAt − 1`, each accused counted at min(stake at `executedAt − 1`, stake at `snapshotAt`, stake at `filedAt − 1`) | `file` reverts `NoVotableStake` when the total less the accused cohort is under `challengeQuorumBps` of the total; stake that cannot vote is not subtracted, so a filing that passes can still be unwinnable | yes |
| convict majority | `convictWeight > acquitWeight`, required on top of the quorum | — | — |
| `forfeitBurnBps` — no conviction (`setForfeitBurnBps`) | 20% of the challenger bond burns, the remainder returns | 0 – 50% | yes |
| `settleBurnBps` — conviction (`setSettleBurnBps`) | 5% burns; the challenger takes `bond − settleBurn` | 0 – 50% | yes |
| `prosecutorFeeBps` — conviction (`setProsecutorFeeBps`) | 20% of the convicted proposer's forfeited bond, paid to the challenger | 0 – 20% (`MAX_PROSECUTOR_FEE_BPS`; the paying escrow enforces its own) | yes |
| per-approver slash | `min(lock, basis)` expressed as bps of the basis, clamped into `[minSlashBps, maxSlashBps]` | sWOOD's bounds | basis anchors at `executedAt` |

Whether `minSlashBps` must be at least as large as the ledger's WOOD haircut is a
separate question with its own ticket; nothing above assumes an answer to it.

Filing parameters:

| Parameter | Default | Min | Max | Setter |
|---|---|---|---|---|
| `challengeWindow` | 14 d, counted from `executedAt + strategyDuration` | > 0 | ≤ ledger's window | `ChallengeGame.setChallengeWindow` |
| `challengerBondBps` | 1.5% of `liabilityUsd` (locks at live value, capped at the proposal's need) | > 0 | 100% | `ChallengeGame.setChallengerBondBps` |

`file` prices the bond through `unsharedLiabilityUsd` inside `try/catch` and reverts
`WoodPriceUnset` on any failure of it: no WOOD price, or a stale or unconfigured
vault-asset feed. There is no fallback bond, and the filing deadline keeps running
during the outage ([coverage.md](coverage.md)).

### What the vote guarantees

- **A filing the accused cohort alone makes unwinnable is refused; others are not.**
  Once the accused hold more than `1 − quorum` of the base — 70% at the 3 000 bps
  default — `file` reverts `NoVotableStake` rather than taking a bond that could only
  burn. The guard subtracts only the accused. Stake added after `snapshotAt` and the
  stake of the challenger, proposer, co-proposers and guardians that request unstake
  after the filing stay in both the base and
  `votableAtFiling` but cannot vote, so a filing can pass the guard and still be
  unwinnable: a non-approving address that stakes more than
  `honest × 10 000 / quorumBps − (honest + accused)` after `snapshotAt` puts a
  unanimous honest conviction below the quorum, and so does a proposer holding that
  much from before `snapshotAt`. The filer then pays `forfeitBurnBps` of its bond.
  A challenger should compute the eligible stake (held at `snapshotAt`, not barred)
  against `quorumBps × totalStakeAtFiling` before filing.
- **Only a sub-quorum failure re-arms.** A quorum acquittal does not re-arm the
  window; the proposal stays challengeable until its existing deadline, and the one
  re-arm remains available to a later silent failure. Below that bar the failure
  counts as silence and re-arms the window (`ChallengeGame._fail`), so one dust
  ballot cannot foreclose it. A re-arm raises the deadline to
  `max(existing, now + challengeWindow)`, so a silent failure early in the window
  spends the re-arm flag without extending anything (`_rearmChallengeWindow`).
  This holds for a substantial minority too — 25% acquit against 20% convict at a
  30% quorum still reads as silence — because the bar is the quorum, not the balance
  of the two sides.
- **A proposal's window re-arms at most once.** The re-arm flag is one-shot per
  proposal, so a filer cycling addresses cannot keep a cohort's coverage pinned
  indefinitely: repeated silent failures let the window lapse and the proposal stops
  being challengeable.
- **Break-even is the best case, not a floor.** `honestFilingBreaksEven()` compares
  `challengerBondBps × settleBurnBps` against `proposerBondBps × prosecutorFeeBps`,
  which is the payoff on the quorum-reached path alone; a filing that misses quorum
  pays `forfeitBurnBps` of the bond and collects nothing, so a filer's real
  expectation is that margin discounted by the odds the cohort convicts.

Anti-griefing details:

- The challenger's terms, the quorum and its base, and the vote window are pinned at
  filing; approvers' slash rates are read at settlement (`_settle` → `slashBpsFor`)
  and clamped by sWOOD's live `minSlashBps` / `maxSlashBps`. `filingsPaused` gates `file` alone and is never read
  in `resolve`, so the owner can stop new challenges but never strand a live one.
- One live challenge per challenger per proposal. The slot is per *challenger*
  precisely so an accused cohort cannot buy immunity by self-filing to occupy the
  only one; the coverage freeze is refcounted so concurrent filings cannot unfreeze
  each other, and conviction is once-per-accused (surviving even a game redeploy via
  an sWOOD-side flag).
- Verdict slashing burns each approver's **lock** for the proposal
  (`slashBpsFor`, clamped into `[minSlashBps, maxSlashBps]` by sWOOD) and anchors
  at **`executedAt`**, not filing time — requesting unstake after execution cannot
  zero the slash basis, and staking more after execution cannot dilute it. A
  released or zero lock owes nothing and is skipped.
- The slash transaction carries a gas floor (`180 000 × approvers + 2 000 000`, plus
  `200 000` when the filing names an adapter to demote) so an under-gassed caller
  cannot burn a verdict or silently starve the demotion.

## Emergency paths

- `unstick` (`GovernorEmergency.unstick`) — vault owner replays the already-voted
  settlement calls after `strategyDuration`. No review: the calldata was already
  reviewed. Caps are the coverage-scaled `effectiveMaxCapital` and settlement
  caps, not the declare-time envelope. It reverts unless the strategy reports it
  has unwound, and it applies `MAX_STAMP_DRAWDOWN_BPS`, a 90% drawdown
  allowance, i.e. a floor at 10% of the execute-time price per share, instead
  of the proposal's own `maxDrawdownBps` (`GovernorEmergency.unstick`,
  `SyndicateGovernor._requireSettlePriceAboveFloorHook`). It closes a settle that fell below the
  proposal's floor; it cannot close one whose stored leg reverts, because it
  replays the same calls.
- `emergencySettleWithCalls` (`GovernorEmergency.emergencySettleWithCalls`) — vault owner submits
  **new** calls after `strategyDuration`; requires the owner's sWOOD bond
  (`requiredOwnerBond` = `max(minOwnerStake, MIN_OWNER_BOND_FLOOR)` at
  `StakedWood.requiredOwnerBond`, `MIN_OWNER_BOND_FLOOR` = 1 000 WOOD, and the
  posted bond must be strictly positive) and opens a fresh guardian review
  (block-only voting, `reviewPeriod` long). A block slashes the **owner's
  bond**, not guardians. `finalizeEmergencySettle` executes the stored
  calls, at any time the owner chooses after `reviewEnd`, with per-call caps
  disabled — the escape hatch for a settlement leg stuck on a cap — and a net
  egress budget of zero, measured across the whole batch (`GovernorEmergency.finalizeEmergencySettle` passes `maxNetOutflow = 0`;
  `SyndicateVault.executeGovernorBatch`): vault float may leave inside the batch only if
  at least as much comes back before it ends (a solvent repay the vault fronts
  and the redeemed collateral returns passes). Only an insolvent unwind needs
  funds sent to the strategy from outside the vault.
- After a blocked round burns the bond, the same owner re-bonds with
  `prepareOwnerStake` → `approveOwnerStakeBinding(vault)` →
  `rotateOwner(vault, owner)`, which is allowed while the stuck proposal is still
  open (rotation to any other address still waits until nothing is open), then
  opens a new round. Each blocked round costs a bond. The rotation drains the
  vault's agent set, so the owner calls `registerAgent` again before proposing.
- If the Safe raises `minOwnerStake` above a vault's posted bond while its
  proposal is open, `emergencySettleWithCalls` reverts `OwnerBondInsufficient`
  and the owner can neither top up nor re-bond (the bond is not zero) until the
  Safe lowers the floor again. Propose and execute are unaffected.

### What an unblocked emergency round lets the owner do

A round that does not reach block quorum executes exactly the calls the owner
submitted. The guardian block vote is the only control on them. An unblocked
round lets the vault owner:

- **Pass on what the strategy returns.** The zero budget protects only the
  vault's asset balance as it stood before the batch. `[clone.rescueTo(asset),
  asset.transfer(owner, x)]` pays the owner up to everything the clone returns
  inside the batch; one unit more reverts `MaxNetOutflowExceeded`.
- **Move non-asset tokens out of the share price.** `rescueTo(token)`
  (`BaseStrategy.rescueTo`) pushes the clone's whole balance of any token to the
  vault, in any lifecycle state. A non-asset token in the vault is not counted
  in the share price, and no governor batch can call it (a batch may target only
  the asset and registered strategies). Once finalize marks the proposal Settled,
  `redemptionsLocked()` is false and the owner's `rescueERC20` can move it, but
  only to a clone the `StrategyFactory` made whose `vault()` is this vault
  (`SyndicateVault.rescueERC20`); never to the owner or any other address. A
  token that no such clone can sell stays in the vault, uncounted.
- **Close a proposal with capital still on the strategy.**
  `finalizeEmergencySettle` checks neither that the strategy has unwound nor the
  settle-price floor. An empty call list, or calls that do nothing, finalise:
  the proposal becomes Settled while the clone still holds the position and
  reports `executed() == true`. `totalAssets()` counts only idle asset, so
  redemptions and deposits reopen at a share price without the position until a
  later proposal's batch calls the clone's `settle()` (`BaseStrategy.settle`).
- **Leave an orphaned clone that can still trade.** After such a close the
  clone stays Executed, and two calls keep working with no proposal open:
  - Portfolio: the clone's proposer, while still an agent of the vault (not
    necessarily the owner), can call `rebalanceDelta` on the basket sitting on
    the clone (`PortfolioStrategy.rebalanceDelta`; `BaseStrategy.onlyProposer`). Each swap
    runs through the clone's own swap adapter and price feeds, which must still
    be allowlisted, and is bounded by `maxSlippageBps`. An owner can add tokens
    to that basket with `rescueERC20` into the clone; the bound is the same.
  - Concentrated liquidity: `rerange()` is permissionless and needs only the
    Executed state (`ConcentratedLiquidityStrategy.rerange`), so anyone can
    re-range the orphaned position, up to `maxReranges` times and subject to its
    trigger and `minInterval`.
  Both are bounded residuals, not ways to take the tokens.
- **Cancel a round for free while block weight is below quorum.**
  `cancelEmergencySettle` is accepted until `reviewEnd` unless block quorum is
  already reached (`GuardianRegistry.cancelEmergency`). Nothing is slashed, and the
  owner may open a new round one `reviewPeriod` after the cancel (`cancelEmergency` sets the cooldown; `openEmergency` refuses until it passes).
  Emergency block votes have no late-vote lockout, so a cancel and the vote that
  would reach quorum race until the window closes. The bond burns only if the
  full `blockQuorumBps` lands inside one window.
- **Pause the vault.** `SyndicateVault.pause` stops
  `executeGovernorBatch` (`whenNotPaused`), so keeper `settleProposal`, `unstick` and
  `finalizeEmergencySettle` all revert while paused, but `emergencySettleWithCalls`
  still opens a round (it touches only the registry). Only the vault owner can
  unpause; the Safe and guardians cannot. After the review the owner unpauses and
  finalises. An owner that is a contract wallet can do both in one transaction,
  so nobody else's `settleProposal` can land in between. While the vault is
  paused the management fee keeps accruing on the whole fund.
- **Force the path by tightening slippage (Portfolio only).** A Portfolio
  clone's proposer can lower `maxSlippageBps` down to its 50 bp floor, which can
  make every ordinary settle revert. A concentrated-liquidity clone's
  `settleSlippageBps` is fixed at init (at least 50 bp) and cannot be changed.

**The electorate is the proposal's snapshot.** `openEmergency` reads the
denominator as `getPastTotalVotes(snapshotAt)` and stores that same instant as
`er.openedAt`; each block vote weighs the voter's raw `getPastStake(voter,
er.openedAt)` (`voteBlockEmergencySettle`). `snapshotAt` is the review snapshot
taken when the proposal entered Pending, however much later the round opens; only
a review registered before that field existed falls back to the open-time
instant. A guardian who staked in or
after that block cannot vote on any emergency round of the proposal. Stake that
counted then counts in the denominator whether or not it votes, including stake
whose owner has since left. The quorum bps is snapshotted when the round opens
(`openEmergency`).

**Reviewer rule.** Simulate the batch on a fork and block it unless all of the
following hold:

1. Every call targets the vault asset, this proposal's strategy
   (`p.strategy`), or another clone made by the `StrategyFactory` for this vault
   (`StrategyFactory.cloneTemplate(target) != address(0)` and
   `IStrategy(target).vault() == vault`). A target that is registered but was
   not made by the factory is grounds to block, whatever its `vault()` returns:
   registration is permissionless and only checks that `vault()`, `proposer()`
   and `executed()` answer.
2. Every `transfer`, `transferFrom` or approve-family call on the asset sends to,
   or approves, the vault or such a clone.
3. Every call's `value` is zero.
4. No call invokes `rescueTo` for a token other than the vault asset (see the
   exception below). A token pushed to the vault is not counted in the share
   price, and afterwards only the owner can move it, and only to a strategy
   clone of the vault.
5. After the batch, `IStrategy(p.strategy).executed()` is false, and the vault's
   asset balance is at least its pre-batch balance plus everything the clones
   released inside the batch. "Released" is the sum of the asset's `Transfer`
   events from the clones permitted by clause 1 to the vault during the batch.

The owner chooses the instant `finalizeEmergencySettle` runs after `reviewEnd`,
with per-call caps disabled, so judge the batch at the worst market state the
strategy's own slippage bounds allow, not at the state you simulated.

One exception to clause 5: a strategy whose settle leg is dead for good can
never report `executed() == false`. In that case only, accept a batch that
leaves the non-asset tokens on the clone (not in the vault), returns every unit
of the asset the clone holds, and does nothing else. Accepting it closes the
proposal with capital still on the strategy (see "Close a proposal with capital
still on the strategy" above): deposits and redemptions reopen at a share price
that excludes the position until a later proposal settles the clone.

### Migrating a vault created under the zero-bond sentinel

`minOwnerStake` may legally be `0` — the deliberate open-onboarding sentinel for
vault creation. Before the `MIN_OWNER_BOND_FLOOR`, that made the emergency gate
evaluate `0 < 0` and pass with **no bond posted**, while `slashOwnerBond`
returned early on `amount == 0`. The deterrent on the one path that runs
owner-supplied calldata with per-call metering disabled was a complete no-op.

Flooring `requiredOwnerBond` fixes that, and it is a **behaviour change for
vaults already created under the sentinel**: `bindOwnerStake` only sets
`p.bound = true` when `p.amount != 0`, so those vaults hold an unbound,
zero-amount slot and `emergencySettleWithCalls` now reverts
`OwnerBondInsufficient` for them until a real bond is posted.

The way back is a factory-gated ceremony, and it works because
`transferOwnerStakeSlot`'s `PriorStakeNotCleared` guard passes at zero:

1. `prepareOwnerStake(amount)` (`StakedWood.prepareOwnerStake`) with
   `amount >= requiredOwnerBond(vault)`
2. `SyndicateFactory.rotateOwner` (`SyndicateFactory.rotateOwner`) to bind the
   funded slot via `transferOwnerStakeSlot` (`StakedWood.transferOwnerStakeSlot`)

Until that runs, the affected vault keeps `unstick` — which carries no bond gate
— so a settlement replay of already-reviewed calldata is unaffected. Only the
new-calldata escape hatch is gated.

## How guardians get paid

The guardian network earns 20% of every management fee and 25% of every
performance fee (see [fees.md](fees.md)). Fees are delivered in the vault's asset to
`guardiansFeeRecipient` and converted to WOOD off-chain via weekly Merkl buyback;
`GuardianFeeAccrued` events provide per-guardian attribution weights, and the
weights come from `getApproverCoverage` — each approver's lock at live value
(`coverageUsdOf`), not their vote-stake. There are no on-chain staking emissions —
review honestly, earn the fee stream in proportion to what you locked; approve a
malicious strategy, and the lock is burned.
