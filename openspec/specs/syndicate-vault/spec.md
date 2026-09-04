# Syndicate Vault Specification

## Purpose
Define the observable behavior of the SyndicateVault: an ERC-4626, ERC20Votes-checkpointed, UUPS-upgradeable vault that custodies a syndicate's assets, prices shares against float-only NAV, routes all mid-proposal LP flow through a per-vault async request queue (Lane B, the only mid-proposal path), enforces an instant-withdrawal liquidity buffer and queue-reserve seniority against governor strategy batches, and confines all privileged surfaces to owner, factory, governor, and queue roles. Instant entry and exit exist only outside a proposal; Lane A (mid-proposal instant flow at router-priced live NAV) was retired from v1 with issue #54.
## Requirements
### Requirement: ERC-4626 share accounting and NAV

The vault SHALL be an ERC-4626 vault over a single underlying asset fixed at
initialization. `totalAssets()` SHALL equal the vault's idle balance of the
underlying asset minus the queue's reserved (stamped-but-unclaimed) redemption
assets, floored at zero. The vault SHALL NOT consult any strategy or external
pricing source for NAV: strategy value is recognized only when a settlement returns
assets to the vault's idle balance. The ERC-4626 virtual-shares decimals offset
SHALL equal the asset's `decimals()`, cached once at initialization.

#### Scenario: NAV outside any proposal

- **WHEN** no proposal is active
- **THEN** `totalAssets()` equals the vault's idle balance of the underlying asset
  minus `reservedQueueAssets()`

#### Scenario: NAV during a proposal is float-only

- **WHEN** a proposal is active with capital deployed into a strategy
- **THEN** `totalAssets()` reflects only the idle balance (net of the queue reserve);
  no live valuation of the deployed position is added

#### Scenario: Reserve exceeding float floors at zero

- **WHEN** the queue reserve exceeds the vault's idle balance
- **THEN** `totalAssets()` returns 0 rather than reverting

#### Scenario: Inflation-attack mitigation

- **WHEN** the vault is initialized over a 6-decimal asset such as USDC
- **THEN** the virtual-shares offset is 6, yielding 12-decimal shares

### Requirement: Vote checkpointing and auto-delegation
The vault share token SHALL implement ERC20Votes with a timestamp-based clock (`clock()` returns `block.timestamp`; `CLOCK_MODE()` is `mode=timestamp`). On every share receipt (mint or transfer, including zero-value transfers), the vault SHALL auto-delegate an undelegated recipient to itself, after balances update, so checkpointed voting power tracks balance for every holder that has not explicitly delegated elsewhere.

#### Scenario: Recipient auto-delegates on receipt
- **WHEN** shares are transferred or minted to an address whose delegate is unset
- **THEN** the recipient is delegated to itself and its post-receipt balance is checkpointed

#### Scenario: Permissionless heal via zero-value transfer
- **WHEN** anyone transfers 0 shares to an undelegated legacy holder
- **THEN** that holder becomes self-delegated and checkpointed from that moment

#### Scenario: Explicit delegation preserved
- **WHEN** shares arrive at a holder that has already delegated to another address
- **THEN** the existing delegation choice is unchanged

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

- **WHEN** any proposal is open (Pending through Executed)
- **THEN** `deposit`/`mint` revert `DepositsLocked` and the depositor's path is
  `requestDeposit`

#### Scenario: Non-whitelisted receiver in closed mode

- **WHEN** `openDeposits` is false and the receiver is not an approved depositor
- **THEN** the deposit reverts `NotApprovedDepositor`

#### Scenario: maxDeposit reflects pause only

- **WHEN** the vault is paused
- **THEN** `maxDeposit`/`maxMint` return 0; otherwise they return
  `type(uint256).max` (proposal and whitelist gating is not reflected in these views)

### Requirement: Depositor access control
The vault owner SHALL control deposit access via an open/closed mode flag (`setOpenDeposits`) and an approved-depositor whitelist (`approveDepositor`, `approveDepositors`, `removeDepositor`), all owner-only. Approving the zero address SHALL revert `InvalidDepositor`; re-approving via the single-address path SHALL revert `DepositorAlreadyApproved`; removing an unapproved depositor SHALL revert `DepositorNotApproved`. Whitelist membership SHALL be readable via `isApprovedDepositor` and paginated via `approvedDepositorsPaginated`, with page size hard-clamped to `MAX_PAGE_LIMIT` (100).

#### Scenario: Batch approval is idempotent
- **WHEN** the owner calls `approveDepositors` with an already-approved address
- **THEN** the call does not revert for the duplicate (only zero addresses revert) and emits `DepositorApproved` per entry

#### Scenario: Pagination clamp
- **WHEN** a paginated view is called with `limit > 100`
- **THEN** at most 100 rows are returned

### Requirement: Instant withdrawal flow and capacity

While no proposal is active, instant `withdraw`/`redeem` SHALL be available up to the
holder's balance, capped by instant capacity = available float (idle balance minus
the queue's reserved assets). While a proposal is active, `maxWithdraw`/`maxRedeem`
SHALL return 0 for every holder except the bound withdrawal queue, and exits route
through the async queue — mid-proposal exits route to the queue, full stop. A
requested exit whose assets plus the queue reserve exceed the idle balance SHALL
revert `QueueReserveBreached`; the vault SHALL NOT pull capital from a strategy to
serve an exit.

#### Scenario: Exit served from float

- **WHEN** no proposal is active and a holder withdraws no more than the available
  float
- **THEN** assets transfer out with no strategy interaction

#### Scenario: Exit beyond available float reverts

- **WHEN** a withdrawal's assets plus the queue reserve exceed the vault's idle
  balance
- **THEN** the withdrawal reverts `QueueReserveBreached`

#### Scenario: Active proposal means queue-only

- **WHEN** a proposal is active
- **THEN** `maxWithdraw` and `maxRedeem` return 0 for every holder except the bound
  withdrawal queue

#### Scenario: Queue bypasses caps it owns

- **WHEN** the bound withdrawal queue is the caller/owner of a withdrawal
- **THEN** the reserve cap and the active-proposal gate do not apply (the reserved
  float belongs to the queue)

#### Scenario: maxRedeem excludes queued shares

- **WHEN** shares are escrowed in the queue (`pendingQueueShares`)
- **THEN** `maxRedeem` treats them as unavailable supply, and redeemable shares are
  further capped by shares convertible from instant capacity when the holder's
  balance exceeds it

#### Scenario: Views return zero when paused

- **WHEN** the vault is paused
- **THEN** `maxWithdraw` and `maxRedeem` return 0

#### Scenario: Missing governor fails closed in exit views

- **WHEN** the factory resolves a zero governor for the vault
- **THEN** `maxWithdraw`/`maxRedeem` revert `GovernorNotSet` (via
  `redemptionsLocked()`) rather than reporting instant capacity

### Requirement: Async redemption requests (Lane B)

`requestRedeem(shares, owner)` SHALL be callable only while `redemptionsLocked()` is
true, the vault is not paused, and a withdrawal queue is bound; zero shares SHALL
revert `InsufficientShares`, an unset queue `WithdrawalQueueNotSet`, and an unlocked
vault `RedemptionsNotLocked`. A caller other than the share owner SHALL spend ERC-20
allowance. The shares SHALL be transferred (not burned) into queue custody, tagged
with the active proposal id, and a request id strictly greater than 0 SHALL be
returned with `RedeemRequested` emitted.

#### Scenario: Queued exit escrows shares

- **WHEN** a holder requests a redemption mid-proposal
- **THEN** their shares move into queue custody (retaining checkpointed voting weight
  at the queue), and burning is deferred to claim time

#### Scenario: Request outside the lock window

- **WHEN** no proposal is active
- **THEN** `requestRedeem` reverts `RedemptionsNotLocked` (instant exit is the
  correct path)

### Requirement: Async deposit requests (Lane B)
`requestDeposit(assets, receiver)` SHALL be callable only while `redemptionsLocked()` is true, the vault is not paused, and a queue is bound; zero assets SHALL revert `ZeroAssets`, and the receiver SHALL pass the same whitelist rule as instant deposits. Assets SHALL be escrowed in the queue's own balance — never counted in `totalAssets()` and never sweepable into a strategy — tagged with the active proposal id, and a request id strictly greater than 0 SHALL be returned with `DepositRequested` emitted.

#### Scenario: Escrowed deposit does not inflate NAV
- **WHEN** assets are escrowed via `requestDeposit` during a proposal
- **THEN** `totalAssets()` is unchanged until the request is claimed and assets are pushed into the vault

### Requirement: Settlement price stamping

When the governor notifies settlement via `onProposalSettled(pid)` (governor-only),
the vault SHALL stamp one frozen settle price into the queue: `num = totalAssets() +
1`, `den = totalSupply() + 10^decimalsOffset`, reproducing ERC-4626 conversion
rounding exactly; on a queueless vault the call SHALL be a no-op. The queue SHALL
accept at most one stamp per proposal id (`AlreadySettled` on re-stamp) and SHALL, at
stamp time, reserve `mulDiv(queuedRedeemShares(pid), num, den)` assets for that
proposal's queued redemptions, adding it to the aggregate `reservedAssets`.

#### Scenario: One frozen price per proposal

- **WHEN** a proposal settles with queued requests tagged to it
- **THEN** every request tagged to that proposal claims against a single stamped
  `num/den`, and a second stamp for the same pid reverts

#### Scenario: Reserve created at stamp

- **WHEN** a proposal with queued redeem shares is stamped
- **THEN** `reservedAssets` increases by the aggregate asset value of those shares at
  the stamped price

### Requirement: Claiming settled requests
`claim(requestId)` SHALL be permissionless, SHALL require the request's proposal to be stamped (`NotSettled` otherwise) and the vault to be unlocked (`VaultLocked` while a proposal is active), and SHALL reject already-claimed (`AlreadyClaimed`) or cancelled (`AlreadyCancelled`) requests. A redeem claim SHALL pay `mulDiv(shares, num, den)` at the request's own proposal's stamped price via the vault's queue-only `settleRedeem` (burn escrowed shares, transfer assets to the request owner). A deposit claim SHALL mint `mulDiv(assets, den, num)` shares priced at the LATEST stamped settlement (not the request's own pid), pushing the escrowed assets into the vault immediately before the queue-only `settleDeposit` mint — pricing at the request's own pid would grant depositors a free look-back option across later settlements.

#### Scenario: Redeem claim at frozen price
- **WHEN** a settled redeem request is claimed
- **THEN** the escrowed shares are burned, the owner receives assets at the request's own stamped price, and `RequestClaimed` is emitted

#### Scenario: Deposit claim priced at latest stamp
- **WHEN** a deposit request tagged to proposal N is claimed after proposal N+1 has also stamped
- **THEN** shares are minted at proposal N+1's (latest) stamped price

#### Scenario: No claims mid-proposal
- **WHEN** a later proposal is active at claim time
- **THEN** `claim` reverts `VaultLocked`

### Requirement: Reserve release and remainder path
Each redeem claim SHALL release reserve: partial claims release exactly their floored payout, and the claim that empties a proposal's remaining queued shares SHALL release that proposal's entire remaining reservation — including the `floor(Σ) − Σfloor` rounding remainder — so aggregate `reservedAssets` never accumulates phantom dust that would over-restrict withdrawals or brick governor batches.

#### Scenario: Final claim frees the remainder
- **WHEN** the last unclaimed redeem request of a proposal is claimed
- **THEN** the proposal's per-pid reservation drops to 0 and `reservedAssets` decreases by the full remaining reservation, not merely the final payout

### Requirement: Request cancellation
`cancel(requestId)` SHALL be callable only by the request owner and only before the request's proposal is stamped; after stamping it SHALL revert `AlreadySettled` (a post-settle cancel would be a free look-back option). Cancellation SHALL return the escrowed shares (redeem) or assets (deposit) to the owner, mark the request cancelled, and emit `RequestCancelled`. Cancellation SHALL remain available while the vault is paused.

#### Scenario: Pre-stamp cancel returns escrow
- **WHEN** an owner cancels an unstamped redeem request
- **THEN** the escrowed shares transfer back and pending counters decrease

#### Scenario: Post-stamp cancel is forbidden
- **WHEN** the request's proposal has been stamped
- **THEN** `cancel` reverts `AlreadySettled` and the request must be claimed

#### Scenario: Paused vault does not trap queued LPs
- **WHEN** the vault is paused with unstamped requests outstanding
- **THEN** owners can still `cancel` and recover their escrow

### Requirement: Queue-reserve seniority
Assets reserved for stamped-but-unclaimed redemptions (`reservedQueueAssets`) SHALL be senior to all other outflows: instant exits SHALL only draw from float in excess of the reserve, and a governor batch SHALL revert `QueueReserveBreached` if it would leave the vault's idle balance below the reserve.

#### Scenario: Strategy execution cannot strand settled claims
- **WHEN** a governor batch would leave idle balance below `reservedQueueAssets`
- **THEN** `executeGovernorBatch` reverts `QueueReserveBreached`

### Requirement: Idle-liquidity buffer
The vault owner SHALL be able to set an idle-liquidity floor `minBufferBps` (basis points, at most 5,000 = 50%, `BufferTooHigh` above; 0 disables), emitting `MinBufferUpdated`. `executeGovernorBatch` SHALL revert `BufferBreached` if the post-batch idle balance is below the queue reserve plus `minBufferBps` of the PRE-batch idle balance — a batch may deploy at most `(1 − minBufferBps)` of the pre-batch float. Net-inflow (settlement) batches pass trivially. The buffer is a deployment-time constraint only: withdrawals may spend it between batches.

#### Scenario: Batch bounded by the buffer
- **WHEN** `minBufferBps = 1000` and a batch attempts to deploy more than 90% of the pre-batch float (net of reserve)
- **THEN** the batch reverts `BufferBreached`

#### Scenario: Setter bound
- **WHEN** the owner calls `setMinBufferBps` with a value above 5,000
- **THEN** the call reverts `BufferTooHigh`

### Requirement: Governor batch execution
`executeGovernorBatch(calls, maxNetOutflow)` SHALL be callable only by the governor resolved live from the factory, only while unpaused, and non-reentrantly. Before executing, the vault SHALL verify the shared executor library's bytecode still matches the codehash stamped at initialization (`ExecutorCodehashMismatch` on drift), then delegatecall the batch, bubbling any failure's revert data. After success it SHALL emit `GovernorBatchExecuted(governor, callCount)` and enforce, in order: net asset outflow of the batch not exceeding `maxNetOutflow` (`MaxNetOutflowExceeded`), idle balance not below the queue reserve (`QueueReserveBreached`), and the idle-liquidity buffer (`BufferBreached`).

#### Scenario: Non-governor caller rejected
- **WHEN** any address other than the factory-resolved governor calls `executeGovernorBatch`
- **THEN** the call reverts `NotGovernor`

#### Scenario: Swapped executor bytecode rejected
- **WHEN** the code at the executor implementation address no longer matches the initialization-time codehash
- **THEN** the batch reverts `ExecutorCodehashMismatch` before any call executes

#### Scenario: Net-outflow ceiling
- **WHEN** a batch moves more of the vault asset out of custody than `maxNetOutflow`
- **THEN** the batch reverts `MaxNetOutflowExceeded(netOutflow, cap)`

### Requirement: Value-moving selector guard on batches

When the calling governor exposes a nonzero TierRegistry, every batch call carrying one of the guarded value-moving selectors — legacy `approve`, `increaseAllowance`, `transfer`, `transferFrom`, plus Permit2 `AllowanceTransfer.approve(address,address,uint160,uint48)` (`0x87517c45`), Permit2 `AllowanceTransfer.transferFrom` (`0x36c78516`), and DSToken `move` (`0xbb35783b`) — SHALL have its spender/recipient (arg 1, calldata bytes 4..36, for legacy `approve`/`increaseAllowance`/`transfer`; arg 2, calldata bytes 36..68, for legacy `transferFrom`, Permit2 `transferFrom`'s `to`, Permit2 `approve`'s `spender`, and DSToken `move`'s `dst`) be either the vault itself or an adapter allowlisted in the TierRegistry; otherwise the batch SHALL revert `DisallowedTransferTarget`. Guarded-selector calldata too short to hold the guarded argument SHALL revert `MalformedCall`. The guard SHALL run on every governor batch (execute, settlement, and emergency paths). When the governor has no tier registry wired (getter missing or returning zero), this destination guard SHALL be skipped by design; the transferFrom **source** guard is unconditional and is specified separately.

The self-transfer fast-path (destination decodes to the vault itself) SHALL apply **only** when the call's target is `asset()` — the one token whose balance the outer net-outflow meter in `executeGovernorBatch` independently verifies via a balance diff. For every other token the vault holds (e.g. a strategy position), a destination that decodes to the vault SHALL still be routed through the TierRegistry check like any other destination; a non-standard token could otherwise execute arbitrary logic under a vault-to-vault call shape with zero verification anywhere in the pipeline.

#### Scenario: Balance-invisible exfiltration blocked

- **WHEN** a batch call is `token.approve(attacker, max)` and `attacker` is not the vault or an allowlisted adapter
- **THEN** the batch reverts `DisallowedTransferTarget` even though the call itself moves no balance

#### Scenario: Registry-less governor degrades open

- **WHEN** the governor's tier registry is unset
- **THEN** the destination guard does not run and the batch proceeds under the transferFrom source guard, the privileged-target guard, and the outflow/reserve/buffer checks only

#### Scenario: Pull into the vault always passes

- **WHEN** a batch call is `transferFrom(x, vault, amount)`
- **THEN** the destination guard passes it as an inflow — this requirement governs only the destination check; a non-vault `x` is separately rejected by the transferFrom source guard specified above before the batch can succeed

#### Scenario: Permit2 approve to a non-allowlisted spender is rejected

- **WHEN** a governor batch contains `Permit2.approve(token, attacker, amount, expiration)` and `attacker` is not the vault or an allowlisted adapter
- **THEN** the batch reverts `DisallowedTransferTarget(permit2, PERMIT2_APPROVE_SELECTOR, attacker)`, closing the two-transaction poison-then-drain route through Permit2 identically to the legacy `approve` guard

#### Scenario: Self-transfer fast-path does not exempt non-asset() tokens

- **WHEN** a governor batch contains `EvilToken.transferFrom(vault, vault, amount)` where `EvilToken` is not `asset()` and is not allowlisted in the TierRegistry
- **THEN** the batch reverts `DisallowedTransferTarget(EvilToken, TRANSFER_FROM_SELECTOR, vault)` — the destination decoding to the vault no longer skips the registry check for any token other than `asset()`

#### Scenario: Self-transfer fast-path still exempts asset()

- **WHEN** a governor batch contains `asset().transferFrom(vault, vault, amount)` (a self-approve/self-transfer of the vault's own underlying asset)
- **THEN** the destination guard's fast-path exempts it exactly as before, since `asset()` is the token the outer net-outflow meter independently verifies

### Requirement: Fee parameters
The vault SHALL expose an initialization-time `managementFeeBps` and an owner-settable agent performance fee `agentFeeBps`. The agent fee SHALL default to `FeeConstants.DEFAULT_AGENT_FEE_BPS` (2000 bps, 20%) until explicitly set, SHALL distinguish an explicit 0% from unset, SHALL be capped at `MAX_AGENT_FEE_BPS` (2500 bps, 25% — an alias of the protocol performance-fee ceiling `FeeConstants.MAX_PERFORMANCE_FEE_BPS`; `AgentFeeTooHigh` above), and SHALL emit `AgentFeeUpdated` on change. The fee is snapshotted onto a proposal at propose time and clamped to the governor's configured maximum at settlement. `transferPerformanceFee(asset, to, amount)` SHALL be governor-only, restricted to the vault's own underlying asset (`InvalidAsset` otherwise), to a nonzero recipient, and to at most the vault's balance (`AmountExceedsBalance`).

#### Scenario: Default agent fee
- **WHEN** the owner has never called `setAgentFeeBps`
- **THEN** `agentFeeBps()` returns 2000

#### Scenario: Explicit zero survives
- **WHEN** the owner sets the agent fee to 0
- **THEN** `agentFeeBps()` returns 0, not the 5% default

### Requirement: Agent registration and removal
The owner SHALL manage the registered-agent set: `registerAgent(agentId, agentAddress)` SHALL reject the zero address, an already-active agent (`AgentAlreadyRegistered`), and any registration that would exceed `MAX_AGENTS_PER_VAULT` (32; `AgentCapExceeded`). When an ERC-8004 agent registry is configured, the `agentId` NFT SHALL be owned by the agent address or the vault owner at registration time (`NotAgentOwner` otherwise); ownership is checked at registration only — later NFT transfers do not revoke vault privileges until `removeAgent`. `removeAgent` SHALL fully delete the agent's config (`AgentNotActive` if inactive) so stale entries cannot be reused. Membership SHALL be readable via `isAgent`, `getAgentCount`, and paginated `agentsPaginated`.

#### Scenario: Registration on a registry-less chain
- **WHEN** the vault was initialized with a zero agent registry
- **THEN** `registerAgent` skips the NFT-ownership check

#### Scenario: Agent cap enforced
- **WHEN** 32 agents are registered and a 33rd registration is attempted
- **THEN** the call reverts `AgentCapExceeded` until `removeAgent` frees a slot

### Requirement: Ownership rotation and upgrade control
Direct `transferOwnership` and `renounceOwnership` SHALL always revert (`NotFactory`); the only ownership-change route SHALL be the factory-only `rotateOwnership(newOwner)`, which SHALL reject a zero new owner and SHALL drain the entire agent set (full deletes, `AgentRemoved` per agent) before transferring ownership, so a new owner never inherits a bricked, at-cap agent set. UUPS upgrades SHALL be authorized only for the factory. The withdrawal queue binding SHALL be factory-only and set-once (`WithdrawalQueueAlreadySet` on rebind), emitting `WithdrawalQueueSet`.

#### Scenario: Owner cannot self-rotate
- **WHEN** the current owner calls `transferOwnership` or `renounceOwnership` directly
- **THEN** the call reverts `NotFactory`

#### Scenario: Rotation purges agents
- **WHEN** the factory rotates ownership of a vault with registered agents
- **THEN** every agent entry is deleted before the new owner takes over

### Requirement: Pause and emergency behavior
Owner-only `pause`/`unpause` SHALL freeze LP flow (`deposit`/`mint`/`withdraw`/`redeem`), strategy execution (`executeGovernorBatch`), and new queue requests (`requestRedeem`/`requestDeposit`), while leaving queue `cancel` available. Owner rescue paths — `rescueEth`, `rescueERC20` (never the vault asset; `CannotRescueAsset`), `rescueERC721` — SHALL remain callable while paused but SHALL revert `RedemptionsLocked` whenever a proposal is active, so the owner cannot siphon strategy-transit assets mid-proposal. The vault SHALL have no `receive`/`fallback` (raw ETH sent directly is rejected). `redemptionsLocked()` SHALL fail closed: a zero governor address SHALL revert `GovernorNotSet` rather than reporting unlocked.

#### Scenario: Pause freezes flow and execution
- **WHEN** the owner pauses the vault
- **THEN** deposits, withdrawals, queue requests, and governor batches all revert until unpause

#### Scenario: Rescue blocked mid-proposal
- **WHEN** a proposal is active
- **THEN** all three rescue functions revert `RedemptionsLocked` regardless of pause state

#### Scenario: Missing governor fails closed
- **WHEN** the factory resolves a zero governor for the vault
- **THEN** `redemptionsLocked()` (and everything gated on it) reverts `GovernorNotSet` instead of silently unlocking

### Requirement: Queue authorization boundaries
The queue SHALL accept `queueRedeem`, `queueDeposit`, and `stampSettlement` only from its immutable bound vault (`NotVault` otherwise); the vault SHALL accept `settleRedeem` and `settleDeposit` only from its bound queue (`NotQueue`) and `onProposalSettled` only from its governor. Request ids SHALL start at 1 (index 0 is a sentinel; out-of-range ids revert `RequestNotFound`). The queue SHALL expose `pendingShares`, `pendingDepositAssets`, `reservedAssets`, per-owner request ids, per-request state (owner, amount, pid, kind, claimed/cancelled, custody interval `queuedAt`/`closedAt`), and stamped settle prices.

#### Scenario: Third party cannot mint via queue surface
- **WHEN** any address other than the bound queue calls `settleDeposit` or `settleRedeem` on the vault
- **THEN** the call reverts `NotQueue`

### Requirement: Privileged-target guard on batches

`_guardBatchCalls` SHALL reject any governor batch containing a call whose `target` is the vault itself or the vault's bound withdrawal queue, reverting `DisallowedBatchTarget(target)`. This target check SHALL be enforced **unconditionally on every call in the batch, before the value-moving-selector switch and independently of whether a TierRegistry is wired** — it SHALL NOT be skipped by the `registry == address(0)` degrade-open path that gates the selector guard. Because `_guardBatchCalls` runs inside `executeGovernorBatch`, the guard SHALL apply on the execute, settlement, and both emergency batch paths alike.

The adversary is a governor batch that carries `msg.sender == vault` into a vault-only entrypoint: because batches execute via `delegatecall`, calling the withdrawal queue's `onlyVault` functions (`queueRedeem`, `queueDeposit`, `stampSettlement`) satisfies its `onlyVault` gate while moving zero vault `asset()` balance in the same transaction — so the net-outflow meter, the queue-reserve check, and the tier-2 coverage price all read it as harmless. Blocking the vault and the queue as batch targets is the complete boundary: no legitimate strategy batch targets either address (they target strategy adapters, the asset token, or external protocols).

#### Scenario: Queue-targeting batch call is rejected

- **WHEN** a governor batch contains a call whose `target` is the bound withdrawal queue (e.g. `queueRedeem(attacker, victimShares, pid)`)
- **THEN** `executeGovernorBatch` reverts `DisallowedBatchTarget(withdrawalQueue)` before any call executes, even though the call moves no vault `asset()` balance and would otherwise clear the outflow meter and tier-2 coverage

#### Scenario: Vault self-targeting batch call is rejected

- **WHEN** a governor batch contains a call whose `target` is the vault itself (`address(this)`)
- **THEN** `executeGovernorBatch` reverts `DisallowedBatchTarget(vault)`

#### Scenario: Guard fires even without a wired TierRegistry

- **WHEN** the calling governor exposes no TierRegistry (getter missing or returning `address(0)`) and a batch targets the withdrawal queue
- **THEN** the batch still reverts `DisallowedBatchTarget` — the target guard runs outside the registry-less degrade-open path that skips the selector guard

#### Scenario: Emergency path is covered

- **WHEN** the vault owner drives `emergencySettleWithCalls` / `finalizeEmergencySettle` (or `unstick`) with owner-supplied calls that target the withdrawal queue, bypassing the LP vote and coverage quorum
- **THEN** the batch reverts `DisallowedBatchTarget` because `_guardBatchCalls` runs on every `executeGovernorBatch` invocation regardless of entrypoint

#### Scenario: Honest strategy batch is unaffected

- **WHEN** a governor batch targets only strategy adapters, the vault's underlying asset token, or external protocol contracts (never the vault or its queue)
- **THEN** the target guard passes every call and the batch proceeds under the existing selector, outflow, reserve, and buffer checks

### Requirement: transferFrom source guard on batches

Every governor batch call carrying the `transferFrom(address,address,uint256)` selector, OR one of the alternate-signature "pull tokens via delegated allowance" selectors this guard recognizes — Permit2 `AllowanceTransfer.transferFrom(address,address,uint160,address)` (`0x36c78516`), DSToken `pull(address,uint256)` (`0xf2d5d56b`), and DSToken `move(address,address,uint256)` (`0xbb35783b`) — SHALL have its source address (`from`/`usr`/`src`, calldata bytes 4..36 in every recognized case) equal to the vault itself; otherwise the batch SHALL revert `DisallowedTransferFromSource(target, from)`. Calldata for any of these selectors too short to hold both address arguments (fewer than 68 bytes) SHALL revert `MalformedCall`. Both checks SHALL be enforced **unconditionally on every call in the batch, independently of whether a TierRegistry is wired** — they SHALL NOT be skipped by the degrade-open path that gates the value-moving selector guard. Because the guard runs inside `executeGovernorBatch`, it SHALL apply on the execute, settlement, and both emergency batch paths alike.

A post-merge security review (Pashov 12-agent audit of PR #157, confidence 90, 3-agent independent convergence) found that limiting recognition to the single legacy `transferFrom` selector left the identical "pull via delegated allowance" capability, exposed under a different selector by Permit2 or DSToken, completely unguarded — reproducing the exact confiscation primitive this requirement exists to close, just routed through a different target. The guard is extended selector-by-selector (documented follow-up: a target-based redesign, gating every batch call regardless of selector, was assessed as more durable but was deferred because it would require re-plumbing the tier-pricing/TierRegistry relationship for every non-value-moving adapter call, outside this change's footprint).

The adversary is a governor batch that spends a third party's ERC-20 allowance: batches execute via `delegatecall`, so every sub-call carries `msg.sender == vault`, and `token.transferFrom(victim, vault, victimBalance)` spends `allowance[victim][vault]` — the standing (routinely unlimited) allowance every LP grants in order to deposit. No other meter sees it: the vault's balance rises so net-outflow reads 0, tier coverage prices only vault capital (`maxCapital`) and never third-party wallets, and the privileged-target denylist does not fire because the call target is the token. Confiscation is not a priced capability but a refused one, which is why the check is unconditional — the same posture as the privileged-target guard.

The permitted source is exactly the vault itself, NOT the TierRegistry adapter allowlist. `isAdapterAllowed` encodes destination consent — an address the vault may *send* funds to — and an entry there is no consent to having its own allowances seized. No honest batch pulls from any third party: capital deploys via a guarded `approve` to an adapter that pulls in its own code, and returns are pushes from the adapter.

#### Scenario: LP-allowance confiscation is rejected

- **WHEN** a governor batch contains `token.transferFrom(victim, vault, amount)` where `victim` is any address other than the vault (e.g. an LP holding a `type(uint256).max` deposit allowance to the vault)
- **THEN** `executeGovernorBatch` reverts `DisallowedTransferFromSource(token, victim)`, even though the destination is the vault and the vault's balance would have risen

#### Scenario: Allowlisted adapter is not a permitted source

- **WHEN** a governor batch contains `token.transferFrom(adapter, vault, amount)` where `adapter` is allowlisted in the TierRegistry
- **THEN** the batch reverts `DisallowedTransferFromSource(token, adapter)` — destination consent does not confer source consent

#### Scenario: Guard fires even without a wired TierRegistry

- **WHEN** the calling governor exposes no TierRegistry (getter missing or returning `address(0)`) and a batch contains `transferFrom` with a non-vault source
- **THEN** the batch still reverts `DisallowedTransferFromSource` — the source guard runs outside the registry-less degrade-open path that skips the selector guard

#### Scenario: Vault-sourced transferFrom still flows through the destination guard

- **WHEN** a governor batch contains `token.transferFrom(vault, x, amount)`
- **THEN** the source guard passes it, and `x` remains subject to the value-moving selector guard (vault or allowlisted adapter, else `DisallowedTransferTarget`) and the batch to the net-outflow meter — exactly as if the call were `transfer(x, amount)`

#### Scenario: Short transferFrom calldata is rejected unconditionally

- **WHEN** a governor batch contains a call whose selector is `transferFrom` but whose calldata cannot hold both address arguments (length below 68 bytes), and no TierRegistry is wired
- **THEN** the batch reverts `MalformedCall` — the source guard's calldata bound does not degrade open with the registry

#### Scenario: Permit2-routed confiscation is rejected identically to legacy transferFrom

- **WHEN** a governor batch contains `Permit2.transferFrom(victim, attacker, amount, token)` where `victim` is any address other than the vault and `victim` has a standing Permit2 allowance recorded for `token`
- **THEN** `executeGovernorBatch` reverts `DisallowedTransferFromSource(permit2, victim)`, exactly as it would for the equivalent legacy `token.transferFrom(victim, attacker, amount)` call

#### Scenario: DSToken pull/move from a non-vault source is rejected

- **WHEN** a governor batch contains `DSToken.pull(victim, amount)` or `DSToken.move(victim, attacker, amount)` where `victim` is not the vault
- **THEN** the batch reverts `DisallowedTransferFromSource(dstoken, victim)`


### Requirement: Deposits are not charged a fee

The vault SHALL charge nothing on entry. (Relocated verbatim from the retired
`instant-exit-fees` capability — it was never Lane-A-specific.)

#### Scenario: A deposit incurs no fee

- **WHEN** a depositor deposits into the vault
- **THEN** the shares issued reflect the full deposited amount, less no fee
