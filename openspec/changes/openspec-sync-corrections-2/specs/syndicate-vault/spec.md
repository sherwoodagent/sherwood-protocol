## MODIFIED Requirements

### Requirement: Idle-liquidity buffer
The vault owner SHALL be able to set an idle-liquidity floor `minBufferBps` (basis points, at most 5,000 = 50%, `BufferTooHigh` above; 0 disables), emitting `MinBufferUpdated`. `executeGovernorBatch` SHALL revert `BufferBreached` if the post-batch idle balance is below the queue reserve plus `minBufferBps` of the PRE-batch idle balance — a batch may deploy at most `(1 − minBufferBps) × preBatchBalance − reservedQueueAssets()`. A settlement batch passes the buffer check whenever `minBufferBps` is unchanged since execute; `setMinBufferBps` has no open-proposal lock, so an owner raise mid-proposal can make even a net-inflow settle or `unstick` revert `BufferBreached`. The buffer is a deployment-time constraint only: withdrawals may spend it between batches.

#### Scenario: Batch bounded by the buffer
- **WHEN** `minBufferBps = 1000` and a batch would leave the post-batch balance below the queue reserve plus 10% of the pre-batch balance
- **THEN** the batch reverts `BufferBreached`

#### Scenario: Setter bound
- **WHEN** the owner calls `setMinBufferBps` with a value above 5,000
- **THEN** the call reverts `BufferTooHigh`
