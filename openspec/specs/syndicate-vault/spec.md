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

The vault share token SHALL implement ERC20Votes with a timestamp-based clock (`clock()` returns `block.timestamp`; `CLOCK_MODE()` is `mode=timestamp`). On every share receipt (mint or transfer, including zero-value transfers), the vault SHALL delegate to itself any recipient that is not already self-delegated, after balances update, so checkpointed voting power tracks balance for every holder. Voting power SHALL NOT be delegated away from the holder: `delegate` and `delegateBySig` SHALL revert `DelegationDisabled` for any delegatee other than the account itself (including `address(0)`), so every share in the veto denominator is castable by its holder and the recorded electorate equals the castable weight at the snapshot.

#### Scenario: Recipient auto-delegates on receipt
- **WHEN** shares are transferred or minted to an address that is not delegated to itself
- **THEN** the recipient is delegated to itself and its post-receipt balance is checkpointed

#### Scenario: Permissionless heal via zero-value transfer
- **WHEN** anyone transfers 0 shares to a holder that is not self-delegated
- **THEN** that holder becomes self-delegated and checkpointed from that moment

#### Scenario: Delegation away from the holder is refused
- **WHEN** a holder calls `delegate` or `delegateBySig` with a delegatee that is not itself (another holder, the queue, or `address(0)`)
- **THEN** the call reverts `DelegationDisabled` and the holder's shares keep voting for the holder

#### Scenario: Self-delegation is a no-op
- **WHEN** a holder calls `delegate(self)`
- **THEN** the call succeeds and `delegates(holder) == holder`

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

#### Scenario: maxDeposit reflects every deposit gate

- **WHEN** the vault is paused, `depositsLocked()` is true, or the receiver is
  not an approved depositor in closed mode (including closed by the factory's
  `depositsRestricted`)
- **THEN** `maxDeposit(receiver)`/`maxMint(receiver)` return 0; otherwise they
  return `type(uint256).max`

### Requirement: Depositor access control
The vault owner SHALL control deposit access via an open/closed mode flag (`setOpenDeposits`) and an approved-depositor whitelist (`approveDepositor`, `approveDepositors`, `removeDepositor`), all owner-only. Approving the zero address SHALL revert `InvalidDepositor`; re-approving via the single-address path SHALL revert `DepositorAlreadyApproved`; removing an unapproved depositor SHALL revert `DepositorNotApproved`. Whitelist membership SHALL be readable via `isApprovedDepositor` and paginated via `approvedDepositorsPaginated`, with page size hard-clamped to `MAX_PAGE_LIMIT` (100). The whitelist rule SHALL apply to the receiver of `deposit`, `mint`, `requestDeposit` and of every queued-deposit claim (`settleDeposit`), read live at each call, so a receiver removed after queueing cannot claim (`NotApprovedDepositor`) and recovers the assets with the queue's `cancel`.

#### Scenario: Batch approval is idempotent
- **WHEN** the owner calls `approveDepositors` with an already-approved address
- **THEN** the call does not revert for the duplicate (only zero addresses revert) and emits `DepositorApproved` per entry

#### Scenario: Pagination clamp
- **WHEN** a paginated view is called with `limit > 100`
- **THEN** at most 100 rows are returned

#### Scenario: Factory-wide deposit restriction
- **WHEN** the factory owner has set `depositsRestricted` via `setDepositsRestricted(true)`
- **THEN** every vault the factory created accepts `deposit`, `mint`, `requestDeposit` and claims of queued deposits only for approved receivers, as in closed mode, whatever its own `openDeposits`
- **AND** withdrawals, redemptions, redeem requests and redeem claims are unaffected, and `setDepositsRestricted(false)` restores each vault's own setting

#### Scenario: Removed receiver cannot claim a queued deposit
- **WHEN** deposits are closed and the owner removes a receiver from the whitelist after it queued a deposit
- **THEN** `claim` of that deposit reverts `NotApprovedDepositor` and the receiver's `cancel` returns the escrowed assets

### Requirement: Instant withdrawal flow and capacity

While no proposal is open, instant `withdraw`/`redeem` SHALL be available up to the
holder's balance, capped by instant capacity = available float (idle balance minus
the queue's reserved assets). From Draft creation until the proposal reaches a
terminal state (settled, cancelled, rejected or expired, as committed on-chain),
`maxWithdraw`/`maxRedeem` SHALL return 0 for every holder except the bound withdrawal
queue, and exits route through the async queue — full stop. The lock starts at Draft
creation, ahead of the vote snapshot and the electorate stamp, so no instant exit can
land on either side of the stamp. Because the exit views cap every holder at the
available float, an over-float `withdraw`/`redeem` SHALL revert in the ERC-4626 max
check (`ERC4626ExceededMaxWithdraw` / `ERC4626ExceededMaxRedeem`); the vault SHALL
NOT pull capital from a strategy to serve an exit.

#### Scenario: Exit served from float

- **WHEN** no proposal is open and a holder withdraws no more than the available
  float
- **THEN** the withdrawal is served instantly from the vault's idle balance

#### Scenario: Exit beyond available float reverts

- **WHEN** a withdrawal's assets exceed the available float (idle balance minus the
  queue reserve)
- **THEN** the withdrawal reverts `ERC4626ExceededMaxWithdraw` (a redeem,
  `ERC4626ExceededMaxRedeem`)

#### Scenario: Active proposal means queue-only

- **WHEN** a proposal is open, Draft included
- **THEN** `maxWithdraw` and `maxRedeem` return 0 for every holder except the bound
  withdrawal queue

#### Scenario: Exit during a collaborative Draft

- **WHEN** a proposal is in Draft and a holder tries an instant redeem
- **THEN** it reverts (`maxRedeem` is 0), and the holder's path is `requestRedeem`

#### Scenario: Queue bypasses caps it owns

- **WHEN** the bound withdrawal queue is the caller/owner of a withdrawal
- **THEN** the reserve cap and the open-proposal gate do not apply (the reserved
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

- **WHEN** the factory resolves a zero governor for an unpaused vault and the owner is
  not the withdrawal queue
- **THEN** `maxWithdraw`/`maxRedeem` revert `GovernorNotSet` (via
  `redemptionsLocked()`) rather than reporting instant capacity

### Requirement: Async redemption requests (Lane B)

`requestRedeem(shares, owner)` SHALL be callable only while the vault is not paused,
a withdrawal queue is bound, and `redemptionsLocked()` is true (any proposal open,
Draft included), checked in that order: a paused vault reverts `EnforcedPause`, an
unset queue `WithdrawalQueueNotSet`, an unlocked vault `RedemptionsNotLocked`, and
zero shares `InsufficientShares`. A caller other than the share owner SHALL spend
ERC-20 allowance. The shares SHALL be transferred (not burned) into queue custody,
tagged with the executing proposal's id, or while none is executing with the latest
proposal id (`proposalCount()`), and a request id strictly greater than 0 SHALL be
returned with `RedeemRequested` emitted. A request is priced only by its proposal's
settle stamp: a request tagged to a proposal that ends without settling is never
stamped, and its only exit is the queue's `cancel`.

#### Scenario: Queued exit escrows shares

- **WHEN** a holder requests a redemption mid-proposal
- **THEN** their shares move into queue custody (retaining checkpointed voting weight
  at the queue), and burning is deferred to claim time

#### Scenario: Request outside the lock window

- **WHEN** no proposal is open
- **THEN** `requestRedeem` reverts `RedemptionsNotLocked` (instant exit is the
  correct path)

#### Scenario: Request tagged to a proposal that never settles

- **WHEN** a holder queues a redemption during a Draft or a vote and that proposal is then cancelled, rejected or expires
- **THEN** the request is never stamped, `claim` keeps reverting, and `cancel` returns the shares

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
`cancel(requestId)` SHALL be callable only by the request owner, before the request is claimed. A redeem request SHALL be cancellable only before its proposal is stamped; after stamping it SHALL revert `AlreadySettled` (a post-settle cancel would be a free look-back option on a fixed payout). A deposit request has no fixed price and SHALL stay cancellable until claimed, so a receiver refused at claim always has a way out. Cancellation SHALL return the escrowed shares (redeem) or assets (deposit) to the owner, mark the request cancelled, and emit `RequestCancelled`. Cancellation SHALL remain available while the vault is paused.

#### Scenario: Pre-stamp cancel returns escrow
- **WHEN** an owner cancels an unstamped redeem request
- **THEN** the escrowed shares transfer back and pending counters decrease

#### Scenario: Post-stamp cancel is forbidden
- **WHEN** a redeem request's proposal has been stamped
- **THEN** `cancel` reverts `AlreadySettled` and the request must be claimed

#### Scenario: Deposit request cancellable after settle
- **WHEN** the owner of an unclaimed deposit request cancels after its proposal settled
- **THEN** the escrowed assets transfer back to the owner

#### Scenario: Paused vault does not trap queued LPs
- **WHEN** the vault is paused with requests outstanding that `cancel` admits
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
`executeGovernorBatch(calls, callCaps, maxNetOutflow)` SHALL be callable only by the governor resolved live from the factory, only while unpaused, and non-reentrantly. Before executing, the vault SHALL verify the shared executor library's bytecode still matches the expected codehash, stamped at initialization and re-stamped by the factory-only `setExecutorImpl` re-point (`ExecutorCodehashMismatch` on drift), run the structural batch guard (registered-strategy targets; on the asset, the named selector set with `transferFrom` from the vault only), then delegatecall the library's `executeBatch(calls, asset(), callCaps)`, which meters each call's gross outflow against its cap when `callCaps` is non-empty, bubbling any failure's revert data. After success it SHALL reset every allowance the batch granted on `asset()` to zero, emit `GovernorBatchExecuted(governor, callCount)`, and enforce, in order: net asset outflow of the batch not exceeding `maxNetOutflow` (`MaxNetOutflowExceeded`), idle balance not below the queue reserve (`QueueReserveBreached`), and the idle-liquidity buffer (`BufferBreached`).

#### Scenario: Non-governor caller rejected
- **WHEN** any address other than the factory-resolved governor calls `executeGovernorBatch`
- **THEN** the call reverts `NotGovernor`

#### Scenario: Swapped executor bytecode rejected
- **WHEN** the code at the executor implementation address no longer matches the expected codehash
- **THEN** the batch reverts `ExecutorCodehashMismatch` before any call executes

#### Scenario: Net-outflow ceiling
- **WHEN** a batch moves more of the vault asset out of custody than `maxNetOutflow`
- **THEN** the batch reverts `MaxNetOutflowExceeded(netOutflow, cap)`

### Requirement: Fee parameters
The vault SHALL expose an initialization-time `managementFeeBps` and an owner-settable agent performance fee `agentFeeBps`. The agent fee SHALL default to `FeeConstants.DEFAULT_AGENT_FEE_BPS` (2000 bps, 20%) until explicitly set, SHALL distinguish an explicit 0% from unset, SHALL be capped at `MAX_AGENT_FEE_BPS` (2500 bps, 25% — an alias of the protocol performance-fee ceiling `FeeConstants.MAX_PERFORMANCE_FEE_BPS`; `AgentFeeTooHigh` above), and SHALL emit `AgentFeeUpdated` on change. The fee is snapshotted onto a proposal at propose time and clamped to the governor's configured maximum at settlement. `transferPerformanceFee(asset, to, amount)` SHALL be governor-only, restricted to the vault's own underlying asset (`InvalidAsset` otherwise), to a nonzero recipient, and to at most the vault's balance (`AmountExceedsBalance`).

#### Scenario: Default agent fee
- **WHEN** the owner has never called `setAgentFeeBps`
- **THEN** `agentFeeBps()` returns 500

#### Scenario: Explicit zero survives
- **WHEN** the owner sets the agent fee to 0
- **THEN** `agentFeeBps()` returns 0, not the 5% default

### Requirement: Agent registration and removal
The owner SHALL manage the registered-agent set: `registerAgent(agentId, agentAddress)` SHALL reject the zero address, an already-active agent (`AgentAlreadyRegistered`), and any registration that would exceed `MAX_AGENTS_PER_VAULT` (32; `AgentCapExceeded`). The registry SHALL be the factory's current `agentRegistry()`, read live at each registration (the vault's init-time snapshot is not consulted), so a factory re-point or disable applies to existing vaults. When that registry is non-zero, the `agentId` NFT SHALL be owned by the agent address or the vault owner at registration time (`NotAgentOwner` otherwise); ownership is checked at registration only — later NFT transfers do not revoke vault privileges until `removeAgent`. `removeAgent` SHALL fully delete the agent's config (`AgentNotActive` if inactive) so stale entries cannot be reused. Membership SHALL be readable via `isAgent`, `getAgentCount`, and paginated `agentsPaginated`.

#### Scenario: Registration on a registry-less chain
- **WHEN** the factory's `agentRegistry()` is zero
- **THEN** `registerAgent` skips the NFT-ownership check

#### Scenario: Registration follows the factory's current registry
- **WHEN** the factory owner re-points `agentRegistry` after a vault was created
- **THEN** that vault's next `registerAgent` checks NFT ownership against the new registry, not the one it was initialized with

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
Owner-only `pause`/`unpause` SHALL freeze LP flow (`deposit`/`mint`/`withdraw`/`redeem`), queued-deposit claims (`settleDeposit`), strategy execution (`executeGovernorBatch`), and new queue requests (`requestRedeem`/`requestDeposit`), while leaving queue `cancel` available. Owner rescue paths — `rescueEth`, `rescueERC20`, `rescueERC721` — SHALL remain callable while paused but SHALL revert `RedemptionsLocked` whenever any proposal is open, Drafts included, so the owner cannot siphon strategy-transit assets mid-proposal. `rescueERC20` SHALL revert `ZeroAddress` for a zero recipient, SHALL never move the vault asset (`CannotRescueAsset`) and SHALL send a non-asset token only to a strategy clone of this vault: the protocol strategy factory's `cloneTemplate(to)` SHALL be non-zero and `IStrategy(to).vault()` SHALL equal the vault, both read fail-closed (an unwired factory, a codeless recipient or one that does not answer reverts `RescueRecipientNotStrategy(to)`). Registration through the permissionless `registerStrategy` SHALL NOT qualify a recipient. A token sent there returns to the vault only through a later proposal's batch. The vault SHALL have no `receive`/`fallback` (raw ETH sent directly is rejected). `redemptionsLocked()` and `depositsLocked()` SHALL fail closed: a zero governor address SHALL revert `GovernorNotSet` rather than reporting unlocked.

#### Scenario: Pause freezes flow and execution
- **WHEN** the owner pauses the vault
- **THEN** deposits, withdrawals, queue requests, queued-deposit claims, and governor batches all revert until unpause

#### Scenario: Rescue blocked mid-proposal
- **WHEN** any proposal is open, including a Draft
- **THEN** all three rescue functions revert `RedemptionsLocked` regardless of pause state

#### Scenario: Rescued token goes only to a clone of the vault
- **WHEN** the owner calls `rescueERC20` for a non-asset token with a recipient that is the owner, an arbitrary address, a hand-registered strategy, or a factory clone bound to another vault
- **THEN** the call reverts `RescueRecipientNotStrategy(to)`
- **AND** the same rescue to a factory clone bound to this vault succeeds, and a later proposal's batch calling that clone returns the value to the vault

#### Scenario: Missing governor fails closed
- **WHEN** the factory resolves a zero governor for the vault
- **THEN** `redemptionsLocked()` (and everything gated on it) reverts `GovernorNotSet` instead of silently unlocking

### Requirement: Queue authorization boundaries
The queue SHALL accept `queueRedeem`, `queueDeposit`, and `stampSettlement` only from its immutable bound vault (`NotVault` otherwise); the vault SHALL accept `settleRedeem` and `settleDeposit` only from its bound queue (`NotQueue`) and `onProposalSettled` only from its governor. Request ids SHALL start at 1 (index 0 is a sentinel; out-of-range ids revert `RequestNotFound`). The queue SHALL expose `pendingShares`, `pendingDepositAssets`, `reservedAssets`, per-owner request ids, per-request state (owner, amount, pid, kind, claimed/cancelled, custody interval `queuedAt`/`closedAt`), and stamped settle prices.

#### Scenario: Third party cannot mint via queue surface
- **WHEN** any address other than the bound queue calls `settleDeposit` or `settleRedeem` on the vault
- **THEN** the call reverts `NotQueue`

### Requirement: Deposits are not charged a fee

The vault SHALL charge nothing on entry. (Relocated verbatim from the retired
`instant-exit-fees` capability — it was never Lane-A-specific.)

#### Scenario: A deposit incurs no fee

- **WHEN** a depositor deposits into the vault
- **THEN** the shares issued reflect the full deposited amount, less no fee

### Requirement: Storage layout is pinned and CI-enforced

The vault's linear storage layout SHALL be pinned at two independent layers,
mirroring the protocol's existing golden-layout guard for the other
proxy-upgraded contracts:

1. A committed golden snapshot (`script/syndicate-vault-layout.golden.json`)
   in the canonical format emitted by `script/check-layout-goldens.sh` —
   every top-level state variable's label, slot, offset, and normalized type
   in declaration order (AST ids stripped, array lengths preserved), plus the
   internal member layout of every struct transitively reachable from
   storage. `check-layout-goldens.sh` SHALL compare the compiler-emitted
   layout of `SyndicateVault` against this golden via the same
   `check_contract` convention as the other pinned contracts, and CI SHALL
   run it (the `storage-layout` job runs the whole script).
2. A raw-slot pin test (`test/VaultLayoutPins.t.sol`) following the structure
   and assertion style of the existing layout-pin tests: sentinel values
   written through real entry points (or, for fields writable only deep in
   the proposal lifecycle, `vm.store` reverse-pinned through their public
   getters) and asserted at frozen slot indices with `vm.load`, so a
   reorder/insert/retype fails under plain `forge test` even when the shell
   script is not run.

The pinned baseline is the layout at the time this change lands. Because the
vault is a UUPS proxy whose upgrades are factory-gated, once any vault proxy
is live the layout SHALL evolve append-only: new fields are carved from the
FRONT of `__gap` (shrinking it), pins are added but never edited, and the
golden is regenerated with `./script/check-layout-goldens.sh --update-golden`
in the same PR as the storage change. Before any vault proxy is live, a
deliberate layout break MAY re-baseline the golden and the pin test in the
same PR — the diff makes the break reviewed and conscious, which is the
gate's purpose.

#### Scenario: Layout drift fails CI

- **WHEN** a change reorders, inserts, deletes, or retypes any
  `SyndicateVault` state variable, or resizes `__gap` without a matching
  field change, without regenerating the golden
- **THEN** `script/check-layout-goldens.sh` exits non-zero and the CI layout
  step fails

#### Scenario: Slot move fails under plain forge test

- **WHEN** a `SyndicateVault` state variable moves to a different slot or
  intra-slot offset and the test suite runs without the shell script
- **THEN** at least one assertion in `test/VaultLayoutPins.t.sol` fails

#### Scenario: Append-only evolution passes

- **WHEN** a new field is appended by carving it from the front of `__gap`
  (gap length decremented accordingly), the golden is regenerated in the same
  PR, and a pin for the new field is added without editing existing pins
- **THEN** both the golden check and the pin test pass

#### Scenario: Empty or misresolved layout is refused

- **WHEN** the checker's `forge inspect` read for `SyndicateVault` resolves
  to an empty storage layout (e.g. the contract is renamed and the name now
  matches an interface or library)
- **THEN** `script/check-layout-goldens.sh` hard-fails rather than comparing
  or baking a layout that pins nothing

### Requirement: Per-call gross-outflow metering in the batch executor
The shared batch executor library's `executeBatch(calls, asset, caps)` SHALL, when `caps` is non-empty, meter every call: `outflow_i = max(0, assetBalanceBefore_i − assetBalanceAfter_i)` measured on the executing vault's balance of `asset` (the library runs under delegatecall, so `address(this)` is the vault), and SHALL revert the entire batch with `CallCapExceeded(i, outflow_i, caps[i])` when any call's gross outflow exceeds its declared cap — fail-closed on money; there is no mode that lets the spend proceed while only the accounting objects. Metering SHALL be GROSS across calls: an inflow during call *j* SHALL NOT increase any other call's remaining budget (each call is judged against its own cap from its own pre-call snapshot; netting within one atomic call is inherent and permitted). A non-empty `caps` array whose length differs from `calls` SHALL revert `CapsLengthMismatch`. An empty `caps` array SHALL skip per-call metering entirely — reserved for callers with no propose-time declaration (the guardian-reviewed emergency path), which remain bounded by the vault's batch-level checks. The library SHALL remain stateless and access-control-free (the calling vault enforces authorization and custody limits), SHALL bubble sub-call revert data unchanged, and SHALL NOT retain the previous unmetered `executeBatch(calls)` selector — a mis-wired vault must fail closed, never fall back to unmetered execution. The library's `simulateBatch(calls, asset, caps)` SHALL accept the same inputs and report each call's success, return data, and measured gross outflow on `address(this)`, so a proposer can size caps from a dry-run executed in the vault's context (an `eth_call` with a state override placing the library at the vault); the vault exposes no simulation entrypoint of its own.

#### Scenario: Refund does not refill an earlier budget
- **GIVEN** caps `[100, 0]` where call 1 sends 100 of the asset out and call 2 receives 150 back
- **WHEN** the batch executes
- **THEN** it succeeds (call 1 outflow 100 ≤ 100; call 2 outflow 0 ≤ 0) — and reordering the inflow FIRST would not license call 2 to overspend: with caps `[0, 100]` and the outflow second, the outflow call is still judged only against its own cap

#### Scenario: Breach reverts the whole batch
- **WHEN** call 3 of a five-call batch exceeds its cap
- **THEN** the entire batch reverts `CallCapExceeded(2, outflow, cap)` — calls 1-2's effects are rolled back and calls 4-5 never run

#### Scenario: Zero cap enforces zero outflow
- **WHEN** a call with cap 0 moves any nonzero amount of the vault asset out of custody
- **THEN** the batch reverts `CallCapExceeded` — a zero cap is a binding declaration, not an unmetered call

#### Scenario: Length mismatch fails fast
- **WHEN** `executeBatch` receives three calls and two caps
- **THEN** it reverts `CapsLengthMismatch` before executing any call

#### Scenario: Simulation reports per-call outflows
- **WHEN** a proposer dry-runs a batch through `simulateBatch` in the vault's context with candidate caps
- **THEN** the result reports each call's gross outflow so caps can be sized to observed behavior, and simulation never enforces authorization (eth_call usage, matching today's `simulateBatch` contract)

### Requirement: Every non-asset batch target is a registered strategy

For every governor-batch call whose `target` is not the vault's underlying `asset()`, the guard SHALL require that the protocol's `StrategyFactory` holds `target` as a registered strategy whose code is unchanged since registration, and SHALL revert `NotARegisteredStrategy(target)` otherwise. The vault SHALL resolve the factory live through `governor → tierRegistry() → strategyFactory()` and read `isRegisteredStrategy(target)` on it; every hop SHALL be fail-closed — a governor or registry that does not answer, an unwired (`address(0)`) factory, or a factory that does not answer the selector with one word SHALL read as "not registered". Admission is not endorsement: the batch's effect on custody is bounded by the outflow meter, the queue reserve and the buffer floor, and its price by the tier snapshotted at propose. The vault SHALL NOT decode recipients, consult any allowlist, or probe a callee's `vault()` inside the guard.

#### Scenario: Unregistered contracts are refused whatever the calldata
- **WHEN** a batch names Morpho directly, the withdrawal queue, the governor, the vault itself, the tier registry or any contract nobody registered
- **THEN** `executeGovernorBatch` reverts `NotARegisteredStrategy(target)` before any call executes

#### Scenario: A registered strategy is admitted with any selector
- **WHEN** a batch approves a registered hand-written strategy and calls it with a selector no registry names, pulling at most `maxNetOutflow` and within each call's cap
- **THEN** the batch executes

#### Scenario: A code change de-registers
- **WHEN** a registered strategy's code changes after registration and a batch names it
- **THEN** the batch reverts `NotARegisteredStrategy(target)`

#### Scenario: Unwired factory refuses every non-asset target
- **WHEN** the registry's `strategyFactory()` is `address(0)` and a batch names a strategy that was registered elsewhere
- **THEN** the batch reverts `NotARegisteredStrategy(target)`; asset calls are still admitted under the asset rules

#### Scenario: A factory that does not answer fails closed
- **WHEN** `isRegisteredStrategy` on the resolved factory reverts or returns other than one word
- **THEN** the batch reverts `NotARegisteredStrategy(target)`

### Requirement: On the asset, a call is a metered transfer or allowance-shaped, and no allowance survives the batch

For every governor-batch call whose `target` is `asset()`: calldata shorter than 36 bytes SHALL revert `MalformedAssetCall(selector)` before any call executes. `transfer(to, n)` and `transferFrom(vault, to, n)` SHALL be admitted as metered egress; `transferFrom` whose first argument word is not the vault's address SHALL revert `TransferFromNotVault(from)`. The approve family — `approve(address,uint256)`, `increaseAllowance(address,uint256)`, `increaseApproval(address,uint256)`, `decreaseAllowance(address,uint256)` and `decreaseApproval(address,uint256)` — SHALL be admitted as allowance-shaped: the guard SHALL record the first argument word as a spender, and after the batch's delegatecall returns — before the outflow, reserve and buffer checks — the vault SHALL `forceApprove(spender, 0)` on `asset()` for each recorded spender. Every other selector, reads included, SHALL revert `UnrecognizedAssetSelector(selector)` before any call executes: a token's own extensions (Paxos's `transferFromBatch`, for one) can spend allowances held by the vault, so the asset surface is a named set. The governor SHALL apply the same predicate at propose to both batches, so no proposal can reach `Executed` on an asset leg that execute or settle would refuse. The rule SHALL apply on the execute, settlement and emergency batch paths alike.

#### Scenario: transferFrom from an LP is refused
- **WHEN** a batch contains `asset.transferFrom(lp, x, n)` where `lp` holds a standing deposit allowance to the vault
- **THEN** the batch reverts `TransferFromNotVault(lp)` before any call executes and the LP's allowance is untouched

#### Scenario: transferFromBatch naming an LP is refused
- **WHEN** the asset exposes `transferFromBatch(address[],address[],uint256[])` and a batch or a proposal's execute or settlement leg calls it with an LP as `from[0]`
- **THEN** `executeGovernorBatch` and `propose` revert `UnrecognizedAssetSelector(transferFromBatch.selector)` before any call executes, and the LP's balance and allowance to the vault are untouched

#### Scenario: Reads and unknown grant shapes are refused
- **WHEN** a batch calls the asset with `balanceOf`, `allowance`, `permit`, `transferAndCall` or any selector outside the admitted set
- **THEN** the batch reverts `UnrecognizedAssetSelector(selector)` before any call executes

#### Scenario: Short asset calldata is refused
- **WHEN** a batch contains an asset call of fewer than 36 bytes (empty, `decimals()`, a bare `transferFrom` selector, an `approve` truncated to 35 bytes)
- **THEN** the batch reverts `MalformedAssetCall(selector)` before any call executes

#### Scenario: A Paxos-shaped asset's increaseApproval is reset
- **WHEN** the asset grants through `increaseApproval(address,uint256)` and has no `increaseAllowance` (the launch asset's shape) and a batch grants two spenders through it, one of which pulls inside the batch
- **THEN** after `executeGovernorBatch` returns, `asset.allowance(vault, spender)` is zero for both, and in the next block `transferFrom(vault, attacker, n)` by the idle spender reverts for insufficient allowance

#### Scenario: transferFrom from the vault is admitted and metered
- **WHEN** a batch approves the vault itself and calls `asset.transferFrom(vault, x, n)` with a call cap of at least `n`, and the reserve and buffer checks pass
- **THEN** the batch executes iff `n <= maxNetOutflow`, else reverts `MaxNetOutflowExceeded`

#### Scenario: transfer is admitted and metered
- **WHEN** a batch contains `asset.transfer(x, n)` with a call cap of at least `n`, and the reserve and buffer checks pass
- **THEN** the batch executes iff `n <= maxNetOutflow`, else reverts `MaxNetOutflowExceeded`

#### Scenario: Every recorded spender reads zero allowance after the batch
- **WHEN** a batch grants two spenders via `approve` or `increaseAllowance`, one of which pulls inside the batch and one of which does not
- **THEN** after `executeGovernorBatch` returns, `asset.allowance(vault, spender)` is zero for both

#### Scenario: Approve-then-drain in a later block is impossible
- **WHEN** a batch approves `attacker` for `type(uint256).max` and no call pulls
- **THEN** in the next block `asset.transferFrom(vault, attacker, 1)` by `attacker` reverts for insufficient allowance

