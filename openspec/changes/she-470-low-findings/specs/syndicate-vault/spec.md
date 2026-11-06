# syndicate-vault (delta)

## MODIFIED Requirements

### Requirement: Idle-liquidity buffer
The vault owner SHALL be able to set an idle-liquidity floor `minBufferBps` (basis points, at most 5,000 = 50%, `BufferTooHigh` above; 0 disables), emitting `MinBufferUpdated`. When `maxNetOutflow` is non-zero, `executeGovernorBatch` SHALL revert `BufferBreached` if the post-batch idle balance is below the queue reserve plus `minBufferBps` of the pre-batch idle balance net of that reserve (zero when the reserve exceeds it) — a batch may deploy at most `(1 − minBufferBps) × (preBatchBalance − reservedQueueAssets())`. A batch with `maxNetOutflow == 0` (settle, `unstick`, emergency finalize) SHALL skip the buffer check, so an owner raise of `minBufferBps` mid-proposal cannot make a settle revert `BufferBreached`. `setMinBufferBps` has no open-proposal lock. The buffer is a deployment-time constraint only: withdrawals may spend it between batches.

#### Scenario: Batch bounded by the buffer
- **WHEN** `minBufferBps = 1000` and an execute batch would leave the post-batch balance below the queue reserve plus 10% of the pre-batch balance net of the reserve
- **THEN** the batch reverts `BufferBreached`

#### Scenario: The queue reserve is not charged the buffer
- **WHEN** the reserve is 50,000, the deployable float is 50,000, `minBufferBps = 1`, and an execute batch deploys 49,994
- **THEN** the batch executes, because the floor is 50,000 + 5

#### Scenario: An owner raise mid-proposal does not wedge settle
- **WHEN** the owner raises `minBufferBps` to 5,000 after execute and the strategy returns 20% of its capital
- **THEN** `settleProposal` settles

#### Scenario: Setter bound
- **WHEN** the owner calls `setMinBufferBps` with a value above 5,000
- **THEN** the call reverts `BufferTooHigh`

### Requirement: Ownership rotation and upgrade control
Direct `transferOwnership` and `renounceOwnership` SHALL always revert (`NotFactory`); the only ownership-change route SHALL be the factory-only `rotateOwnership(newOwner)`, which SHALL reject a zero new owner and, when `newOwner` differs from the current owner, SHALL drain the entire agent set (full deletes, `AgentRemoved` per agent) before transferring ownership, so a new owner never inherits a bricked, at-cap agent set. A same-owner rotation (the re-bond recovery) SHALL keep the agent set, so the owner stays an agent and a live clone's `onlyProposer` checks keep passing. UUPS upgrades SHALL be authorized only for the factory. The withdrawal queue binding SHALL be factory-only and set-once (`WithdrawalQueueAlreadySet` on rebind), emitting `WithdrawalQueueSet`.

#### Scenario: Owner cannot self-rotate
- **WHEN** the current owner calls `transferOwnership` or `renounceOwnership` directly
- **THEN** the call reverts `NotFactory`

#### Scenario: Rotation purges agents
- **WHEN** the factory rotates ownership of a vault with registered agents to a different owner
- **THEN** every agent entry is deleted before the new owner takes over

#### Scenario: Same-owner re-bond keeps agents
- **WHEN** the factory rotates a vault to its current owner after a blocked emergency round burned the bond
- **THEN** `isAgent(owner)` stays true and the owner's live clone still accepts `updateParams`

## ADDED Requirements

### Requirement: Governor batch legs carry no native value
Every governor-batch call SHALL have `value == 0`. The vault's batch guard SHALL revert `CallValueNotAllowed(index)` on the first leg with non-zero value, on every batch path (execute, settle, `unstick`, emergency finalize), even when the vault holds force-fed ETH. The governor SHALL apply the same rule to both stored legs at propose, so a leg that passes propose cannot revert at settle for carrying value.

#### Scenario: A value leg is refused at propose
- **WHEN** an agent proposes a settlement leg with `value = 1`
- **THEN** `propose` reverts `CallValueNotAllowed(0)`

#### Scenario: Force-fed ETH cannot be spent by a batch
- **WHEN** the vault holds 1 ETH and the governor submits a batch whose leg carries `value = 1 ether`
- **THEN** `executeGovernorBatch` reverts `CallValueNotAllowed(0)` and the vault keeps the ETH
