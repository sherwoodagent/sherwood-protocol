## MODIFIED Requirements

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
