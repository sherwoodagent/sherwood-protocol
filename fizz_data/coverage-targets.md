# Coverage Targets

Fuzz profile: **via_ir required (stack too deep), optimizer_runs = 0** — coverage deflated ~10%, targets adjusted.

`setup_fuzz_profile.sh` tried `via_ir = false` first (which would give accurate
numbers) and hit the same stack-too-deep this repo already documents in its
`[profile.coverage]` block. Attempt 2 — `via_ir = true` with the optimizer
disabled — compiled, so the Yul optimizer's branch merging is reduced but not
eliminated. Every target below is therefore ~10 points under the value the
same harness would need on an un-deflated build.

Build command for all Medusa runs: `FOUNDRY_PROFILE=fuzz forge build`

## Per-contract targets

| Contract | Role | Target (ir-no-opt) |
|---|---|---:|
| SyndicateVault | Core protocol logic | 70% |
| SyndicateGovernor | Core protocol logic | 70% |
| StakedWood | Core protocol logic | 70% |
| ExposureLedger | Core protocol logic | 70% |
| ChallengeGame | Core protocol logic | 70% |
| TokenCourt | Core protocol logic | 70% |
| VaultWithdrawalQueue | Core protocol logic | 70% |
| GuardianRegistry | Access control / role management | 50% |
| TierRegistry | Access control / role management | 50% |
| ProposerBondEscrow | Peripheral (driven by governor + game) | 40% |

## Out of scope for this campaign

Documented here so their absence from the report is not read as a coverage gap:

- **PortfolioStrategy, MorphoSupplyStrategy, BaseStrategy, StrategyFactory** —
  require live external venues (Uniswap, Morpho, Chainlink Data Streams). The
  repo's own fork tests for these already fail without an RPC.
- **UniswapSwapAdapter** — same reason; it is the contract the 9 failing
  `UniswapAdapterFork` tests target.
- **WoodTwapOracle** — needs a UniswapV2 pair with a real cumulative-price
  history. `ExposureLedger`'s governance price leg is fuzzed instead, which
  applies the same pressure to X-7's `min(oracle, governance)` composition.
- **SyndicateFactory** — one-shot deployment and wiring. The harness stands in
  as the factory, so the factory-gated paths ARE exercised, just not through
  `SyndicateFactory` itself.
- **ProtocolConfig, FeeConstants** — pure configuration, no state machine.
- **TokenVesting, VestingFactory** — self-contained and uncoupled from the core
  protocol; nothing in the fuzzed surface reaches them.

## Cycle history

### Cycle 1 — 2026-08-04

Medusa ran a full campaign: 105 tests passed, 0 failed.

| Contract | Role | Target | Hit | Status |
|---|---|---:|---:|:--:|
| StakedWood | Core | 70% | 63.3% (188/297) | ❌ |
| TierRegistry | Access control | 50% | 61.3% (76/124) | ✅ |
| SyndicateVault | Core | 70% | 37.1% (142/383) | ❌ |
| TokenCourt | Core | 70% | 29.5% (43/146) | ❌ |
| ChallengeGame | Core | 70% | 20.3% (77/380) | ❌ |
| GuardianRegistry | Access control | 50% | 19.8% (80/404) | ❌ |
| ExposureLedger | Core | 70% | 19.3% (88/457) | ❌ |
| VaultWithdrawalQueue | Core | 70% | 14.0% (15/107) | ❌ |
| SyndicateGovernor | Core | 70% | 12.4% (70/563) | ❌ |
| ProposerBondEscrow | Peripheral | 40% | 8.5% (4/47) | ❌ |

**1/10 at target.** The distribution is diagnostic, not random: `StakedWood` and
`TierRegistry` — the two subsystems reachable without a proposal — lead, and
everything gated behind one collapses. The proposal lifecycle was not
progressing.

Two causes, both fixed for cycle 2:

1. **`propose` was mostly reverting on identity.** It requires
   `isAgent(msg.sender)`, but the clamped handler used whatever actor the
   rotation had selected — an agent roughly a third of the time. Added
   `_toAgent()` and pinned the actor in both propose handlers.
2. **`Executed` was practically unreachable.** It requires propose →
   votingPeriod → openReview → reviewPeriod → resolveReview → execute in
   order, which random call sequencing almost never assembles. Since a
   challenge can only be filed against an EXECUTED proposal, the whole
   adjudication subsystem was dead. Added two composites —
   `syndicateGovernor_lifecycle_toExecuted` (propose → guardian approve →
   review → execute) and `syndicateGovernor_lifecycle_toSettled` (warp past
   `strategyDuration`, settle, which stamps the queue price I-16 depends on).

The individual steps stay exposed so the fuzzer can still interleave them
adversarially and reach the partial-progress states the composites skip.

### Cycles 2–3 — INVALID, discard

Both reported coverage byte-identical to cycle 1. Neither was a measurement:
`crytic-compile` was reading a stale `fizz_data/crytic-export/` that never
contained the new handlers, and an 857-sequence corpus from the pre-fix code was
dominating the run. Confirmed by `FizzAdapter` being absent from both the export
and the run log while present in `out/`.

Root cause of the export failure: **forge 1.7.1 writes slim build-info**
(`id`, `language`, `source_id_to_path`) with no top-level `output` key.
`crytic-compile` 0.3.7 — the version Nix exposes transitively via slither —
raises `KeyError: 'output'` on it. **0.3.10 handles it** (it runs its own
`forge clean && forge build --build-info`). Every Medusa run must therefore
put the 0.3.10 store path ahead of slither's on `PATH`.

### Cycle 4 — first valid campaign, 2026-08-04

First run with the toolchain, harness, lifecycle composites and properties all
genuinely in the same build.

| Contract | Role | Target | Cycle 1 | Cycle 4 | Status |
|---|---|---:|---:|---:|:--:|
| VaultWithdrawalQueue | Core | 70% | 14.0% | **91%** | ✅ |
| ProposalLifecycle | Core (governor base) | 70% | — | **87%** | ✅ |
| GovernorEmergency | Core (governor base) | 70% | — | **74%** | ✅ |
| SyndicateVault | Core | 70% | 37.1% | **73%** | ✅ |
| GovernorParameters | Core (governor base) | 70% | — | 69% | ❌ |
| StakedWood | Core | 70% | 63.3% | 64% | ❌ |
| TierRegistry | Access control | 50% | 61.3% | **64%** | ✅ |
| SyndicateGovernor | Core | 70% | 12.4% | 63% | ❌ |
| GuardianRegistry | Access control | 50% | 19.8% | 40% | ❌ |
| ProposerBondEscrow | Peripheral | 40% | 8.5% | 34% | ❌ |
| ExposureLedger | Core | 70% | 19.3% | 33% | ❌ |
| ChallengeGame | Core | 70% | 20.3% | 26% | ❌ |
| TokenCourt | Core | 70% | 29.5% | 29% | ❌ |

**5/13 at target.** The LP and governance lanes are well covered; the
adjudication chain (challenge → court → slash) is not.

Why adjudication lags: reaching a *conviction* needs
execute → file → dispute-to-pool-completion → refer → vote → finalize → rule,
with real time between each and a bonded challenger at every step. The
composites only carry a proposal to Executed and Settled; there is no
equivalent composite for the challenge lifecycle. That is the single highest-value
next improvement — a `challengeGame_lifecycle_toConviction` composite would
likely move ChallengeGame, TokenCourt, ExposureLedger and ProposerBondEscrow
together, since all four are gated behind the same chain.

Property results: **130 passed, 0 failed** after correcting GL-09 and GL-16
(see below). No protocol violation was found in this campaign.
