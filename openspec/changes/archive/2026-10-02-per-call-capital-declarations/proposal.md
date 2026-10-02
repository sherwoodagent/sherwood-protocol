# Per-call capital declarations — coverage priced per call, metered per call (issue #43)

## Why

**One tier-2 call poisons the whole batch, by design that the design itself calls over-counting.** `SyndicateGovernor._resolveTierAndCoverage` (src/SyndicateGovernor.sol:1150-1163) computes `tier = max(execTier)` and `coverage = maxCapital * (execBps + settleBps) / 10_000` — one proposal-wide `maxCapital`, with every call's `boundBps` applied to that same figure. Its own natspec concedes it (:1142-1144): *"deliberately OVER-counts multi-call batches (n tier-2 calls price n×maxCapital)"*. Four mechanisms then compound (all verified on main):

1. One tier-2 call sets the whole proposal's tier (`_scanCalls` max).
2. Tier 2 prices at full notional (`TierRegistry.tierOf` returns `(2, 10_000)` for anything uncertified), so that single call contributes `maxCapital` to coverage on its own.
3. A covering approve quorum is required at every tier (`quorumTierThreshold == 0` is pinned by DeployPlanB PRE-FLIGHT 4), so that full-notional coverage must actually be raised.
4. The quorum gate is all-or-nothing (`ExposureLedger.requireApproveQuorum` reverts `InsufficientApproveCoverage` — issue #27), so 99% of the required coverage executes nothing.

Chained: a $100k tier-2 experiment inside a $10M proposal requires the cohort to raise $10M+ of coverage, and — because `StrategyAlreadyActive` allows one live proposal per vault — running it as its own proposal idles the other $9.9M. Mixed batches are economically impossible; tier 2 is a proposal type instead of a line item.

**The fix is to thread per-call notional through**: each call declares its own capital cap, coverage becomes the sum of what each call can actually lose (`Σ cap_i × boundBps_i / 10_000`), and the batch executor enforces each declared cap with a per-call gross-outflow meter. On the issue's own example the identical batch's coverage falls from $10,000,000 to $117,500 — from uninsurable to easily underwritten — while the enforcement boundary gets strictly tighter (a call exceeding its declared cap reverts the batch even when the batch total is under `maxCapital`).

**Owner decision (2026-08-03): build now, full scope.** Both halves ship together — propose-time validation (`Σ callCaps ≤ maxCapital` per batch, per-call tier-2 ceiling) AND `BatchExecutorLib` execution-time metering. The validation-only variant stays rejected: unenforced caps are a declaration the chain never checks, which reads as protection that is not there.

## What Changes

- **`propose()` gains two parallel cap arrays** (`executeCallCaps`, `settlementCallCaps`, one `uint256` per call) — an accepted **breaking ABI change** to `propose` (src/SyndicateGovernor.sol:219, ISyndicateGovernor.sol:491). `RiskEnvelope` itself is unchanged; `maxCapital` survives as the proposal-level belt-and-braces ceiling. Caps-as-parallel-arrays over caps-in-envelope is argued in design.md D1.
- **Propose-time validation**: each cap array's length equals its call array's; `Σ executeCallCaps ≤ maxCapital` and `Σ settlementCallCaps ≤ maxCapital` (per batch, not combined — the two batches run separately, each under the `maxCapital` custody cap); every tier-2/uncertified call's cap at or under the new per-call tier-2 ceiling (`tier2CallCapBps` of `totalAssets()` at propose, a new owner-set governor parameter, inert at its default). Zero caps are legal at every tier (design.md D2). Composes beside, not inside, #118's propose-time target rejection (design.md D6).
- **Coverage re-priced**: `_resolveTierAndCoverage` becomes `coverage = Σ cap_i × boundBps_i / 10_000` across execute AND settlement calls. Tier stays batch-wide (`max(execTier)` — design.md D3). The `registry == address(0)` fail-closed default (`(2, maxCapital)`) and both regression guards (`TierRegressed` / `CoverageRegressed`, re-resolved from the stored caps) are preserved.
- **`BatchExecutorLib` gains per-call gross-outflow metering** — the safety-critical half. Signature becomes `executeBatch(Call[] calls, address asset, uint256[] caps)`: snapshot the vault's `asset` balance around each call; a call whose gross outflow exceeds its declared cap reverts the whole batch (`CallCapExceeded(i, outflow, cap)`) — fail-closed on money, matching the vault's `MaxNetOutflowExceeded` idiom. Gross rule per the issue: an inflow in call *j* never refills call *i*'s budget. An empty caps array skips per-call metering (the emergency-path escape valve, still bounded by the batch-level meter); a non-empty array of the wrong length reverts. This is an ABI change to a **shared, deploy-once singleton** — the redeploy-and-rewire migration is a first-class deliverable (design.md D5): factory gains `setExecutorImpl`, vault gains a factory-gated, lifecycle-quiet executor re-point, and the operational sequence (quiesce → deploy lib → upgrade impls together → re-point + re-stamp codehash) is specified.
- **`SyndicateVault.executeGovernorBatch` gains the `callCaps` parameter** and forwards `(calls, asset(), callCaps)` to the lib. Its own single before/after net-outflow meter, queue-reserve and buffer checks are **unchanged in semantics** — the two accounting layers are deliberately distinct and both retained (design.md D4).
- **Governor call sites thread the stored caps**: `executeProposal` passes the execute caps, `settleProposal` and `unstick` pass the stored settlement caps, `finalizeEmergencySettle` passes empty caps (owner-supplied rescue calls have no declared caps; guardian review + `maxCapital` bound them). New view `getCallCaps(proposalId)` — the seam #27 will consume (design.md D7).
- **Storage**: two appended governor mappings (`_executeCallCaps`, `_settlementCallCaps`) + one parameter slot; `StrategyProposal` itself gains no field. `script/syndicate-governor-layout.golden.json` regenerated. Free in practice: no governor or vault proxy is deployed (re-verified 2026-08-03 — no `broadcast/` entry for chain 4663; Base 8453 lineage is legacy/no-upgrades; design.md "Deployment reality").
- **Tests**: the issue's five obligations — mixed batch executes with per-call-sum coverage; a call exceeding its own cap reverts under-`maxCapital` batches; a later refund does not refill an earlier budget; tier-2 cap above the ceiling rejected at propose; layout goldens appended-only — plus regression-guard, empty-caps, and migration tests (tasks.md §8).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `syndicate-governor`: "Proposal creation validation" gains the cap arrays and their three validations; "Risk tiering and proposer bond at propose" re-defines the coverage unit of account as the per-call sum; "Execution safety guards", "Settlement and P&L", and "Emergency settlement paths" thread the caps into batch execution; "Governance parameter management" gains `tier2CallCapBps`; "Factory lifecycle-gated administration" gains the executor migration primitives.
- `syndicate-vault`: "Governor batch execution" carries the caps parameter and forwards to the metered executor; a new "Per-call gross-outflow metering" requirement pins the meter's semantics (gross, per-call, fail-closed, empty-caps escape valve).

## Impact

- `src/BatchExecutorLib.sol` — metered `executeBatch`; `simulateBatch` extended with per-call outflow reporting (off-chain dry-run for cap sizing).
- `src/SyndicateVault.sol`, `src/interfaces/ISyndicateVault.sol` — `executeGovernorBatch` signature; executor re-point primitive.
- `src/SyndicateGovernor.sol`, `src/interfaces/ISyndicateGovernor.sol` — `propose` signature; cap storage/validation; coverage math; caps threading; `getCallCaps`; `tier2CallCapBps`.
- `src/SyndicateFactory.sol`, `src/interfaces/ISyndicateFactory.sol` — `setExecutorImpl`, `pushExecutor`.
- `script/syndicate-governor-layout.golden.json`, `script/syndicate-factory-layout.golden.json` (label-only if any), deploy scripts (new lib wiring; DeployPlanB pre-flight for `tier2CallCapBps`).
- Test blast radius is large but mechanical: every `propose(...)` and `executeGovernorBatch(...)` call site (fixtures/helpers first — tasks.md §6).
- Bytecode: governor ~25.2KB / vault ~25.6KB against Robinhood 4663's 98,304-byte limit — enormous margin. Legacy Base vault (18 bytes under EIP-170) takes no upgrades and is out of scope by standing decision.
- **Not touched**: `ExposureLedger` (issue #154's machinery) — this change only alters the `requiredCoverage` NUMBER the ledger is handed, never its accounting (`_effectiveTotal` etc.); verified by grep, which is why #43 proceeds while #27/#33 are held. `TierRegistry` (off-limits #45) — read-only consumer.

## Sequencing

- **After #118** (`fix/issue-118-propose-target-validation`, in flight): its propose-time target rejection and `isPrivilegedBatchTarget` view land first; this change's validation sits beside it in the same cheap-validation region and its spec delta text incorporates #118's (design.md D6). **After #151** if it lands first per the agreed order (#147 → #118 → #151 → #43): #151 deletes `selfManagesFees` — same `propose()` body, different lines and different struct region; no semantic overlap, rebase-order only.
- **Before #27** (held pending #154): this change redefines the coverage unit of account #27's proportional sizing divides by. The exact interface #27 consumes — `getCallCaps`, the caps-as-batch-parameters plumbing, and the linearity property that makes pro-rata scaling exact — is recorded in design.md D7 so #27's spec does not have to rediscover it.
- No conflict with off-limits #35/#45; #147 (PortfolioStrategy) is disjoint files.
