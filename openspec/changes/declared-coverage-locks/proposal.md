## Why

Every guardian who approves a proposal reserves the proposal's **full** coverage requirement, because at vote time any one of them might end up carrying it alone. Three approvers lock 3× what is needed, and a later permissionless pass (`settleCoverage`) is meant to collapse each reservation to its pro-rata share. That collapse has no sound moment to run: fire it at `executeBy` and a guardian's capacity is freed while their pledge stays slashable for weeks (SHE-212, audit High, reproduced — a $1,000 bond still fully pledged to proposal A books $500 against proposal B); never fire it and guardians sit locked by finished proposals (SHE-225, live, ~29% of bond stranded). Both are symptoms of one mechanism, and every attempt to fix its timing collides with behaviour built on purpose. The A-fold reservation and the machinery that undoes it are removed together (SHE-227, Variant C with Option B).

A second, quieter driver: the `guardian-coverage` spec already describes slashing proportional to a guardian's allocation, while the code slashes the whole bond at a binary rate (moved there under pashov review #13). This change makes the code and the spec agree on the model the spec has always stated.

## What Changes

- **BREAKING** — A guardian **declares** how much WOOD they lock behind a proposal. The lock IS the declaration: no USD conversion at approval, no price read on the approval path. `recordApproval` and the registry's approve vote gain a WOOD amount; SDK, CLI and guardian daemon pass it.
- **BREAKING** — **No cohort cap.** The sum of declarations may exceed the requirement. Over-subscription is a well-covered proposal; under-subscription already scales `effectiveMaxCapital` and needs no new machinery. Nothing ever needs collapsing, so booking equals pledge for the lock's whole life.
- **BREAKING** — **Slash = the locked WOOD** for that (proposal, guardian), burned through the existing review and verdict paths, clamped by the existing `[minSlashBps, maxSlashBps]` envelope of stake. `minSlashBps` is the **single deterrence floor**: a guardian cannot make their penalty smaller than that fraction of everything they hold, whatever they declared. No separate declaration floor.
- **BREAKING** — `settleCoverage` is removed, along with the downward rebook, the settled flag, and both governor self-trigger call sites. The two accumulators whose divergence was SHE-212 (`_liveBookedUsd`, `_livePledgedUsd`) collapse into one.
- **Capacity becomes price-free.** Free budget is `kNumerator × slashable stake − Σ live locks`, all in WOOD. The "unpriceable WOOD books nothing" failure mode on the approval path disappears; the only USD conversion stays where it already is — the execute-time quorum comparison against the proposal's USD requirement.
- `kNumerator` stays a governance knob, default 1. The spec now states the property it controls: at k = 1 a conviction on one proposal leaves every other proposal the guardian backs fully covered, so raising k is legible as deliberate leverage rather than an accounting accident.
- Challenger-bond sizing keeps reading the unshared pledge sum, capped at the proposal's need — the cohort may over-subscribe, but a challenger's bond is sized off what a conviction can recover *for this proposal*, not off the over-subscription.
- Fresh deployment. No migration of live proposals, no per-key version tag, no dual slash predicate.
- The in-progress change `settle-coverage-self-trigger` (15/18 tasks, remaining tasks validation-only) is **archived unfinished**: it wires the exact mechanism this change removes.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `guardian-coverage`: reservation becomes a guardian-declared WOOD lock with no cohort cap; capacity is denominated in WOOD; the allocation, settlement and per-approver slash-rate requirements are replaced by locked-WOOD semantics; the exposure-cap multiplier requirement states the k = 1 containment property; challenger-bond sizing is capped at need.
- `guardian-staking`: the review-path and verdict-path slash requirements size the burn off the locked WOOD for the case, clamped to the stake envelope and to live stake, instead of the whole bond.
- `challenge-game`: accused rates and challenger-bond sizing follow the locked-WOOD basis.
- `deployment-docs`: the Plan B `maxSlashBps == 10_000` pre-flight keeps its constraint but its rationale changes (a lock may equal the whole stake and must be burnable in full), and a `minSlashBps != 0` pre-flight is added — it is now the single deterrence floor.

(`syndicate-governor` is NOT a modified capability: its main spec never gained the coverage-settle trigger — that requirement lives only in the unarchived `settle-coverage-self-trigger` delta. Deleting the trigger code is an implementation task with no main-spec requirement to remove.)

## Impact

- `src/ExposureLedger.sol` — `recordApproval` signature, WOOD-denominated buckets and cap, per-(key, guardian) locked amount, `slashBpsFor` basis, `unsharedLiabilityUsd` cap; `settleCoverage`/`_rebook`/`_settled`/`allocatedUsd` deleted. The ledger is a plain constructor-deployed contract (no proxy, no gap, no golden), so its storage is restructured freely.
- `src/GuardianRegistry.sol` — approve vote carries the WOOD amount through to the ledger.
- `src/StakedWood.sol` — `_slashOne` burns `min(locked, live stake)` under the envelope rather than a rate of the whole bond.
- `src/ChallengeGame.sol` — `_accusedWithRates` consumes the new slash basis; bond sizing reads the capped pledge sum.
- `src/SyndicateGovernor.sol` — `_settleCoverageBestEffort` and its two call sites removed; `CoverageSettleFailed` event removed.
- Interfaces: `IExposureLedger`, `IGuardianRegistry`, `ISyndicateGovernor`.
- Off-chain: SDK, CLI, guardian daemon (`sherwood-guardian`) pass the declared amount on approve.
- `script/DeployPlanB.s.sol` — pre-flight rationale text for `maxSlashBps`; new `minSlashBps != 0` pre-flight.
- Tests: every fixture that calls `settleCoverage` (36 call sites) or relies on full-coverage reservation is rewritten to declarations; the `ExposureLedger_she212PhantomCapacity` reproduction becomes a pinned "cannot happen" test.
- Linear: SHE-212 and SHE-225 resolved by removal; SHE-213 (freeze/pin outlives bucket) remains and is unaffected; SHE-227 implemented.
