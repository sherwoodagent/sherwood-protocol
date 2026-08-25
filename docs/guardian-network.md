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
| `CallSandbox.sol` | isolated clone that runs uncertified (tier-2) calldata against a funded envelope |
| `ChallengeGame.sol` + `TokenCourt.sol` | post-execution accountability: challenge, dispute, adjudicate, slash |

## Becoming a guardian

Registration is permissionless: `StakedWood.stakeAsGuardian(amount, agentId)`
(`src/StakedWood.sol:594`). No registry gate, no cap — only a stake floor. Active
means `stakedAmount > 0` and no pending unstake request.

| Parameter | Default | Min | Max | Setter |
|---|---|---|---|---|
| `minGuardianStake` | 10 000 WOOD | 1 WOOD | — | `StakedWood.sol:756` |
| `coolDownPeriod` (unstake delay) | 7 d | 1 d | 30 d, and ≥ `registry.reviewPeriod` | `StakedWood.sol:769` |
| `minOwnerStake` (vault-owner bond at creation) | 10 000 WOOD | 0 (open onboarding) or ≥ 1 000 | — | `StakedWood.sol:790` |
| `minSlashBps` | 10% | 0 | ≤ `maxSlashBps` | `StakedWood.sol:800` |
| `maxSlashBps` | 100% | ≥ `minSlashBps` | 100% | `StakedWood.sol:809` |
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
| `reviewPeriod` | 24 h | 6 h (mainnet immutable floor) | 3 d | `GuardianRegistry.sol:1460` |
| `blockQuorumBps` | 30% | 10% | 100% | `GuardianRegistry.sol:1481` |
| `LATE_VOTE_LOCKOUT_BPS` | last 10% of window | const | const | `GuardianRegistry.sol:46` |
| `MAX_APPROVERS_PER_PROPOSAL` / `MAX_BLOCKERS_PER_PROPOSAL` | 100 each | const | const | `GuardianRegistry.sol:41-45` |

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
- **Approve votes are underwriting**, not just signaling: each approval books
  coverage on the `ExposureLedger` against the guardian's free stake.
- A **blocked** review slashes every approver. Severity is deterministic, not voted:
  a quadratic ramp from `minSlashBps` (10%) to `maxSlashBps` (100%), saturating at
  a 66.67% block supermajority (`_severityBps`, `GuardianRegistry.sol:1195`).
- Slashed WOOD is **burned** (`0x…dEaD`) — the slash pays nobody. A funded
  slash-appeal reserve can refund at most 20% per 7-day epoch
  (`MAX_REFUND_PER_EPOCH_BPS`, `GuardianRegistry.sol:56`).
- Registry pause has a dead-man switch: anyone can unpause after 7 days
  (`DEADMAN_UNPAUSE_DELAY`, `GuardianRegistry.sol:57`).

## The exposure ledger — economic security sizing

`ExposureLedger.sol` is the coverage book: it prices what a strategy could
extract and books bonded WOOD against that price when a guardian Approves.
Full detail: [coverage.md](coverage.md).

- **Coverage requirement:** at propose, each call's tier bound prices its
  extractable value: `requiredCoverage = Σ (cap_i × boundBps_i) / 10 000`. Untiered
  calls default to tier 2 = full notional. Written by
  `_snapshotTierAndGate`; read with `getRequiredCoverage`.
- **Approve is underwriting:** `voteOnProposal` → `recordApproval`
  (`ExposureLedger.sol:985`). An under-bonded guardian is not rejected at vote
  time; the cap is enforced by booking zero.
- **Approve quorum at execute:** `requireApproveQuorum`
  (`ExposureLedger.sol:1428`) is a coverage **measurement**, not an all-or-nothing
  gate. It returns `(coverageRaisedUsd, requiredCoverageUsd)` so the governor can
  size execution to a coverage-proportional `effectiveMaxCapital`. It reverts
  `InsufficientApproveCoverage` **only** when the approver set is empty (`:1437`)
  or the raised aggregate is exactly zero (`:1469`). A nonzero-but-partial book is
  the shortfall case: it **scales** capital via
  `_deriveAndStoreEffectiveCapital` (`SyndicateGovernor.sol:1563`) —
  `effectiveMaxCapital = floor(maxCapital * coverageRaisedUsd / requiredCoverageUsd)` —
  and the same ratio scales every per-call cap. `quorumTierThreshold = 0`
  (`ExposureLedger.sol:195`) applies the gate to every tier. An empty or
  zero book is "no underwriter on the hook," not a shortfall; the proposal stays
  `Approved` until `executeBy`. Guardian daemons that treat any shortfall as
  disqualifying are wrong.
- **Proposer bond:** `coverageUsd × proposerBondBps (default 1%) / woodPrice`,
  locked in `ProposerBondEscrow` for the life of the proposal + challenge window.
  See [proposer-bond.md](proposer-bond.md).

| Parameter | Default | Min | Max | Setter |
|---|---|---|---|---|
| `challengeWindow` | 14 d | > 0 and ≥ `reviewPeriod` + 7 d | scan-bounded (16 buckets) | `ExposureLedger.sol:768` |
| `epochLength` | 28 d (immutable) | — | — | ctor |
| `MAX_COVERAGE_HORIZON` | 60 d | const | const | `ExposureLedger.sol:132` |
| `proposerBondBps` | 100 (1%) | 0 | 100% | `ExposureLedger.sol:854` |
| `coveredTvlCapUsd` | 0 = fail-closed (nothing proposable until set) | — | — | `ExposureLedger.sol:843` |
| `woodHaircutBps` | 100% (no haircut — deploy script refuses this; safe value set at deploy) | 50% | 100% | `ExposureLedger.sol:727` |
| `woodUsdPriceX8` | owner-set cap (0 = hard stop `NoWoodPrice`) | — | — | `ExposureLedger.sol:648` |

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

## Call sandbox

`proposeWithSandbox` (`SyndicateGovernor.sol:403`) is the permissionless path to a
tier-2 target. The payload's targets are never allowlisted and never certified.
Four facts make that path sound:

1. **Tier 2 is permissionlessly reachable.**
2. **Isolation, not reputation, bounds the loss.**
3. **Funding is the structural maximum.**
4. **No owner transaction exists anywhere in the flow.**

A governor batch cannot use the tier-2 default. `_guardBatchCalls` is **tier-blind**:
an uncertified target is unreachable, not expensive. The gate cannot simply be
dropped — a batch runs under `delegatecall`, so a sub-call arrives as the vault
and can spend standing allowances. Isolation removes that premise.

`CallSandbox` (`src/CallSandbox.sol:48`) is an ERC-1167 clone the vault mints at
execute, salted on the proposal id. It holds nothing but the vault asset it was
funded with. A target called from the clone sees `msg.sender == address(sandbox)`:
no vault allowance to spend, no vault-held position token to move. The most a
hostile call set can cost is the balance this contract was handed — which is
exactly the figure full-notional tier-2 coverage already charged for.

There is no `setAdapterAllowed`, `certify`, or `setTemplateApproval` step for a
sandbox target. The vault-side binding is factory-only and set-once
(`setSandboxImplementation`, `SyndicateVault.sol:722`; storage
`_sandboxImplementation` at `:504`). `_guardBatchCalls` is not consulted and is
not modified: `runSandbox` (`SyndicateVault.sol:873`) is a separate `onlyGovernor`
entry point, not an exemption inside the batch guard.

`proposeWithSandbox` takes the same arguments as `propose` plus a `SandboxPayload`.
Every other gate belongs to the shared `_propose` body. Payload bounds:

| Field | Bound | Meaning |
|---|---|---|
| `funding` | Non-zero; `≤ envelope.maxCapital` | Vault asset the clone is handed. Structural maximum loss. |
| `calls` | 1–32 (`MAX_SANDBOX_CALLS`) | Arbitrary `(target, data)` pairs. No `value` field. Frozen at propose. |
| `declaredTokens` | 0–16; no duplicates | Non-asset tokens the payload may end up holding. |

`sandboxPayload(proposalId)` (`SyndicateGovernor.sol:506`) returns the stored
payload for the whole review period. Guardians underwrite this call set.

A sandbox is priced at **full funding** and forced to **tier 2** inside
`_snapshotTierAndGate` (`SyndicateGovernor.sol:1747`, sandbox term `:1778-1782`):
`coverage_ += sandboxFunding`. There is no certified bound that could reduce it.
That force is not cosmetic: the approve quorum only applies at or above
`quorumTierThreshold`, so a payload that rode along at tier 0 would be arbitrary
calldata with no identified underwriter on the hook.

`executeProposal` dispatches the sandbox **before** the execute batch. Coverage
scaling uses the same `effective / max` ratio as `effectiveMaxCapital`
(`SyndicateGovernor.sol:875-885`); a payload whose coverage floors to nothing
runs nothing. `runSandbox` is `onlyGovernor`, `nonReentrant`, and pause-gated:
clone, `init` (`CallSandbox.sol:165`), **push** funding (never approve-and-pull),
then `run()` (`CallSandbox.sol:201`) — one-shot; any reverting call reverts the
whole run.

Residue: the clone implements `IStrategyDelivery` so `collectResidue` reaches it
the same way it reaches a settled strategy. `sweep()` (`CallSandbox.sol:328`) is
vault-only. A sandbox holds no registry entry, so there is nothing to demote
and nothing to wedge.

Permissionless **targets**, not permissionless proposing: `registerAgent` stays
`onlyOwner`; only a registered agent can call `proposeWithSandbox`.

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
| `challengeWindow` | 14 d | > 0 | ≤ ledger's window | `ChallengeGame.sol:2088` |
| `challengerBondBps` | 1.5% of frozen coverage | > 0 | 100% | `ChallengeGame.sol:2104` |
| `autoSlashDelay` (silence → conviction) | 7 d | 2 d | < `disputeTimeout` | `ChallengeGame.sol:2176` |
| `disputeTimeout` | 30 d | > `autoSlashDelay` | 60 d | `ChallengeGame.sol:2187` |
| `settleBurnBps` (win burn) | 5% | 0 | 50% | `ChallengeGame.sol:2203` |
| `forfeitBurnBps` (loss burn) | 20% | 0 | 50% | `ChallengeGame.sol:2114` |
| `inconclusiveBurnBps` (round 4+) | 10% | 0 | 50% | `ChallengeGame.sol:2234` |
| `prosecutorFeeBps` (slice of proposer bond) | 20% | 0 | 20% | `ChallengeGame.sol:2217` |

Anti-griefing details:

- All rates are **pinned at filing** — no owner change can re-rate a live challenge.
- Inconclusive retries burn on an escalating schedule per proposal:
  round 1 = 2.5% (`INCONCLUSIVE_BURN_ROUND1_BPS`, `ChallengeGame.sol:192` — a free
  first round let a filer freeze coverage at no cost), round 2 = 5%, round 3 =
  10%, round 4+ = `inconclusiveBurnBps` (10%), each clamped to `settleBurnBps`
  on earlier rounds.
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
  (1 h, `ChallengeGame.sol:98`) reserves referral headroom so a case cannot be
  opened with too little clock left to finish.

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
`GuardianFeeAccrued` events provide per-guardian attribution weights. There are no
on-chain staking emissions — review honestly, earn the fee stream; approve a
malicious strategy, get slashed and burned.
