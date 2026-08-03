# Syndicate Vault Specification

## Purpose
Define the observable behavior of the SyndicateVault: an ERC-4626, ERC20Votes-checkpointed, UUPS-upgradeable vault that custodies a syndicate's assets, prices shares against vault-side live NAV (Lane A), routes mid-proposal LP flow through a per-vault async request queue (Lane B), enforces an instant-withdrawal liquidity buffer and queue-reserve seniority against governor strategy batches, and confines all privileged surfaces to owner, factory, governor, and queue roles.

## Requirements

### Requirement: ERC-4626 share accounting and NAV
The vault SHALL be an ERC-4626 vault over a single underlying asset fixed at initialization. `totalAssets()` SHALL equal the vault's idle asset balance plus a live-NAV term that is nonzero only when Lane A is available; the vault SHALL never trust a strategy's self-reported value — live NAV is the active strategy's positions priced vault-side by the protocol PriceRouter. The ERC-4626 virtual-shares decimals offset SHALL equal the asset's `decimals()`, cached once at initialization.

#### Scenario: NAV outside any proposal
- **WHEN** no proposal is active
- **THEN** `totalAssets()` equals the vault's idle balance of the underlying asset (live-NAV term is 0)

#### Scenario: NAV during a proposal with Lane A available
- **WHEN** a proposal is active, the factory's PriceRouter is set, and `valueStrategy(activeStrategy)` returns `(value, ok=true)`
- **THEN** `totalAssets()` equals idle float plus that router-priced value

#### Scenario: NAV fails closed without pricing
- **WHEN** a proposal is active but the PriceRouter is unset, the router call reverts, or it returns `ok=false`
- **THEN** the live-NAV term is 0 and the vault reports float-only NAV (Lane A closed)

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

### Requirement: Lane eligibility rule
The vault SHALL derive instant-lane (Lane A) eligibility from a single rule: Lane A is open only when a proposal is active AND the PriceRouter successfully prices every position of the active strategy (`valueStrategy` returns ok). Any missing precondition — no active proposal-bound strategy, unset router, router revert, or `ok=false` — SHALL fail closed to Lane A unavailable with a zero live-NAV term. An active strategy address with no deployed code SHALL be treated as non-pullable for liquidity purposes.

#### Scenario: Router failure closes Lane A
- **WHEN** the PriceRouter reverts while a proposal is active
- **THEN** Lane A is unavailable, `totalAssets()` is float-only, and instant exits are closed (`maxWithdraw`/`maxRedeem` return 0)

#### Scenario: Codeless strategy cannot brick views
- **WHEN** the active strategy address has no code
- **THEN** `maxWithdraw`/`maxRedeem` still return (with strategy liquidity counted as 0) rather than reverting

### Requirement: Instant deposit flow
`deposit`/`mint` SHALL succeed only when the vault is not paused, and either no proposal is open (governor `openProposalCount() == 0`) or Lane A is available; otherwise they SHALL revert `DepositsLocked` and depositors use the async queue. The whitelist check SHALL run against the `receiver` (the share holder), not the caller, so pay-on-behalf funding is permitted. A Lane A (mid-proposal) deposit SHALL record the active proposal id as the receiver's Lane A lock and SHALL add the deposited assets to the interim net-flow accumulator.

#### Scenario: Deposit outside any open proposal
- **WHEN** no proposal is open and the receiver is eligible (deposits open, or receiver whitelisted)
- **THEN** the deposit mints shares at the current NAV

#### Scenario: Mid-proposal deposit without Lane A
- **WHEN** a proposal is open and Lane A is unavailable
- **THEN** `deposit`/`mint` revert `DepositsLocked`

#### Scenario: Mid-proposal Lane A deposit locks the receiver
- **WHEN** a deposit executes while Lane A is available during an active proposal
- **THEN** the receiver's shares are Lane-A-locked to that proposal id and `interimNetFlow` increases by the deposited assets

#### Scenario: Non-whitelisted receiver in closed mode
- **WHEN** `openDeposits` is false and the receiver is not an approved depositor
- **THEN** the deposit reverts `NotApprovedDepositor`

#### Scenario: maxDeposit reflects pause only
- **WHEN** the vault is paused
- **THEN** `maxDeposit`/`maxMint` return 0; otherwise they return `type(uint256).max` (proposal and whitelist gating is not reflected in these views)

### Requirement: Depositor access control
The vault owner SHALL control deposit access via an open/closed mode flag (`setOpenDeposits`) and an approved-depositor whitelist (`approveDepositor`, `approveDepositors`, `removeDepositor`), all owner-only. Approving the zero address SHALL revert `InvalidDepositor`; re-approving via the single-address path SHALL revert `DepositorAlreadyApproved`; removing an unapproved depositor SHALL revert `DepositorNotApproved`. Whitelist membership SHALL be readable via `isApprovedDepositor` and paginated via `approvedDepositorsPaginated`, with page size hard-clamped to `MAX_PAGE_LIMIT` (100).

#### Scenario: Batch approval is idempotent
- **WHEN** the owner calls `approveDepositors` with an already-approved address
- **THEN** the call does not revert for the duplicate (only zero addresses revert) and emits `DepositorApproved` per entry

#### Scenario: Pagination clamp
- **WHEN** a paginated view is called with `limit > 100`
- **THEN** at most 100 rows are returned

### Requirement: Instant withdrawal flow and capacity
While no proposal is active, instant `withdraw`/`redeem` SHALL be available up to the holder's balance, capped by instant capacity = available float (idle balance minus the queue's reserved assets) plus the active strategy's on-demand liquidity. While a proposal is active, instant exit SHALL be open only when Lane A is available and the holder is not Lane-A-locked; otherwise `maxWithdraw`/`maxRedeem` SHALL return 0 and exits route through the async queue. When a requested exit exceeds idle float (net of the queue reserve), the vault SHALL pull exactly the shortfall from the active strategy in the same transaction via `IStrategy.withdrawTo`, verifying delivery by balance difference and reverting `UnwindShortfall` on under-delivery; with no pullable strategy the exit SHALL revert `QueueReserveBreached`. An instant exit during an active proposal SHALL subtract the withdrawn assets from `interimNetFlow`.

#### Scenario: Exit served fully from float
- **WHEN** a holder withdraws no more than the available float
- **THEN** assets transfer out with no strategy interaction

#### Scenario: Exit spanning float and strategy liquidity
- **WHEN** Lane A is available and a withdrawal exceeds available float but not float plus `availableLiquidity()`
- **THEN** the shortfall is pulled from the strategy in the same transaction and the exit completes at live NAV

#### Scenario: Under-delivering strategy reverts the exit
- **WHEN** the strategy's `withdrawTo` returns fewer assets than the requested shortfall
- **THEN** the withdrawal reverts `UnwindShortfall`

#### Scenario: Locked without pricing means queue-only
- **WHEN** a proposal is active and Lane A is unavailable
- **THEN** `maxWithdraw` and `maxRedeem` return 0 for every holder except the bound withdrawal queue

#### Scenario: Queue bypasses caps it owns
- **WHEN** the bound withdrawal queue is the caller/owner of a withdrawal
- **THEN** the reserve cap and lane gates do not apply (the reserved float belongs to the queue)

#### Scenario: maxRedeem excludes queued shares
- **WHEN** shares are escrowed in the queue (`pendingQueueShares`)
- **THEN** `maxRedeem` treats them as unavailable supply, and redeemable shares are further capped by shares convertible from instant capacity when the holder's balance exceeds it

#### Scenario: Views return zero when paused
- **WHEN** the vault is paused
- **THEN** `maxWithdraw` and `maxRedeem` return 0

### Requirement: Lane A per-holder lock (anti intra-proposal MEV)
Shares acquired via a Lane A deposit during an active proposal SHALL be locked to that proposal id for the receiving holder: while that proposal remains active, the holder SHALL NOT transfer shares (`SharesLocked` on transfer), SHALL NOT instant-exit (`maxWithdraw`/`maxRedeem` return 0 for the holder), and SHALL NOT queue an exit (`requestRedeem` reverts `SharesLocked`). The lock SHALL lift implicitly when the active proposal id changes or clears. Mints and burns are unaffected by the transfer restriction.

#### Scenario: Locked holder cannot hop wallets
- **WHEN** a Lane-A-locked holder attempts an ERC-20 share transfer during the locking proposal
- **THEN** the transfer reverts `SharesLocked`

#### Scenario: Lock lifts at settlement
- **WHEN** the locking proposal settles and is no longer active
- **THEN** the holder may transfer, instant-exit, and request redemptions again with no explicit clearing transaction

### Requirement: Async redemption requests (Lane B)
`requestRedeem(shares, owner)` SHALL be callable only while `redemptionsLocked()` is true, the vault is not paused, and a withdrawal queue is bound; zero shares SHALL revert `InsufficientShares`, an unset queue `WithdrawalQueueNotSet`, and an unlocked vault `RedemptionsNotLocked`. A caller other than the share owner SHALL spend ERC-20 allowance. The shares SHALL be transferred (not burned) into queue custody, tagged with the active proposal id, and a request id strictly greater than 0 SHALL be returned with `RedeemRequested` emitted. Lane-A-locked owners SHALL be rejected with `SharesLocked`.

#### Scenario: Queued exit escrows shares
- **WHEN** a holder requests a redemption mid-proposal
- **THEN** their shares move into queue custody (retaining checkpointed voting weight at the queue), and burning is deferred to claim time

#### Scenario: Request outside the lock window
- **WHEN** no proposal is active
- **THEN** `requestRedeem` reverts `RedemptionsNotLocked` (instant exit is the correct path)

### Requirement: Async deposit requests (Lane B)
`requestDeposit(assets, receiver)` SHALL be callable only while `redemptionsLocked()` is true, the vault is not paused, and a queue is bound; zero assets SHALL revert `ZeroAssets`, and the receiver SHALL pass the same whitelist rule as instant deposits. Assets SHALL be escrowed in the queue's own balance — never counted in `totalAssets()` and never sweepable into a strategy — tagged with the active proposal id, and a request id strictly greater than 0 SHALL be returned with `DepositRequested` emitted.

#### Scenario: Escrowed deposit does not inflate NAV
- **WHEN** assets are escrowed via `requestDeposit` during a proposal
- **THEN** `totalAssets()` is unchanged until the request is claimed and assets are pushed into the vault

### Requirement: Settlement price stamping
When the governor notifies settlement via `onProposalSettled(pid)` (governor-only), the vault SHALL first reset `interimNetFlow` to 0 (even when no queue is bound), then stamp one frozen settle price into the queue: `num = totalAssets() + 1`, `den = totalSupply() + 10^decimalsOffset`, reproducing ERC-4626 conversion rounding exactly. The queue SHALL accept at most one stamp per proposal id (`AlreadySettled` on re-stamp) and SHALL, at stamp time, reserve `mulDiv(queuedRedeemShares(pid), num, den)` assets for that proposal's queued redemptions, adding it to the aggregate `reservedAssets`.

#### Scenario: One frozen price per proposal
- **WHEN** a proposal settles with queued requests tagged to it
- **THEN** every request tagged to that proposal claims against a single stamped `num/den`, and a second stamp for the same pid reverts

#### Scenario: Reserve created at stamp
- **WHEN** a proposal with queued redeem shares is stamped
- **THEN** `reservedAssets` increases by the aggregate asset value of those shares at the stamped price

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
When the calling governor exposes a nonzero TierRegistry, every batch call carrying one of the four value-moving ERC-20 selectors — `approve`, `increaseAllowance`, `transfer`, `transferFrom` — SHALL have its spender/recipient (arg 1 for the first three; the `to` arg for `transferFrom`) be either the vault itself or an adapter allowlisted in the TierRegistry; otherwise the batch SHALL revert `DisallowedTransferTarget`. Guarded-selector calldata too short to hold the guarded argument SHALL revert `MalformedCall`. The guard SHALL run on every governor batch (execute, settlement, and emergency paths). When the governor has no tier registry wired (getter missing or returning zero), the guard SHALL be skipped by design.

#### Scenario: Balance-invisible exfiltration blocked
- **WHEN** a batch call is `token.approve(attacker, max)` and `attacker` is not the vault or an allowlisted adapter
- **THEN** the batch reverts `DisallowedTransferTarget` even though the call itself moves no balance

#### Scenario: Pull into the vault always passes
- **WHEN** a batch call is `transferFrom(x, vault, amount)`
- **THEN** the guard passes it as an inflow

#### Scenario: Registry-less governor degrades open
- **WHEN** the governor's tier registry is unset
- **THEN** the selector guard does not run and the batch proceeds under the outflow/reserve/buffer checks only

### Requirement: Interim net-flow accounting
The vault SHALL accumulate a signed `interimNetFlow` — Lane A mid-proposal deposits add assets, mid-proposal instant exits subtract assets — readable by the governor at settlement so mid-proposal LP flows neither corrupt strategy PnL nor incur performance fees on depositor principal. Queue settlements SHALL NOT be counted (they post-date the PnL read). The accumulator SHALL reset to 0 in `onProposalSettled` before any queue interaction, including on queueless vaults.

#### Scenario: Principal excluded from PnL
- **WHEN** an LP deposits via Lane A mid-proposal and the proposal later settles
- **THEN** the deposited principal is reflected in `interimNetFlow` and excluded from settlement PnL / performance-fee computation

### Requirement: Fee parameters
The vault SHALL expose an initialization-time `managementFeeBps` and an owner-settable agent performance fee `agentFeeBps`. The agent fee SHALL default to 5% (500 bps) until explicitly set, SHALL distinguish an explicit 0% from unset, SHALL be capped at `MAX_AGENT_FEE_BPS` (15%, the protocol performance-fee ceiling; `AgentFeeTooHigh` above), and SHALL emit `AgentFeeUpdated` on change. The fee is snapshotted onto a proposal at propose time and clamped to the governor's configured maximum at settlement. `transferPerformanceFee(asset, to, amount)` SHALL be governor-only, restricted to the vault's own underlying asset (`InvalidAsset` otherwise), to a nonzero recipient, and to at most the vault's balance (`AmountExceedsBalance`).

#### Scenario: Default agent fee
- **WHEN** the owner has never called `setAgentFeeBps`
- **THEN** `agentFeeBps()` returns 500

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
