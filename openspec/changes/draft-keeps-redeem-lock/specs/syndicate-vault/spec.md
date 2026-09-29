## Purpose

Keep both LP-flow locks on one predicate from Draft creation to settle (v1-deploy's
deposit lock, restored in the v2 merge), and refuse delegation away from the holder.

## MODIFIED Requirements

### Requirement: Vote checkpointing and auto-delegation

The vault share token SHALL implement ERC20Votes with a timestamp-based clock (`clock()` returns `block.timestamp`; `CLOCK_MODE()` is `mode=timestamp`). On every share receipt (mint or transfer, including zero-value transfers), the vault SHALL delegate to itself any recipient that is not already self-delegated, after balances update, so checkpointed voting power tracks balance for every holder. Voting power SHALL NOT be delegated away from the holder: `delegate` and `delegateBySig` SHALL revert `DelegationDisabled` for any delegatee other than the account itself (including `address(0)`), so every share in the veto denominator is castable by its holder and the recorded electorate equals the castable weight at the snapshot.

#### Scenario: Recipient auto-delegates on receipt
- **WHEN** shares are transferred or minted to an address that is not delegated to itself
- **THEN** the recipient is delegated to itself and its post-receipt balance is checkpointed

#### Scenario: Permissionless heal via zero-value transfer
- **WHEN** anyone transfers 0 shares to a holder that is not self-delegated
- **THEN** that holder becomes self-delegated and checkpointed from that moment

#### Scenario: Delegation to another address is refused
- **WHEN** a holder calls `delegate` or `delegateBySig` with a delegatee that is not itself (another holder, the queue, or `address(0)`)
- **THEN** the call reverts `DelegationDisabled` and the holder's shares keep voting for the holder

#### Scenario: Self-delegation is a no-op
- **WHEN** a holder calls `delegate(self)`
- **THEN** the call succeeds and `delegates(holder) == holder`

### Requirement: Instant withdrawal flow and capacity

While no proposal is open, instant `withdraw`/`redeem` SHALL be available up to the
holder's balance, capped by instant capacity = available float (idle balance minus
the queue's reserved assets). From Draft creation through settle,
`maxWithdraw`/`maxRedeem` SHALL return 0 for every holder except the bound withdrawal
queue, and exits route through the async queue — full stop. The lock starts at Draft
creation, ahead of the vote snapshot and the electorate stamp, so no exit can land on
either side of the stamp: every share in the recorded electorate SHALL be capital at
risk for the cycle, and whoever can vote on a proposal SHALL remain exposed to its
outcome. A requested exit whose assets plus the queue reserve exceed the idle balance
SHALL revert `QueueReserveBreached`; the vault SHALL NOT pull capital from a strategy
to serve an exit.

#### Scenario: Exit served from float

- **WHEN** no proposal is active and a holder withdraws no more than the available
  float
- **THEN** the withdrawal is served instantly from the vault's idle balance

#### Scenario: Exit during a collaborative Draft

- **WHEN** a proposal is in Draft and a holder tries an instant redeem
- **THEN** it reverts (`maxRedeem` is 0); the holder's path is `requestRedeem`, and
  the shares stay in the electorate recorded at the later Draft → Pending transition

### Requirement: Async redemption requests (Lane B)

`requestRedeem(shares, owner)` SHALL be callable only while `redemptionsLocked()` is
true (Draft creation through settle), the vault is not paused, and a withdrawal queue is
bound; zero shares SHALL revert `InsufficientShares`, an unset queue
`WithdrawalQueueNotSet`, and an unlocked vault `RedemptionsNotLocked`. A caller other
than the share owner SHALL spend ERC-20 allowance. The shares SHALL be transferred
(not burned) into queue custody, tagged with the active proposal id, and a request id
strictly greater than 0 SHALL be returned with `RedeemRequested` emitted.

#### Scenario: Queued exit escrows shares

- **WHEN** a holder requests a redemption mid-proposal
- **THEN** their shares move into queue custody (retaining checkpointed voting weight
  at the queue), and burning is deferred to claim time

#### Scenario: Request outside the lock window

- **WHEN** no proposal is open
- **THEN** `requestRedeem` reverts `RedemptionsNotLocked` (instant exit is the
  correct path)

### Requirement: Pause and emergency behavior

Owner-only `pause`/`unpause` SHALL freeze LP flow (`deposit`/`mint`/`withdraw`/`redeem`), strategy execution (`executeGovernorBatch`), and new queue requests (`requestRedeem`/`requestDeposit`), while leaving queue `cancel` available. Owner rescue paths — `rescueEth`, `rescueERC20` (never the vault asset; `CannotRescueAsset`), `rescueERC721` — SHALL remain callable while paused but SHALL revert `RedemptionsLocked` whenever ANY proposal is open, Drafts included, so the owner cannot siphon strategy-transit assets mid-proposal. The vault SHALL have no `receive`/`fallback` (raw ETH sent directly is rejected). `redemptionsLocked()` and `depositsLocked()` SHALL fail closed: a zero governor address SHALL revert `GovernorNotSet` rather than reporting unlocked.

#### Scenario: Rescue blocked mid-proposal
- **WHEN** the owner calls a rescue path while any proposal is open, including a Draft
- **THEN** the call reverts `RedemptionsLocked`

#### Scenario: Missing governor fails closed
- **WHEN** the factory resolves a zero governor for the vault
- **THEN** `redemptionsLocked()` (and everything gated on it) reverts `GovernorNotSet` instead of silently unlocking
