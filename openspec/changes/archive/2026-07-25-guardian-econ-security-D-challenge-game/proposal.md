# Guardian Economic Security — Plan D: Challenge Game (v1b, part 2)

> Migrated from docs/superpowers/plans/2026-07-25-guardian-econ-security-D-challenge-game.md (superpowers workflow) on 2026-08-01.

## Why

Spec §3.4 requires a trigger above Plan C's payout rails: anyone may post a bonded challenge against an executed proposal, citing a predicate and an evidence pointer, which freezes the accused coverage. Before this change, `authorizedSlasher` was a multisig — liability was driven by governance, not by the mechanism. This plan makes an UNDISPUTED verdict mechanism-driven: if nobody disputes within the delay, the covering approvers are slashed straight into the `CompensationEscrow`; if an accused approver posts a counter-bond, the challenge escalates toward the court (Plan E) and, absent a ruling, times out in favour of the accused.

## What Changes

- New contract `ChallengeGame` (Ownable2Step, not upgradeable — same shape as `TierRegistry`/`ExposureLedger`): bonded `file` (bond scales with frozen exposure, `challengerBondBps`), per-proposal coverage freeze, `dispute` by an accused approver with a matching counter-bond, permissionless `resolve` with two branches — undisputed past `autoSlashDelay` → slash via `StakedWood.slashToEscrow` pinned to `executedAt - 1`, demote the offending adapter, return the challenger's bond; disputed past `disputeTimeout` → challenge fails, challenger's bond forfeits to the accused pro-rata, counter-bond returns.
- `ExposureLedger` gains `approversOf(governor, proposalId)` (public approver getter; released commitments report zero shares) and a per-proposal coverage freeze (`coverageFreezer` role, `freezeCoverage`/`unfreezeCoverage`; `releaseApproval` reverts `CoverageFrozen` while pinned).
- `TierRegistry` gains an `authorizedDemoter` role and `demoteByChallenge` so a passed challenge can demote an adapter without holding registry ownership (revoke-only, never grant).
- No on-chain predicate verification (adjudication is silence, not proof); the `Predicate` enum is event-only classification. The first-detector bounty moved off-chain to a bug-bounty program keyed off `ChallengeFiled`/`ChallengeSettled`.
- Invariant (spec §4, fuzz-tested): the game's WOOD balance always equals the bonds held for challenges still in `Filed`/`Disputed`.
- Deploy script `script/DeployPlanD.s.sol` wires the four roles (ledger freezer, tier demoter, sWOOD slasher; escrow funder confirmed = sWOOD) with pre-flight asserts.

## Capabilities

- challenge-game
- guardian-coverage
- tier-policy

## Impact

- Created: `src/ChallengeGame.sol`, `src/interfaces/IChallengeGame.sol`, `test/ChallengeGame.t.sol`, `test/ChallengeEndToEnd.t.sol`, `script/DeployPlanD.s.sol`
- Modified: `src/ExposureLedger.sol`, `src/interfaces/IExposureLedger.sol`, `src/TierRegistry.sol`, `test/ExposureLedger.t.sol`, `test/TierRegistry.t.sol`, spec status header + §4 phasing note
- Known gaps carried forward (named in the PR, closed by Plan E): a genuinely guilty approver could dispute and run out `disputeTimeout`; vigilance moved to guardians; a bad-faith challenger could freeze coverage for a challenge's duration at the cost of its bond.
- Landed as PR #25 against `feat/guardian-econ-security-c`.
