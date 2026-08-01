# Guardian Economic Security — Plan B: Coverage, Quorum, and Bonds (v1a completion)

> Migrated from docs/superpowers/plans/2026-07-24-guardian-econ-security-B-coverage-quorum.md (superpowers workflow) on 2026-08-01.

## Why

Plan A (PR #13, see `openspec/changes/archive/2026-07-22-guardian-econ-security-A-execution-safety/`) shipped execution-side bounds — envelopes, metering, tiering, the selector guard — and stores a `requiredCoverage` figure per proposal that nothing yet consumed. The master design's v1a phase (§3.3, §3.3a, §3.6-bond, §3.7, §3.9) requires that this coverage figure actually bind: a dollar-denominated aggregate exposure cap per guardian, an explicit approve quorum for coverage-consuming proposals (so silence cannot pass a tier-2 drain), a risk-scaled proposer bond, a hard WOOD-only covered-TVL cap, and an adapter-submitter bond. Without them, guardian approvals carry no economic weight relative to what a proposal can extract.

## What Changes

- New standalone `ExposureLedger` (Ownable2Step singleton): governance-set conservative WOOD→USD price (`priceHaircut` — no WOOD Chainlink feed exists), per-asset Chainlink feeds with fail-closed staleness checks, `slashableBondUsd(g)` per §3.3 (own stake plus delegated stake counted only at the `maxDelegatedSlashBps` cap), epoch-bucketed open-exposure tracking (§3.4a), covered-TVL cap check (§3.7), and approve-quorum check (§3.3a, live bond reads).
- New `ProposerBondEscrow`: ownerless WOOD escrow keyed by `(governor, proposalId)`; governor-only lock/release; no forfeit path in v1a (forfeiture routes to Plan C's compensation escrow).
- `GuardianRegistry` (UUPS upgrade): `exposureLedger` slot + `setExposureLedger`; `voteOnProposal` records exposure on approve-side votes and releases on Approve→Block vote changes — an over-cap guardian's approve vote reverts `ExposureCapExceeded`.
- `SyndicateGovernor` (beacon upgrade): covered-TVL cap check and risk-scaled proposer bond lock at `propose` (CEI-ordered — `collaborationDeadline` write hoisted ahead of the state-changing `lockBond` external call); approve quorum enforced at `executeProposal` for proposals with `envelopeTier >= quorumTierThreshold` (launch value 2); permissionless `reclaimProposerBond` releasing against the escrow address stored per proposal.
- `TierRegistry`: `certify` gains a `submitter` parameter and pulls a submitter bond held while certified; demotion starts a `bondReleaseDelay` timelock before `claimSubmitterBond` (§3.6).
- `SyndicateFactory`: `exposureLedger`/`bondEscrow` slots, setters, pushes at `createSyndicate`, and a `pushWiring` rewire entrypoint for governors created before wiring existed (closes LOW-1, issue #19).
- Deploy script `script/DeployPlanB.s.sol` with the sWOOD `coolDownPeriod >= epochLength + challengeWindow` pre-flight; storage-layout goldens regenerated (verified append-only); end-to-end adversarial suite (batching attack, cold-start thin cohort, WOOD price crash, optimistic-lane preservation).

Landed as PR #22 on branch `feat/guardian-econ-security-b`, rebased onto the proposal-lifecycle refactor per `openspec/changes/archive/2026-07-24-lifecycle-planB-integration/`.

## Capabilities

- guardian-coverage
- challenge-game
- tier-policy
- guardian-staking
- syndicate-governor

## Impact

- New: `src/ExposureLedger.sol`, `src/interfaces/IExposureLedger.sol`, `src/ProposerBondEscrow.sol`, `src/interfaces/IProposerBondEscrow.sol`, `script/DeployPlanB.s.sol`
- Modified: `src/GuardianRegistry.sol` (+`exposureLedger` slot, gap 50→49), `src/SyndicateGovernor.sol` (+`_exposureLedger`/`_bondEscrow` slots, gap 33→31; `StrategyProposal` appends `proposerBondWood` + `proposerBondEscrow`), `src/TierRegistry.sol`, `src/SyndicateFactory.sol`, `src/interfaces/IGuardianRegistry.sol`, `src/interfaces/ISyndicateGovernor.sol`, `src/interfaces/ISyndicateFactory.sol`
- Tests: `test/ExposureLedger.t.sol`, `test/ProposerBondEscrow.t.sol`, `test/TierRegistry.t.sol` (extended), `test/RegistryExposureHook.t.sol`, `test/GovernorCoverageGates.t.sol`, `test/FactoryCoverageWiring.t.sol`, `test/CoverageEndToEnd.t.sol`, storage-layout goldens
