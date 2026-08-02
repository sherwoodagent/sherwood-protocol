# Burn Slash Proceeds

## Why

Verdict slashing today routes proceeds to `CompensationEscrow`, which pays vault
shareholders pro-rata against an ERC20Votes snapshot. Two problems follow from
that sink.

**1. The escrow sink caps slashing at break-even.** Paying a victim more than
their loss creates a windfall and an incentive to be harmed, so a compensatory
sink structurally bounds the slash at 1x damages. `ExposureLedger.slashBpsFor`
implements exactly that bound: each approver's rate is derived from
`_allocate(mine, effectiveTotal, needUsd)` — their pro-rata slice of the
proposal's *required coverage*, not their bond. `maxSlashBps` is 10,000 in every
deploy script, but it is a ceiling that never binds. A guardian who approves an
attack extracting `V` is slashed approximately `V` and nets approximately zero.
Break-even is not deterrence.

Worse, `needUsd` derives from `getRequiredCoverage(proposalId)`, a tier-derived
estimate of the loss. A proposal whose declared coverage understates what is
actually extractable is slashed for less than it steals.

**2. Slash value does not reach the parties who police the protocol.** Under the
escrow, honest guardians gain nothing when a colluder is convicted. Nothing
prevents a guardian from holding shares in the vault they approve for, so a
self-dealing guardian recovers a slice of their own slash through
`getPastVotes`.

Burning has no counterparty and therefore no windfall constraint: the slash can
exceed the loss without unjustly enriching anyone. That is what makes punitive
(super-compensatory) slashing possible. The destroyed supply accrues to every
WOOD holder, which is predominantly other guardians, since bonding requires
WOOD — so convicting a bad guardian pays the honest ones.

Nothing in the Plan D stack (`StakedWood`, `CompensationEscrow`, `ChallengeGame`,
`ExposureLedger`) has been deployed — there are no broadcast artifacts — so this
is a pre-deployment design change with no migration burden.

## What Changes

### Sink: one burn, three paths

- `StakedWood.slashToEscrow` is renamed `slashVerdict` and burns its net
  proceeds unconditionally. The `try openCase / catch _burnWood` split collapses
  to the burn leg that already exists.
- `slashGuardians` and `slashOwnerBond` already burn 100%; they are unchanged.
  All three slash paths become structurally identical in where value goes.
- The conviction bounty leg is retained: `bounty = gross * bountyBps / 10_000`
  is paid to `bountyTo` from gross, and the remainder is burned. Challenging
  must stay profitable.

### Sizing: punitive, not compensatory

- Verdict slash rate becomes a flat `maxSlashBps` (100% of the live bond at the
  verdict anchor) for every approver the ledger names, replacing the
  coverage-proportional allocation in `ExposureLedger.slashBpsFor`.
- Deterrence condition changes from "slash covers the loss" to "bond exceeds
  maximum extractable value".

### Coverage gate: retained, reframed

- `ExposureLedger.requireApproveQuorum` keeps its inequality
  `sum(min(live_i, reserved_i)) >= needUsd` but changes meaning: it is now a
  **skin-in-the-game eligibility floor** ("these approvers are bonded enough to
  be trusted with this tier"), not an indemnity guarantee ("these approvers can
  make the vault whole").
- The documented `maxSlashBps` recovery-shortfall gap
  (`ExposureLedger.sol:1055-1082`, PR #24 review N3) ceases to be a defect,
  because there is no recovery to fall short of.

### Depositor model: caveat emptor

- The protocol makes no promise to compensate depositors for losses. Guardians
  are a quality filter backed by a punitive bond, not an insurance pool.
- `CompensationEscrow` and every claim path built on it are deleted.

### Deletions

- `src/CompensationEscrow.sol` and `src/interfaces/ICompensationEscrow.sol`
- `VaultWithdrawalQueue.claimCompensation`, `compensationCase`,
  `compensationClaimed`, the `CompCase` struct, `_compCases`, `_compClaimed`,
  and their events and errors
- `StakedWood.compensationEscrow`, `setCompensationEscrow`,
  `_isRecoverableOpenCaseFailure`, `CompensationEscrowNotSet`, and the
  `VerdictSlashRouted` / `VerdictSlashUncompensated` / `CompensationEscrowSet`
  events
- The `vault` and `snapshotTimestamp` parameters of the verdict slash entry
  point, and with them the `SnapshotAfterVerdict` error and the
  `factory.governorOf(vault)` membership check
- `SyndicateFactory.compensationEscrow` and its setter
- `DeployPlanD` pre-flight 1 (escrow/funder wiring)

## Capabilities

### New Capabilities

- `guardian-slashing`: how much a convicted guardian loses, where that value
  goes, and what the protocol does and does not promise depositors

### Modified Capabilities

<!-- none — no existing spec's requirements change; `continuous-integration` is untouched -->

## Impact

- **Contracts:** `StakedWood`, `ExposureLedger`, `ChallengeGame`,
  `SyndicateFactory`, `VaultWithdrawalQueue`; `CompensationEscrow` removed
  entirely. Approximately 700-900 lines net deletion.
- **Gas:** `ChallengeGame.SLASH_GAS_PER_APPROVER` (300k) and `SLASH_GAS_BASE`
  (1M) were sized against Robinhood's 32M per-transaction limit *because of the
  `openCase` child call*. Removing that call requires re-deriving both
  constants downward.
- **Storage layout:** no mainnet 4663 deployment exists and testnets are
  redeployable, so slots are removed outright rather than deprecated —
  following the 2026-07-26 DPoS re-baseline precedent. `StakedWood.__gap` grows
  4 -> 5 to absorb the removed field, and the `SyndicateFactory` golden is
  regenerated in the same PR.
- **Vault:** `SyndicateVault`'s auto-delegate-on-`_update` existed to make
  `getPastVotes` a valid claim basis. It may still be wanted for governance;
  this change does not remove it, but it is no longer load-bearing for slashing.
- **Depositor-facing docs and any coverage marketing** must stop describing
  guardian coverage as compensation for depositor losses.
- **Token:** WOOD exposes no `burn()`, so `BURN_ADDRESS` (`0x...dEaD`) remains
  the sink — the choice `StakedWood` already made deliberately. `totalSupply`
  does not move, so the deflation is a **circulating-supply** effect and depends
  on data providers excluding the dead address. No contract reads WOOD
  `totalSupply`, so nothing internal is affected. See design.md R1.
