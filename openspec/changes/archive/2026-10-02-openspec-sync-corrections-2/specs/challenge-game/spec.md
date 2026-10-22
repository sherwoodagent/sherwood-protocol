## MODIFIED Requirements

### Requirement: Filing a bonded challenge
`ChallengeGame.file(governor, proposalId, predicate, adapterTarget, adapterSelector, evidenceURI)` SHALL be permissionless and SHALL accept a filing only against an EXECUTED proposal (`executedAt != 0`, read from the governor; otherwise revert `NotExecuted`), and only while `block.timestamp <= max(executedAt + strategyDuration + challengeWindow, challengeableUntil[reviewKey])` (otherwise revert `WindowClosed`), where `executedAt` and `strategyDuration` come from the same `getProposal` read and `challengeWindow` is the game's live value. The deadline MUST be recomputed as a max against that live baseline on every call, never read as a stored absolute, so the extension can only ever raise it. The cited predicate (one of `OutOfAdapterOutflow`, `OraclePriceDeviation`, `ProposerLinkedOutflow`, `RogueAllowance`, `DrawdownBreach`) SHALL be a classification label only — recorded and emitted in `ChallengeFiled` but branching no logic; there is no on-chain predicate verification. `evidenceURI` SHALL be carried unindexed in `ChallengeFiled` as the off-chain evidence anchor. The review key SHALL be `keccak256(abi.encode(governor, proposalId))`, matching the ledger and registry derivation. `file` SHALL also revert `AlreadyConvicted` when the proposal is already convicted or sWOOD reports `verdictSlashed` under that key for any accused approver. With sWOOD unwired `file` reverts `ZeroAddress`, but only after the bond is computed, so a filing that cannot be priced or whose bond floors to zero reverts `WoodPriceUnset` or `BondTooSmall` first.

#### Scenario: Filing against an executed proposal inside the window
- **WHEN** a caller files against a proposal with non-zero `executedAt`, within the window, with a valid bond
- **THEN** a new challenge is created in status `Filed` with `filedAt = block.timestamp`, the bond is pulled via `safeTransferFrom`, and `ChallengeFiled` is emitted with the challenger, predicate, bond, and evidence URI

#### Scenario: Unexecuted proposal refused
- **WHEN** `file` is called for a proposal whose `executedAt` is zero
- **THEN** the call reverts `NotExecuted`

#### Scenario: The window counts from the end of the strategy duration
- **WHEN** a proposal executed with a 7-day `strategyDuration` and a 14-day `challengeWindow` is challenged 20 days after `executedAt`
- **THEN** the filing is inside the window and is accepted

#### Scenario: Window closed
- **WHEN** `block.timestamp` exceeds both `executedAt + strategyDuration + challengeWindow` and the proposal's `challengeableUntil` extension
- **THEN** the call reverts `WindowClosed`

### Requirement: Slash gas floor
Because `resolve` is permissionless, `_settle` SHALL revert `InsufficientSlashGas` when `gasleft() < approvers.length * SLASH_GAS_PER_APPROVER + SLASH_GAS_BASE`, with `SLASH_GAS_PER_APPROVER = 180_000` and `SLASH_GAS_BASE = 2_000_000` — measured end to end through `resolve`, not against the slash call alone. When the challenge names a non-zero adapter, the floor SHALL additionally require `DEMOTION_GAS = 200_000`: the check becomes `gasleft() >= approvers.length * SLASH_GAS_PER_APPROVER + SLASH_GAS_BASE + DEMOTION_GAS`, so a settle that passes it is GUARANTEED to reach the best-effort `demoteByChallenge` child with enough gas for the demotion to succeed on a willing registry — a caller cannot choose a gas budget on which the conviction lands but the demotion is starved. A filing that accuses no adapter (zero `adapterTarget`) demotes nothing and SHALL owe nothing for it: its floor is the slash terms alone. Without the term, the demotion's gas safety rested on two incidental facts — the slash constants' measured slack reaching the demotion call, and an out-of-gas demotion child consuming its whole 63/64 stipend so the 1/64 remainder could not pay for the settle's own tail (the whole call reverted rather than settling with a silent miss). Both held at the time this term was added, but neither was stated or tested; the explicit term is what survives retuning the slash constants, slimming the settle tail, or reordering the demotion. The full-cap floor including `DEMOTION_GAS` SHALL fit Robinhood's 32M per-transaction limit after the one 63/64 haircut that applies when an EOA calls `resolve` directly (`100 * 180_000 + 2_000_000 + 200_000 = 20,200,000` against `32,000,000 * 63/64 = 31,500,000`; `test_slashGasFloorFitsRobinhoodMaxTxGas` is the tripwire). The code enforces only the floor itself. The check is skipped on the `VerdictAlreadyCollected` branch (nothing is slashed, nothing is demoted) and a failed check changes no challenge state — retry with more gas.

#### Scenario: Under-gassed resolve reverts cleanly
- **WHEN** `resolve` reaches the slash with less than the floor remaining
- **THEN** it reverts `InsufficientSlashGas` and the challenge remains resolvable by a retry with more gas

#### Scenario: A budget that covers the slash but not the demotion is refused up front
- **WHEN** `resolve` reaches `_settle` on an adapter-naming challenge with gas at or above the slash terms but below the demotion-extended floor
- **THEN** it reverts `InsufficientSlashGas` before any state moves — the conviction cannot land on a budget that cannot also afford the demotion

#### Scenario: A settle that clears the extended floor lands the demotion
- **WHEN** an adapter-naming challenge settles with the demoter role intact and gas exactly at the extended floor
- **THEN** the demotion succeeds — no `AdapterDemotionFailed` is emitted and the adapter's certification is revoked

#### Scenario: No-adapter filings pay no demotion term
- **WHEN** a challenge naming the zero adapter settles with gas at or above the slash-only floor
- **THEN** the floor passes and the settle completes, demoting nothing
