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

## Becoming a guardian

Registration is permissionless: `StakedWood.stakeAsGuardian(amount, agentId)`
(`src/StakedWood.sol:594`). No registry gate, no cap — only a stake floor. Active
means `stakedAmount > 0` and no pending unstake request.

| Parameter | Default | Min | Max | Setter |
|---|---|---|---|---|
| `minGuardianStake` | 10 000 WOOD | 1 WOOD | — | `StakedWood.sol:756` |
| `coolDownPeriod` (unstake delay) | 7 d | 1 d | 30 d, and ≥ `registry.reviewPeriod` | `StakedWood.sol:769` |
| `minOwnerStake` (vault-owner bond at creation) | 10 000 WOOD | 0 (open onboarding) or ≥ 1 000 | — | `StakedWood.sol:790` |
| `minSlashBps` — the **deterrence floor**: the least a convicted approver loses, as a fraction of their whole bond, whatever WOOD they declared. Launch value is a governance decision; `DeployPlanB` refuses zero. | 10% | 0 | ≤ `maxSlashBps` | `StakedWood.sol:800` |
| `maxSlashBps` — must be 100%: a guardian may lock their entire stake behind one proposal, and a ceiling below that would cap the burn beneath the lock. `DeployPlanB` pre-flight asserts it. | 100% | ≥ `minSlashBps` | 100% | `StakedWood.sol:809` |
| `ageFloorBps` (new-stake vote weight) | 25% | > 0 | 100% | `StakedWood.sol:816` |
| `maturationPeriod` (ramp to full weight) | 30 d | 7 d | 90 d | `StakedWood.sol:823` |

**Age-weighted voting:** fresh stake votes at `ageFloorBps` (25%) and ramps linearly
to full weight over `maturationPeriod` (30 d). Topping up re-anchors the stake
timestamp to a weighted average — no cheap weight resets.

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

- Total stake and the block quorum are **snapshotted at `openReview`** — joining or
  leaving mid-review does not move the bar.
- A thin cohort still decides its own reviews. There is no stake floor at open.
  Only a **zero** denominator fails open: `_isBlocked` returns false when
  `totalStakeAtOpen == 0` (`GuardianRegistry.sol:507-523`), because
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
  block-side decisiveness, saturating at a 66.67% supermajority (`_severityBps`,
  `GuardianRegistry.sol:1195`) — multiplies that lock-derived rate, and the result
  is clamped into `[minSlashBps, maxSlashBps]`. A guardian who backed a bad
  proposal with a small lock while holding a large bond loses the lock, and never
  less than `minSlashBps` of the bond.
- Slashed WOOD is **burned** (`0x…dEaD`) — the slash pays nobody. A funded
  slash-appeal reserve can refund at most 20% per 7-day epoch
  (`MAX_REFUND_PER_EPOCH_BPS`, `GuardianRegistry.sol:56`).
- Registry pause has a dead-man switch: anyone can unpause after 7 days
  (`DEADMAN_UNPAUSE_DELAY`, `GuardianRegistry.sol:57`).

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
  `kNumerator × slashableStake − openExposure(guardian)` — no price is read. A
  guardian with no free budget is not rejected at vote time; the cap is enforced
  by locking zero, and the vote still counts as weight.
- **Approve quorum at execute:** `requireApproveQuorum` is a coverage
  **measurement**, not an all-or-nothing gate. It values each approver's lock
  live — `Σ min(lock_i, live stake_i) × woodPriceX8()` — and returns
  `(coverageRaisedUsd, requiredCoverageUsd)` so the governor can size execution
  to a coverage-proportional `effectiveMaxCapital`. This is the one place WOOD is
  converted to USD for coverage; a guardian whose lock is now worth less than
  when they declared it (unstake, WOOD price fall) counts at the shrunken live
  value. It reverts
  `InsufficientApproveCoverage` **only** when the approver set is empty (`:1437`)
  or the raised aggregate is exactly zero (`:1469`). A nonzero-but-partial book is
  the shortfall case: it **scales** capital via
  `_deriveAndStoreEffectiveCapital` (`SyndicateGovernor.sol:1563`) —
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
  or inflate a guardian's capacity, and an approve vote never depends on a price.
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
| `kNumerator` (exposure budget multiplier) | 1 | 1 (zero reverts `InvalidParameter`) | — | `ExposureLedger.sol:795` |
| `challengeWindow` | 14 d | > 0 and ≥ `reviewPeriod` + 7 d | scan-bounded (16 buckets) | `ExposureLedger.sol:707` |
| `epochLength` | 28 d (immutable) | — | — | ctor |
| `MAX_COVERAGE_HORIZON` | 60 d | const | const | `ExposureLedger.sol:146` |
| `proposerBondBps` | 100 (1%) | 0 | 100% | `ExposureLedger.sol:812` |
| `coveredTvlCapUsd` | 0 = fail-closed (nothing proposable until set) | — | — | `ExposureLedger.sol:801` |
| `woodHaircutBps` | 100% (no haircut — deploy script refuses this; safe value set at deploy) | 50% | 100% | `ExposureLedger.sol:666` |
| `woodUsdPriceX8` | owner-set cap (0 = hard stop `NoWoodPrice`) | — | — | `ExposureLedger.sol:587` |

## Adapter certification — TierRegistry

Two independent axes:

1. **Tier axis** (prices risk): tier is a property of `(target, selector)`.
   Tier 0 = closed-loop, tier 1 = oracle-bounded, tier 2 = arbitrary calldata
   (the default for anything uncertified). Each certification pins an
   `extractableBoundBps` and the adapter's **codehash**.
2. **Allowlist axis** (bounds where funds may go): the vault's `_guardBatchCalls`
   requires every batch callee and every value-moving recipient to be
   `isAdapterAllowed` — which checks both the flag *and* that the live codehash
   still equals the one snapshotted at grant time. Code changes self-revoke lazily.

| Parameter | Default | Min | Max |
|---|---|---|---|
| `certifyDelay` (propose → certify) | 3 d | 1 d | 30 d |
| certify window after ready | 14 d fixed | — | — |
| `bondReleaseDelay` (submitter bond) | 14 d | 1 d | 365 d |
| `submitterBondWood` | 0 (launch gate) | 0 | uint96 max |

Certification is two-step (owner proposes, anyone executes after the delay if the
codehash still matches). Revocation is instant: owner `demote`, challenge-driven
`demoteByChallenge`, or permissionless `poke` on codehash mismatch — and demoting
any one selector clears the **whole adapter's** allowlist entry.

Known blind spot (documented in-contract): EXTCODEHASH attestation catches
same-address bytecode swaps, but not proxy implementation swaps or storage rewiring.
Governance discipline: never certify proxied or storage-mutable adapters at tier 0/1.

## Post-execution accountability — ChallengeGame

Anyone can challenge an executed proposal during the challenge window by posting a
bond. A filing freezes the accused cohort's coverage and opens a guardian vote; the
vote decides it.

```
file (bond = 1.5% of liability)
  → coverage frozen, guardians vote convict/acquit for voteWindow (7 d)
      ├─ convict weight reaches the quorum (30% of the votable stake)
      │    → SETTLED: approvers' locks burned, proposer bond forfeited,
      │      adapter demoted, challenger paid bond − settleBurn
      │      plus the prosecutor fee out of the proposer's bond
      └─ the window closes short of quorum
           → FAILED: forfeitBurnBps (20%) of the bond burns, the rest returns.
             Silence re-arms the proposal's challenge window once;
             a voted acquittal spends it.
```

`resolve` is permissionless and exercises no discretion. It settles the instant
`convictWeight × 10 000 ≥ quorumBpsAtFiling × votableStakeAtFiling` — there is no
un-vote, so a reached quorum is already final — and otherwise waits for
`filedAt + voteWindowAtFiling` and fails. Settling a reached quorum has no deadline
of its own: `resolve` is permissionless and the challenger, whose bond returns only
on settlement, is the party paid to call it, while the ledger freeze covers only
`filedAt + voteWindow` — so a settlement left until after that may find the
approvers' locks already retired. No transfer anywhere in the game reaches
an approver or the proposer: the challenger's burns go to `0x…dEaD`, the slash
burns inside sWOOD, and the prosecutor fee comes out of the convicted proposer's
own escrowed bond.

### The vote

- **Entrypoint:** `voteOnChallenge(challengeId, convict)` (`ChallengeGame.sol:522`).
  One ballot per guardian per challenge, no changes, and only while the challenge is
  `Filed` and inside its pinned window.
- **Weight:** the voter's staked WOOD at `filedAt − 1`
  (`swood.getPastStake`). The stamp is one second back because an sWOOD checkpoint
  is keyed on the second a stake changes and a same-second push overwrites — reading
  the filing instant itself would let stake planted in that very block count in the
  numerator while the denominator missed it.
- **Electorate:** pinned once, at filing, to
  `getPastTotalVotes(filedAt − 1)` minus each accused approver's stake at the same
  stamp. The accused cohort is refused at the door (`AccusedCannotVote`) *and* sits
  outside the denominator, so a large approver can neither vote itself clear nor
  raise the bar everyone else has to clear.
- **Quorum:** `challengeQuorumBps` of that pinned stake, counted on the convict side
  only. Abstention and acquittal are arithmetically the same — both leave the
  numerator where it is — so a challenge carries on an active convicting minority of
  the electorate reaching the bar, or not at all.

D6 parameters. These are launch defaults and await an economics run:

| Parameter | Value | Bounds | Pinned at filing |
|---|---|---|---|
| `voteWindow` (`setVoteWindow`, `:877`) | 7 d | ≥ `MIN_VOTE_WINDOW` = 2 d | yes |
| `challengeQuorumBps` (`setChallengeQuorumBps`, `:886`) | 3 000 bps (30%) of the votable stake | owner-set in [1 000, 10 000] | yes |
| electorate — `votableStakeAtFiling` | total staked WOOD at `filedAt − 1` minus the accused cohort's stake | must be non-zero, else `file` reverts `NoVotableStake` | yes |
| `forfeitBurnBps` — missed quorum (`setForfeitBurnBps`, `:847`) | 20% of the challenger bond burns, the remainder returns | 0 – 50% | yes |
| `settleBurnBps` — quorum reached (`setSettleBurnBps`, `:897`) | 5% burns; the challenger takes `bond − settleBurn` | 0 – 50% | yes |
| `prosecutorFeeBps` — quorum reached (`setProsecutorFeeBps`, `:911`) | 20% of the convicted proposer's forfeited bond, paid to the challenger | 0 – 20% (`MAX_PROSECUTOR_FEE_BPS`; the paying escrow enforces its own) | yes |
| per-approver slash | `min(lock, basis)` expressed as bps of the basis, clamped into `[minSlashBps, maxSlashBps]` | sWOOD's bounds | basis anchors at `executedAt` |

Whether `minSlashBps` must be at least as large as the ledger's WOOD haircut is a
separate question with its own ticket; nothing above assumes an answer to it.

Filing parameters:

| Parameter | Default | Min | Max | Setter |
|---|---|---|---|---|
| `challengeWindow` | 14 d | > 0 | ≤ ledger's window | `ChallengeGame.sol:828` |
| `challengerBondBps` | 1.5% of `liabilityUsd` (locks at live value, capped at the proposal's need) | > 0 | 100% | `ChallengeGame.sol:837` |

### What the vote guarantees

- **A challenge nobody outside the accused could decide is never opened.** When the
  accused cohort is the whole staked guardian set, the pinned electorate is zero and
  `file` reverts `NoVotableStake` rather than taking a bond that could only burn.
- **A voted acquittal ends the matter.** Any acquit weight at all means the cohort
  looked and decided, so the challenge fails *and* the proposal's challenge window is
  spent. Only silence — a window that closes with no ballot on either side — re-arms
  it.
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

- All rates **and the clock** are **pinned at filing** — no owner change can re-rate
  or re-time a live challenge. `filingsPaused` gates `file` alone and is never read
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

- `unstick` (`GovernorEmergency.sol:76`) — vault owner replays the already-voted
  settlement calls after `strategyDuration`. No review: the calldata was already
  reviewed. Caps are the coverage-scaled `effectiveMaxCapital` and settlement
  caps, not the declare-time envelope.
- `emergencySettleWithCalls` (`GovernorEmergency.sol:107`) — vault owner submits
  **new** calls; requires the owner's sWOOD bond (`requiredOwnerBond` =
  `max(minOwnerStake, MIN_OWNER_BOND_FLOOR)` at `StakedWood.sol:1179`,
  `MIN_OWNER_BOND_FLOOR` = 1 000 WOOD at `:210`, and the posted bond must be
  strictly positive) and opens a fresh guardian review (block-only voting). A
  block slashes the **owner's bond**, not guardians. Finalize executes with
  per-call caps disabled — the escape hatch for a settlement leg stuck on a cap.

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

1. `prepareOwnerStake(amount)` (`StakedWood.sol:944`) with
   `amount >= requiredOwnerBond(vault)`
2. `SyndicateFactory.rotateOwner` (`SyndicateFactory.sol:718`) to bind the
   funded slot via `transferOwnerStakeSlot` (`StakedWood.sol:1120`)

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
