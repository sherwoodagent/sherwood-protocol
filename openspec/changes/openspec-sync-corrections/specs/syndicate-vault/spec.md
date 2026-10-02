## MODIFIED Requirements

### Requirement: Instant deposit flow

`deposit`/`mint` SHALL succeed only when the vault is not paused and no proposal is
open (governor `openProposalCount() == 0`); while any proposal is open they SHALL
revert `DepositsLocked` and depositors use the async queue (`requestDeposit`). The
whitelist check SHALL run against the `receiver` (the share holder), not the caller,
so pay-on-behalf funding is permitted.

#### Scenario: Deposit outside any open proposal

- **WHEN** no proposal is open and the receiver is eligible (deposits open, or
  receiver whitelisted)
- **THEN** the deposit mints shares at the current NAV

#### Scenario: Mid-proposal deposit is locked

- **WHEN** any proposal is open (Draft through Executed)
- **THEN** `deposit`/`mint` revert `DepositsLocked` and the depositor's path is
  `requestDeposit`

#### Scenario: Non-whitelisted receiver in closed mode

- **WHEN** `openDeposits` is false and the receiver is not an approved depositor
- **THEN** the deposit reverts `NotApprovedDepositor`

#### Scenario: maxDeposit reflects every deposit gate

- **WHEN** the vault is paused, `depositsLocked()` is true, or the receiver is
  not an approved depositor in closed mode (including closed by the factory's
  `depositsRestricted`)
- **THEN** `maxDeposit(receiver)`/`maxMint(receiver)` return 0; otherwise they
  return `type(uint256).max`

### Requirement: Async deposit requests (Lane B)
`requestDeposit(assets, receiver)` SHALL be callable only while the vault is not paused, a queue is bound (`WithdrawalQueueNotSet`), and the governor reports an open proposal (`openProposalCount() != 0`, else `NoOpenProposal`) — the predicate instant deposit closes on, so exactly one deposit path is open at a time; zero assets SHALL revert `ZeroAssets`, and the receiver SHALL pass the same whitelist rule as instant deposits. Assets SHALL be escrowed in the queue's own balance — never counted in `totalAssets()` and never sweepable into a strategy — tagged with the executing proposal's id, or while none is executing with the latest proposal id, and a request id strictly greater than 0 SHALL be returned with `DepositRequested` emitted.

#### Scenario: Escrowed deposit does not inflate NAV
- **WHEN** assets are escrowed via `requestDeposit` during a proposal
- **THEN** `totalAssets()` is unchanged until the request is claimed and assets are pushed into the vault

### Requirement: ERC-4626 share accounting and NAV

The vault SHALL be an ERC-4626 vault over a single underlying asset fixed at
initialization. `totalAssets()` SHALL equal the vault's idle balance of the
underlying asset minus the queue's reserved (stamped-but-unclaimed) redemption
assets and minus the governor's escrowed fee liability for the vault
(`outstandingEscrow`), floored at zero. Share conversions SHALL divide by the pricing
supply: `totalSupply()` minus the queue's stamped-but-unclaimed redemption shares. The
vault SHALL NOT consult any strategy or external pricing source for NAV: strategy
value is recognized only when a settlement returns assets to the vault's idle
balance. The ERC-4626 virtual-shares decimals offset SHALL equal the asset's
`decimals()`, cached once at initialization.

#### Scenario: NAV outside any proposal

- **WHEN** no proposal is active
- **THEN** `totalAssets()` equals the vault's idle balance of the underlying asset
  minus `reservedQueueAssets()` and any escrowed fee liability

#### Scenario: NAV during a proposal is float-only

- **WHEN** a proposal is active with capital deployed into a strategy
- **THEN** `totalAssets()` reflects only the idle balance (net of the queue reserve
  and escrowed fees); no live valuation of the deployed position is added

#### Scenario: Reserve exceeding float floors at zero

- **WHEN** the queue reserve plus the escrowed fee liability exceeds the vault's idle balance
- **THEN** `totalAssets()` returns 0 rather than reverting

#### Scenario: Inflation-attack mitigation

- **WHEN** the vault is initialized over a 6-decimal asset such as USDC
- **THEN** the virtual-shares offset is 6, yielding 12-decimal shares

### Requirement: Idle-liquidity buffer
The vault owner SHALL be able to set an idle-liquidity floor `minBufferBps` (basis points, at most 5,000 = 50%, `BufferTooHigh` above; 0 disables), emitting `MinBufferUpdated`. `executeGovernorBatch` SHALL revert `BufferBreached` if the post-batch idle balance is below the queue reserve plus `minBufferBps` of the PRE-batch idle balance — a batch may deploy at most `(1 − minBufferBps) × preBatchBalance − reservedQueueAssets()`. Net-inflow (settlement) batches pass trivially. The buffer is a deployment-time constraint only: withdrawals may spend it between batches.

#### Scenario: Batch bounded by the buffer
- **WHEN** `minBufferBps = 1000` and a batch would leave the post-batch balance below the queue reserve plus 10% of the pre-batch balance
- **THEN** the batch reverts `BufferBreached`

#### Scenario: Setter bound
- **WHEN** the owner calls `setMinBufferBps` with a value above 5,000
- **THEN** the call reverts `BufferTooHigh`

### Requirement: Fee parameters
The vault SHALL expose an initialization-time `managementFeeBps` and an owner-settable agent performance fee `agentFeeBps`. The agent fee SHALL default to `FeeConstants.DEFAULT_AGENT_FEE_BPS` (2000 bps, 20%) until explicitly set, SHALL distinguish an explicit 0% from unset, SHALL be capped at `MAX_AGENT_FEE_BPS` (2500 bps, 25% — an alias of the protocol performance-fee ceiling `FeeConstants.MAX_PERFORMANCE_FEE_BPS`; `AgentFeeTooHigh` above), and SHALL emit `AgentFeeUpdated` on change. The fee is clamped to the governor's configured maximum and snapshotted onto a proposal at propose time, and re-clamped to the maximum then in force at settlement. `transferPerformanceFee(asset, to, amount)` SHALL be governor-only, restricted to the vault's own underlying asset (`InvalidAsset` otherwise), to a nonzero recipient (`ZeroAddress`), and to at most the balance net of the queue reserve and the escrowed fee liability (`AmountExceedsBalance`).

#### Scenario: Default agent fee
- **WHEN** the owner has never called `setAgentFeeBps`
- **THEN** `agentFeeBps()` returns 2000

#### Scenario: Explicit zero survives
- **WHEN** the owner sets the agent fee to 0
- **THEN** `agentFeeBps()` returns 0, not the 20% default

### Requirement: Queue authorization boundaries
The queue SHALL accept `queueRedeem`, `queueDeposit`, and `stampSettlement` only from its immutable bound vault (`NotVault` otherwise); the vault SHALL accept `settleRedeem` and `settleDeposit` only from its bound queue (`NotQueue`) and `onProposalSettled` only from its governor. Request ids SHALL start at 1 (index 0 is a sentinel; `claim` and `cancel` on id 0 or an out-of-range id revert `RequestNotFound`). The queue SHALL expose `pendingShares`, `pendingDepositAssets`, `reservedAssets`, per-owner request ids, per-request state (owner, amount, pid, kind, claimed/cancelled, custody interval `queuedAt`/`closedAt`), and stamped settle prices.

#### Scenario: Third party cannot mint via queue surface
- **WHEN** any address other than the bound queue calls `settleDeposit` or `settleRedeem` on the vault
- **THEN** the call reverts `NotQueue`

### Requirement: Deposits are not charged a fee

The vault SHALL charge nothing on entry.

#### Scenario: A deposit incurs no fee

- **WHEN** a depositor deposits into the vault
- **THEN** the shares issued reflect the full deposited amount, less no fee
