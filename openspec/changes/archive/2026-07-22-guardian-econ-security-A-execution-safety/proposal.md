# Guardian Economic Security — Plan A: Execution-Side Safety

> Migrated from docs/superpowers/plans/2026-07-22-guardian-econ-security-A-execution-safety.md + docs/superpowers/specs/2026-07-22-guardian-economic-security-design.md (superpowers workflow) on 2026-08-01.
>
> This archive's `design.md` is the **full master design** for the guardian economic-security program (plans A–F); the other guardian-econ-security plan archives reference it rather than duplicating it.

## Why

The guardian mechanism could not make a coordinated rug unprofitable: the guardian fee paid auto-approvers the same per-stake rate as diligent reviewers; slashing fired only when a review reached block quorum, so a proposal that *executed* — the attacker's success case — carried zero guardian penalty; and passage was optimistic (silence passes), making universal auto-approve the equilibrium. The master design's impossibility result: any fix leaving the executed-outcome path penalty-free cannot deter collusion — executed outcomes must carry liability (R1) and exposed stake must scale with extractable value in the drain's unit of account (R2). Plan A ships the **v1a execution-side** half: hard-bound what any proposal can move *before* any liability machinery exists, with no new trust assumptions.

## What Changes

Implements master design §3.1–§3.2 (merged as PR #13):

- **`TierRegistry`** (new standalone contract, Ownable2Step): maps `(target, selector) → {tier, extractableBoundBps, certifiedCodehash}`. Tier 0 = closed-loop, tier 1 = oracle-bounded discretion, tier 2 = arbitrary calldata / full notional — the **default-deny** for any uncertified selector. `certify` (owner, tier 0/1 only, nonzero bound, contract targets only, snapshots `EXTCODEHASH`), `demote` (owner), and permissionless `poke`. Fail-safe demotion is **lazy**: `tierOf` verifies the live codehash on every read and reports tier 2 on mismatch with no state write — nothing to grief; `poke` persists the demotion for indexers.
- **Per-proposal `RiskEnvelope`** in `SyndicateGovernor.propose`: `{maxCapital (nonzero), maxDrawdownBps (≤ 10_000)}`, validated at propose, stored on `StrategyProposal` (append-only fields, storage-parity checked), exposed via `getRiskEnvelope`.
- **Net-outflow metering** in `SyndicateVault.executeGovernorBatch`: signature gains `maxNetOutflow`; the batch's net asset outflow (before/after balance metering) must not exceed it — `MaxNetOutflowExceeded` otherwise. The governor passes `p.maxCapital` on execute and `type(uint256).max` on settle/emergency paths; inflow batches pass trivially.
- **Propose-time tier resolution**: `_resolveTier` computes proposal tier = max tier across execute calls and `requiredCoverage` = extractable-weighted coverage demand (full `maxCapital` at tier 2; `maxCapital × boundBps / 10_000` for bounded tiers). No registry wired ⇒ tier 2 / full notional (safe default). Plan B's dollar-denominated aggregate exposure cap consumes `requiredCoverage`.
- **Execute-time tier regression check**: `executeProposal` re-resolves the live tier and reverts `TierRegressed` if it exceeds the propose-time tier — a proposal priced at tier 0/1 whose adapter demoted since propose is under-covered and must not run.
- **ERC20 selector guard** (shipped with PR #13 per the master design's implementation-status record) and end-to-end tier lifecycle tests + `TierRegistry` deploy wiring.
- **Explicitly out of Plan A** (delivered by later plans): exposure ledger/approve quorum/proposer bond/covered-TVL cap (Plan B), slash-to-escrow + compensation escrow (Plan C), challenge game (Plan D), two-layer court (Plan E), epoch NAV checkpointing (Plan F). **Removed, do not build** (decision 2026-07-22): all silent/slow-drain protection — aggregate rolling-drawdown predicates, cross-vault accumulators, 30-day exposure lock, per-vault per-epoch outflow cap. The per-*proposal* `maxCapital` meter is core and stays; it is not slow-drain protection.

## Capabilities

- tier-policy
- syndicate-governor
- syndicate-vault

## Impact

- `src/TierRegistry.sol` — new
- `src/interfaces/ITierRegistry.sol` — new
- `src/SyndicateGovernor.sol` — `RiskEnvelope` in `propose`, `_resolveTier`, execute-time regression check, `tierRegistry` wiring, `StrategyProposal` fields appended (`maxCapital`, `maxDrawdownBps`, `envelopeTier`, `requiredCoverage`)
- `src/interfaces/ISyndicateGovernor.sol` — `RiskEnvelope` struct, errors (`ZeroMaxCapital`, `InvalidDrawdown`, `TierRegressed`), views (`getRiskEnvelope`, `getProposalTier`, `getRequiredCoverage`)
- `src/SyndicateVault.sol`, `src/interfaces/ISyndicateVault.sol` — `executeGovernorBatch(calls, maxNetOutflow)` + `MaxNetOutflowExceeded`
- `test/TierRegistry.t.sol`, `test/governor/RiskEnvelope.t.sol`, `test/governor/TierResolution.t.sol`, `test/vault/OutflowMetering.t.sol`, `test/integration/TierEndToEnd.t.sol` — new suites; every `propose()`/`executeGovernorBatch()` call site swept
- Deploy scripts — `TierRegistry` deploy + governor wiring
