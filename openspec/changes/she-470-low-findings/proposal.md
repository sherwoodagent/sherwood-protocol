# Resolve the internal review's Low findings (SHE-470, L-1..L-14)

## Why

The internal review SHE-470 confirmed 14 Low findings (Linear SHE-479..SHE-492). Seven are cheap,
local code fixes that remove a wedge or a griefing path; seven are design choices that are accepted
and need to be stated where an auditor reads the trust model. Doing them in one change keeps the
accepted-risks document and the specs in step with the code.

## What Changes

Code:

- **L-1 (SHE-479)** `SyndicateVault.executeGovernorBatch`: the buffer floor is
  `reserve + (balanceBefore − reserve) × minBufferBps / 10_000`, and it is skipped when
  `maxNetOutflow == 0` (settle, `unstick`, emergency finalize). The setter keeps no lifecycle gate.
- **L-2 (SHE-480)** A batch leg with non-zero `Call.value` reverts `CallValueNotAllowed(index)`, in the
  vault's `_guardBatchCalls` (execute, settle, `unstick`, emergency) and in the governor's
  propose-time mirror `_mirrorBatchLeg`.
- **L-3 (SHE-481)** `StrategyFactory.cloneAndInitDeterministic` salts CREATE2 with
  `keccak256(abi.encode(vault, msg.sender, salt))`.
- **L-5 (SHE-483)** `SyndicateVault.rotateOwnership` drains the agent set only when the owner changes.
- **L-8 (SHE-486)** `GuardianRegistry.voteBlockEmergencySettle` refuses unless the governor reports the
  proposal `Executed`; the SHE-471 probe becomes a shared `_governorReports` helper.
- **L-9 (SHE-487)** `ProposalLifecycle._afterVote`: a paused registry holds a proposal in
  `GuardianReview` only until `executeBy`, then it is `Expired`.
- **L-10 (SHE-488)** `ChallengeGame.file` seeds `challengeableUntil` with the baseline deadline, and
  `_rearmChallengeWindow` spends the one-shot latch only when it extends that deadline.

Documentation (`docs/audit-scope-and-accepted-risks.md`, natspec):

- **L-4 (SHE-482)**, **L-6 (SHE-484)**, **L-7 (SHE-485)**, **L-11 (SHE-489)**, **L-12 (SHE-490)**,
  **L-13 (SHE-491)**, **L-14 (SHE-492)** accepted and stated. Natspec corrected on
  `GuardianRegistry.isEmergencyOpen` (L-7), the performance-fee donation comment (L-12) and
  `ChallengeGame.honestFilingBreaksEven` (L-14).

## Capabilities

### Modified Capabilities

- `syndicate-vault`: buffer floor net of the queue reserve and skipped at zero budget; batch legs carry
  no value; a same-owner rotation keeps the agent set.
- `syndicate-governor`: a paused registry cannot hold a proposal past `executeBy`.
- `guardian-slashing`: an emergency block vote lands only while the proposal is `Executed`.
- `challenge-game`: the re-arm is spent only by an extension past the deadline already in force.
- `tier-policy`: the deterministic clone salt binds the deployer.

## Impact

- `src/SyndicateVault.sol`, `src/interfaces/ISyndicateVault.sol` (new error `CallValueNotAllowed`),
  `src/SyndicateGovernor.sol`, `src/ProposalLifecycle.sol`, `src/GuardianRegistry.sol`,
  `src/ChallengeGame.sol`, `src/StrategyFactory.sol`. No storage layout change.
- Off-chain: the SDK's `effectiveStrategySalt` must become `keccak256(abi.encode(vault, deployer, salt))`
  (tracked separately), and must not ship while clients talk to the live 4663 factory. The guardian
  daemon SHOULD call `resolveEmergencyReview` once a blocked round passes `reviewEnd` (L-7).
- Deployment scope: the vault fixes (L-1, vault-side L-2, L-5) reach only vaults deployed from the v2
  vault impl, and L-3 only a newly deployed `StrategyFactory`. Live 4663 vaults and the live factory keep
  v1 behaviour (`docs/upgrade-v1-to-v2-runbook.md` §1).
