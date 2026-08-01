# Design — Plan D: Challenge Game

> Master design: this plan implements §3.4 of the guardian economic security design — see `openspec/changes/archive/2026-07-22-guardian-econ-security-A-execution-safety/design.md` (not duplicated here). Below are only this plan's own architecture notes and decisions.

## Context

Build the challenge game of spec §3.4 — the *trigger* above Plan C's payout rails. One new contract, `ChallengeGame` (Ownable2Step, not upgradeable). It reads `executedAt` and the vault from `SyndicateGovernor` and the covering approver set from `ExposureLedger`, freezes that proposal's committed coverage while a challenge is live, and on a passed challenge calls `StakedWood.slashToEscrow` — which Plan C already built and tested. `ExposureLedger` gains a coverage freeze and a public approver getter; `TierRegistry` gains an authorized-demoter role.

Sequencing: Plan A (§3.1–3.2) → Plan B (v1a) → Plan C (v1b part 1, PR #24) → **this** → Plan E (two-layer court, §3.5) → Plan F (§3.4a epoch NAV checkpointing) → Plan G (§3.10 approver premium + watchtower funding, gated on the §4 blocking ROE validation).

**Deliberate deviation from spec §4's phasing, decided 2026-07-25.** §4 ordered the court LAST (v1c), after the epoch machinery and the premium, reasoning that "an order that front-loads the novel forensic court while deferring the machinery that bounds loss is backwards for risk." That reasoning held while the court was the ONLY path to liability. It no longer is: this plan lands a working undisputed-slash path, so the court stops being the whole mechanism and becomes the patch for one escape hatch — a guilty approver disputing and running out `disputeTimeout` (D5). Leaving that hole open across two more plans is worse than building the court earlier, and nothing in the epoch machinery or the premium is a prerequisite for it. The spec's §4 phasing was updated to match.

## Goals / Non-Goals

- Goal: bonded permissionless filing against executed proposals; silence auto-slashes; a counter-bond escalates.
- Goal: freeze exactly the accused proposal's committed coverage while a challenge is live.
- Goal: passed challenges demote the offending adapter (revoke-only role).
- Non-goal: on-chain predicate verification (see the decisive design fact below).
- Non-goal: adjudication of a disputed challenge (Plan E); §3.4a epoch NAV checkpointing (Plan F); watchtower funding and §3.10 approver premium (Plan G); any on-chain first-detector bounty (moved off-chain — no constant can be "sized to cover forensic cost", which runs from minutes to days per case; on-chain a successful challenger only breaks even).

## Decisions

### The decisive design fact: adjudication is silence, not on-chain proof

§3.4's flow is **assertion + silence**, not verification: an undisputed challenge auto-slashes after a delay; a disputed one (accused post a counter-bond) escalates to adjudication (§3.5). Nothing in the spec asks the chain to *verify* a predicate — the accused is given a window and a cheap way to contest; not contesting IS the adjudication. An earlier draft added an on-chain `prove()` re-deriving predicates 1/4/5 from stored calldata. Dropped, for three reasons:

1. **It was never required.** An addition beyond §3.4 that bought real risk — calldata parsing with the exact `transferFrom` arg-2 offset bug PR #13's review caught, historical oracle round lookups, and a duplicate of logic the vault's `_guardBatchCalls` already implements. Two copies of a parser is a divergence waiting to happen.
2. **Only three of five predicates could ever be proven on-chain anyway.** Predicate 2 (oracle price deviation) needs a venue-specific fair-value model; predicate 3 (proposer-linked destination) is a funding-graph question §8 itself says "needs a consistent evidentiary standard." A design where 1/4/5 are code-enforced and 2/3 are judge-enforced runs two different security models in one mechanism.
3. **Judges are already the trust root for the hard cases.** Extending them to the easy cases adds no new trust assumption; it removes a bifurcation.

So a challenge is an assertion with an evidence pointer. All five predicates are handled identically: file with a bond and an `evidenceURI`, freeze the accused coverage, and let silence or a counter-bond decide.

**The consequence, named in the PR:** vigilance cost moves to guardians. A guardian who sleeps through the dispute window is slashed on an unproven assertion. Defensible — they are staked professionals, the challenger posts a bond scaled to the coverage it freezes, and a bad-faith challenger forfeits that bond — but a genuine shift in who bears the watching burden, and why the dispute window must be generous relative to the auto-slash delay (`autoSlashDelay` is bounded to a sane floor).

### Pinned decisions

- **D1 — A challenge is a bonded assertion; adjudication is silence.** No on-chain predicate verification. All five predicates take the same path. The `Predicate` enum is retained purely as a classification carried in the event so watchtowers, indexers and (later) judges can filter and route — it branches no logic.
- **D2 — Who gets slashed: the ledger's committed approvers.** `ExposureLedger._approversOf[reviewKey]` is the covering set, and each entry's committed share is what that guardian actually backed; this plan adds the `approversOf(governor, proposalId)` getter. Slashing that exact set is what makes §2's inequality hold: recovery is the sum of *their* bonds.
- **D3 — Freeze is per-proposal, never whole-stake** (§3.4 "Freeze scope"). A live challenge pins the proposal's committed coverage so `releaseApproval` cannot free it and the guardian cannot recycle that budget while under challenge. It does not touch the guardian's stake or its other open approvals.
- **D4 — Challenger bond scales with frozen exposure** (§3.4). `bond = frozenCoverageUsd * challengerBondBps / 10_000`, converted to WOOD at the ledger's haircut price. The ONLY deterrent to frivolous filings now that no proof is required, so it is load-bearing — a failed challenge forfeits it to the accused approvers pro-rata to their committed shares.
- **D5 — A disputed challenge times out in favour of the accused.** The counter-bond stops the auto-slash clock and escalates to the court. The court (Plan E) did not exist yet, so without a fallback both bonds and the frozen coverage would sit stuck forever — anyone could freeze a guardian's coverage indefinitely just by filing. Therefore: no ruling within `disputeTimeout` → the challenge fails — challenger's bond forfeits to the accused, coverage unfreezes. Fail-safe toward *not* slashing, the right default when the adjudicator is missing. Accepted consequence: until Plan E ships, a genuinely guilty party can dispute and run out the clock — the honest cost of shipping the game before the court, strictly better than an indefinite freeze.
- **D6 — The compensation snapshot is the block before execution.** Per §3.8, "pre-drain block" is the block before the challenged proposal executed. `ChallengeGame` passes `executedAt - 1` to `slashToEscrow`. Plan C's `snapshotTimestamp <= openedAt` guard is satisfied because the challenge opens after execution.
- **D7 — Adapter demotion needs a new role.** §3.4: "Adapters demote only on a **passed** challenge." `TierRegistry.demote` is `onlyOwner`, so this plan adds an `authorizedDemoter` role (owner-set, pointed at `ChallengeGame`) rather than making the game the registry owner — the game can revoke a certification, never grant one. `demoteByChallenge` reuses the same `_demote` path as owner demotion so the submitter-bond release timelock starts identically (§3.6 slash-first layering).
- **No escrow pointer and no `detectorBountyWood` on the game.** The compensation escrow is owner-set state on sWOOD rather than anything the game names, so the game can never redirect the proceeds of a slash it triggers.
- **Invariant** (spec §4 requires one per new accounting path, with a fuzz test): the game's WOOD balance always equals the sum of (challenger bonds + counter-bonds) held for challenges still in `Filed` or `Disputed`.

## Risks / Trade-offs

- (a) A genuinely guilty approver can dispute and run out `disputeTimeout`, escaping the slash until Plan E ships (D5) — the accepted cost of failing safe when the adjudicator is missing.
- (b) Vigilance moves to guardians, who are slashed on an unproven assertion if they sleep through `autoSlashDelay` (D1).
- (c) A bad-faith challenger can freeze a guardian's coverage for the duration of a challenge at the cost of its bond.
- All three are direct consequences of shipping the game before the court, stated in the PR rather than discovered.
- Type-consistency pins from the plan's self-review: `approversOf(address,uint256) → (address[], uint256[])` used identically across ledger, resolve path, and end-to-end tests; `demoteByChallenge(address,bytes4)`; `Predicate`/`Status` enum member names identical everywhere. `slashToEscrow`'s arity as of this plan was Plan C's post-review six-parameter form `(bytes32 caseKey, uint256 openedAt, address[] approvers, uint256 slashBps, address vault, uint256 snapshotTimestamp)` — the escrow address is owner-set state on `StakedWood`, NOT a parameter. **STALE as of the 2026-07-29 court-incentives change:** its Task 1 appended `(address bountyTo, uint256 bountyBps)`, making the real arity today eight parameters, capped in `StakedWood` by `MAX_CONVICTION_BOUNTY_BPS`.
