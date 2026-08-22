# Design — Plan E: Two-Layer Court

> Master design: this plan implements §3.5 of the guardian economic security design — see `openspec/changes/archive/2026-07-22-guardian-econ-security-A-execution-safety/design.md` (not duplicated here). Below are only this plan's own architecture notes and decisions.
>
> NOTE: the `Court` contract designed here was later superseded by the single-layer token court (`openspec/changes/archive/2026-07-28-token-court/`); the `ChallengeGame.rule` seam survived.

## Context

Build the adjudication layer of spec §3.5 — the bonded panel and the token-vote appeal that resolve the challenges Plan D can only park. One new contract, `Court` (Ownable2Step, not upgradeable — the house shape). A disputed challenge is referred to a panel of governance-elected members, each holding a slashable bond; the panel rules within `panelWindow`. Any ruling is appealable to a full WOOD vote weighted by `StakedWood.getPastVotes` at the block before the challenged proposal executed, and an appeal only overturns if turnout clears a participation floor. A separate token vote — never the merits appeal — decides whether a ruling was made in bad faith and slashes the panelist's bond. The final outcome calls a new court-only `ChallengeGame.rule(challengeId, guilty)`, routing into Plan D's existing `_settle` (slash into the compensation escrow) or `_fail` (challenger's bond forfeits to the accused).

Sequencing: Plan A → Plan B → Plan C (PR #24) → Plan D (PR #25) → **this**. Remaining afterwards: Plan F (§3.4a epoch NAV checkpointing) and Plan G (§3.10 approver premium + watchtower funding, gated on the §4 blocking ROE validation).

### Two facts that shaped this plan

1. **The aged-stake requirement is already satisfied — do not build it again.** §3.5 asks that "dispute voting weight uses **aged** stake … so WOOD accumulated shortly before the exploit carries reduced weight." `StakedWood`'s interface documents `getPastVotes` as "AGE-WEIGHTED own staked + delegated-inbound capped at `delegatedWeightCapX ×` aged own" (`src/interfaces/IStakedWood.sol:66-67`). The pre-accumulation defense comes free from the existing primitive: read `getPastVotes(voter, snapshotTs)` and the age weighting is applied for you. Writing new age math would duplicate — and inevitably diverge from — the staking contract's.
2. **This plan cannot be split into "panel now, appeal later."** §3.5 is explicit: "A token vote alone is (1) incompetent for forensic questions (single-digit turnout, narrative over trace) and (2) capturable at ~$15M mcap. A standalone panel is bribable (5 humans, bribe 3) with no check above it. The layers cover each other's failure mode." Shipping the panel without the appeal deploys a mechanism the spec names as bribable, holding authority over 100% slashes; shipping the appeal without the panel puts forensic questions to a single-digit-turnout token vote. Neither half is safe alone, so `Court` must not be wired into `ChallengeGame` until both layers plus the bad-faith track are live — enforced as a deploy-time pre-flight, not a convention.

## Goals / Non-Goals

- Goal: close Plan D's D5 hole — a disputed challenge must be resolvable on the merits before `disputeTimeout`.
- Goal: two mutually covering layers plus an independent bad-faith track, wired atomically.
- Non-goal: on-chain panel elections (D1 — roster is owner-set from an off-chain governance result).
- Non-goal: §3.4a epoch NAV checkpointing (Plan F); approver premium and watchtower funding (Plan G).
- Non-goal: new age-weighting math (fact 1 — reuse `getPastVotes`).

## Decisions

- **D1 — Panel membership is owner-set; elections stay off-chain.** §3.5 says panel members are "elected by WOOD governance"; on-chain elections are a governance subsystem in their own right and out of scope. `Court` takes an owner-set roster (`setPanel`), the owner being the governance multisig executing the election result. The *selection* is trusted, the *behaviour* is bonded.
- **D2 — The snapshot is `executedAt - 1`, reusing Plan C's rule.** §3.5 snapshots voting power "before the challenged proposal's execution block" — the same instant §3.8 uses for compensation claims and Plan D passes to `slashToEscrow`. Computed ONCE at `refer` and stored; every later vote reads the stored value, so no two votes can disagree about the electorate. One rule, three consumers — do not invent a second.
- **D3 — Aged stake comes from `getPastVotes`; the floor denominator from `getPastTotalVotes`.** `turnout >= participationFloorBps * getPastTotalVotes(snapshotTs) / 10_000`. Do not re-weight — the age weighting is already inside `getPastVotes`.
- **D4 — Bad faith is a SEPARATE vote from the merits appeal (F6).** The single most important structural point in §3.5. The first draft slashed the panel bond only on a merits overturn, which "let an attacker who controls the cheap appeal make a corrupt ruling safe and gave panelists a beauty-contest incentive to predict the vote." Therefore: overturning a ruling on the merits must not slash the panelist, and controlling the merits appeal must not immunize one. Two independent tracks, two independent votes — tested for independence in BOTH directions.
- **D5 — Panelist reward is flat.** Independent of which way they rule, so there is no incentive to track the expected vote rather than the evidence (§3.5).
- **D6 — Below the participation floor, the panel ruling stands.** An appeal that fails quorum is not an acquittal and not a conviction — a non-event; the panel's ruling is final and the appellant's bond forfeits. This removes the "swing a single-digit-turnout appeal cheaply" path (own branch, own event — the anti-capture property).
- **D7 — A guilty verdict slashes at `maxSlashBps`, no severity ramp** (§3.5: "ground truth established"). Plan D's `_settle` already does exactly this; the court supplies only the guilty/not-guilty bit.
- **Fail-safe default:** a panel that does not rule within `panelWindow` (or ties) yields `NotGuilty` — fail-safe toward not slashing, consistent with Plan D's D5. A real property, documented, not an accident.
- **Slashed panel bonds go to the protocol backstop** (the same address `CompensationEscrow.backstop` uses), not the escrow's per-case claims — a corrupt panelist's bond is not the drained value, and mixing them would let a bad-faith slash inflate a victim case.
- **Invariant** (spec §4, fuzz-tested): the court's WOOD balance always equals (panel bonds posted by seated panelists) + (appeal and bad-faith bonds for votes still open).

## Risks / Trade-offs

- (a) D1 means a compromised governance multisig can seat a captured panel — the bad-faith track and the sovereign appeal are the checks, not the roster.
- (b) A panel that simply never rules yields `NotGuilty` by default, so an inactive panel acquits rather than convicts — fail-safe, but panel liveness becomes an operational requirement.
- (c) The participation floor is a fixed bps of `getPastTotalVotes` at the snapshot — if staking participation collapses, the floor gets easier to clear in absolute terms.
- Type-consistency pins from the plan's self-review: `ChallengeGame.rule(uint256,bool)` used identically everywhere; `Ruling {None, Guilty, NotGuilty}` member names identical across panel/appeal/bad-faith tasks; the snapshot is `executedAt - 1` everywhere (D2), the same expression Plan C's `slashToEscrow` and Plan D's `_settle` already use; `getPastVotes(address,uint256)` / `getPastTotalVotes(uint256)` match `src/interfaces/IStakedWood.sol` exactly.
