# Guardian Network

Guardians are staked-WOOD reviewers who inspect every strategy proposal's calldata
before it can execute, and who underwrite the capital it may extract. Their economics
run through five contracts:

| Contract | Role |
|---|---|
| `StakedWood.sol` (sWOOD) | sole WOOD custodian — guardian stake, owner bonds, vote checkpoints, slashing |
| `GuardianRegistry.sol` | review lifecycle + slash-appeal reserve; holds **zero assets** |
| `ExposureLedger.sol` | the exposure book — how much guardian stake backs which strategy |
| `TierRegistry.sol` | adapter-selector certification + the vault's adapter allowlist |
| `ChallengeGame.sol` + `TokenCourt.sol` | post-execution accountability: challenge, dispute, adjudicate, slash |

## Becoming a guardian

Registration is permissionless: `StakedWood.stakeAsGuardian(amount, agentId)`
(`src/StakedWood.sol:621`). No registry gate, no cap — only a stake floor. Active
means `stakedAmount > 0` and no pending unstake request.

| Parameter | Default | Min | Max | Setter |
|---|---|---|---|---|
| `minGuardianStake` | 10 000 WOOD | 1 WOOD | — | `StakedWood.sol:818` |
| `coolDownPeriod` (unstake delay) | 7 d | 1 d | 30 d, and ≥ `registry.reviewPeriod` | `StakedWood.sol:833` |
| `minOwnerStake` (vault-owner bond at creation) | 10 000 WOOD | 0 (open onboarding) or ≥ 1 000 | — | `StakedWood.sol:848` |
| `minSlashBps` | 10% | 0 | ≤ `maxSlashBps` | `StakedWood.sol:858` |
| `maxSlashBps` | 100% | ≥ `minSlashBps` | 100% | `StakedWood.sol:867` |
| `ageFloorBps` (new-stake vote weight) | 25% | > 0 | 100% | `StakedWood.sol:874` |
| `maturationPeriod` (ramp to full weight) | 30 d | 7 d | 90 d | `StakedWood.sol:881` |

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
| `reviewPeriod` | 24 h | 6 h (mainnet immutable floor) | 3 d | `GuardianRegistry.sol:1002` |
| `blockQuorumBps` | 30% | 10% | 100% | `GuardianRegistry.sol:1026` |
| `MIN_COHORT_STAKE_AT_OPEN` | 50 000 sWOOD | const | const | `GuardianRegistry.sol:33` |
| `LATE_VOTE_LOCKOUT_BPS` | last 10% of window | const | const | `GuardianRegistry.sol:39` |
| `MAX_APPROVERS_PER_PROPOSAL` / blockers | 100 each | const | const | `GuardianRegistry.sol:34-38` |

Mechanics worth knowing:

- Total stake and the block quorum are **snapshotted at `openReview`** — joining or
  leaving mid-review does not move the bar.
- A cohort under 50 000 sWOOD auto-clears the review (`cohortTooSmall`) — a tiny
  cohort must not carry veto power.
- Votes are locked in the final 10% of the window (first votes *and* changes).
- **Approve votes are underwriting**, not just signaling: each approval books
  coverage on the `ExposureLedger` against the guardian's free stake.
- A **blocked** review slashes every approver. Severity is deterministic, not voted:
  a quadratic ramp from `minSlashBps` (10%) to `maxSlashBps` (100%), saturating at
  a 66.67% block supermajority (`_severityBps`, `GuardianRegistry.sol:807`).
- Slashed WOOD is **burned** (`0x…dEaD`) — the slash pays nobody. A funded
  slash-appeal reserve can refund at most 20% per 7-day epoch
  (`MAX_REFUND_PER_EPOCH_BPS`).
- Registry pause has a dead-man switch: anyone can unpause after 7 days.

## The exposure ledger — economic security sizing

`ExposureLedger.sol` prices what a strategy could extract and requires guardian
stake to cover it before execution.

- **Coverage requirement:** at propose, each call's tier bound prices its
  extractable value: `requiredCoverage = Σ (cap_i × boundBps_i) / 10 000`. Untiered
  calls default to tier 2 = full notional.
- **Approve quorum at execute:** `requireApproveQuorum` reverts execution unless
  booked guardian coverage ≥ required coverage (fail-closed;
  `quorumTierThreshold = 0` applies it to every tier).
- **Proposer bond:** `coverageUsd × proposerBondBps (default 1%) / woodPrice`,
  locked in `ProposerBondEscrow` for the life of the proposal + challenge window.

| Parameter | Default | Min | Max | Setter |
|---|---|---|---|---|
| `challengeWindow` | 14 d | > 0 and ≥ `reviewPeriod` + 7 d | scan-bounded (16 buckets) | `ExposureLedger.sol:837` |
| `epochLength` | 28 d (immutable) | — | — | ctor |
| `MAX_COVERAGE_HORIZON` | 60 d | const | const | `ExposureLedger.sol:151` |
| `proposerBondBps` | 100 (1%) | 0 | 100% | `ExposureLedger.sol:892` |
| `coveredTvlCapUsd` | 0 = fail-closed (nothing proposable until set) | — | — | `ExposureLedger.sol:881` |
| `woodHaircutBps` | 100% (no haircut — deploy script refuses this; safe value set at deploy) | 50% | 100% | `ExposureLedger.sol:802` |
| `woodUsdPriceX8` | owner-set cap (0 = hard stop `NoWoodPrice`) | — | — | `ExposureLedger.sol:708` |

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
bond. The game is a two-stage bond battle with a court backstop:

```
file (bond = 1.5% of coverage) ─┬─ nobody disputes within autoSlashDelay (7 d)
                                │    → SILENCE CONVICTION: approvers slashed 100%,
                                │      proposer bond forfeited, adapter demoted
                                └─ counter-bond pool fills to exactly bondWood
                                     → Disputed → referred to TokenCourt
                                          ├─ Guilty: slash + challenger takes pool
                                          ├─ NotGuilty / timeout: challenger bond
                                          │    forfeited (20% burned, rest to funders)
                                          └─ Inconclusive: everyone refunded minus a
                                               burn; window re-arms
```

| Parameter | Default | Min | Max | Setter |
|---|---|---|---|---|
| `challengeWindow` | 14 d | > 0 | ≤ ledger's window | `ChallengeGame.sol:421` |
| `challengerBondBps` | 1.5% of frozen coverage | > 0 | 100% | `ChallengeGame.sol:433` |
| `autoSlashDelay` (silence → conviction) | 7 d | 2 d | < `disputeTimeout` | `ChallengeGame.sol:467` |
| `disputeTimeout` | 30 d | > `autoSlashDelay` | 60 d | `ChallengeGame.sol:478` |
| `settleBurnBps` (win burn) | 10% | ≥ `inconclusiveBurnBps` | 50% | `ChallengeGame.sol:499` |
| `forfeitBurnBps` (loss burn) | 20% | 0 | 50% | `ChallengeGame.sol:462` |
| `inconclusiveBurnBps` (round 4+) | 10% | 0 | min(50%, `settleBurnBps`) | `ChallengeGame.sol:586` |
| `prosecutorFeeBps` (slice of proposer bond) | 20% | 0 | 20% | `ChallengeGame.sol:543` |

Anti-griefing details:

- All rates are **pinned at filing** — no owner change can re-rate a live challenge.
- Inconclusive retries burn on an escalating schedule per proposal:
  round 1 = 2.5% (`INCONCLUSIVE_BURN_ROUND1_BPS` — a free first round let a filer
  freeze coverage at no cost), round 2 = 5%, round 3 = 10%, round 4+ =
  `inconclusiveBurnBps` (10%), each clamped to `settleBurnBps`.
- One live challenge per challenger per proposal; conviction is once-per-accused
  (survives even a game redeploy via an sWOOD-side flag).
- Verdict slashing anchors at **`executedAt`**, not filing time — requesting unstake
  after execution cannot zero the slash basis.
- The slash transaction carries a gas floor (`180 000 × approvers + 2 000 000`) so an
  under-gassed caller cannot burn a verdict.

## TokenCourt — adjudication

Single-layer WOOD-vote court. One referral opens one vote window; one tally produces
the verdict. No panel, no appeal.

| Parameter | Default | Min | Max |
|---|---|---|---|
| `voteWindow` | 5 d | > 0 | 14 d (`MAX_VOTE_WINDOW`) |
| `FINALIZE_BUFFER` | 1 d | const | const |
| `participationFloorBps` | 10% | > 0 | < `sWOOD.ageFloorBps` (25%) |

- Electorate: all sWOOD stakers **except the accused** (accused = guardians whose
  coverage backs the challenged proposal). No vote changes.
- Verdict: turnout below the participation floor → `Inconclusive`; strict majority
  guilty → `Guilty`; tie or majority not-guilty → `NotGuilty` (fails safe).
- Referral is only accepted if a full vote + finalize buffer fits before the
  challenge's pinned `disputeTimeout` (`InsufficientClock`) — a case that exists is
  always one that can finish.
- Cross-contract invariant, enforced at the setters on both sides plus
  per-referral:
  `autoSlashDelay + voteWindow + FINALIZE_BUFFER + MIN_REFERRAL_SLACK ≤ disputeTimeout`
  (7 d + 5 d + 1 d + 1 h ≈ 13 d ≤ 30 d at defaults). `MIN_REFERRAL_SLACK`
  (1 h, `ChallengeGame.sol:117`) reserves referral headroom so a case cannot be
  opened with too little clock left to finish.

## Emergency paths

- `unstick` — vault owner replays the already-voted settlement calls after
  `strategyDuration`. No review: the calldata was already reviewed.
- `emergencySettleWithCalls` — vault owner submits **new** calls; requires the
  owner's sWOOD bond (`requiredOwnerBond` = `max(minOwnerStake, 1 000 WOOD)`,
  and the posted bond must be strictly positive) and opens
  a fresh guardian review (block-only voting). A block slashes the **owner's bond**,
  not guardians. Finalize executes with per-call caps disabled — the escape hatch
  for a settlement leg stuck on a cap.

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

The way back is a three-step, `onlyFactory`-gated ceremony, and it works
because `transferOwnerStakeSlot`'s `PriorStakeNotCleared` guard passes at zero:

1. `prepareOwnerStake(amount)` with `amount >= requiredOwnerBond(vault)`
2. `approvedBindVault` to bind the funded slot
3. `rotateOwner` to the same address, re-binding it

Until that runs, the affected vault keeps `unstick` — which carries no bond gate
— so a settlement replay of already-reviewed calldata is unaffected. Only the
new-calldata escape hatch is gated.

## How guardians get paid

The guardian network earns 10% of every management fee and 15% of every performance
fee (see [fees.md](fees.md)). Fees are delivered in the vault's asset to
`guardiansFeeRecipient` and converted to WOOD off-chain via weekly Merkl buyback;
`GuardianFeeAccrued` events provide per-guardian attribution weights. There are no
on-chain staking emissions — review honestly, earn the fee stream; approve a
malicious strategy, get slashed and burned.
