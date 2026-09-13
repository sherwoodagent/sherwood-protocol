## Purpose

Split the two LP-flow locks, which were one predicate. A Draft locks nothing; the
redeem lock starts at Pending, the deposit lock at execute.

## MODIFIED Requirements

### Requirement: Instant deposit flow

`deposit`/`mint` SHALL succeed only when the vault is not paused and no proposal is
EXECUTING (governor `getActiveProposal() == 0`); from execute to settle they SHALL
revert `DepositsLocked` and depositors use the async queue (`requestDeposit`). The
lock tracks the one window in which the share price is not knowable — capital
deployed in a strategy — and nothing else: a deposit made before execute mints at a
live NAV the vault can compute, and buys no vote weight, because weight is read at
the proposal's `snapshotTimestamp` and the veto electorate was recorded at the same
instant. The whitelist check SHALL run against the `receiver` (the share holder), not
the caller, so pay-on-behalf funding is permitted.

#### Scenario: Deposit outside any open proposal

- **WHEN** no proposal is open and the receiver is eligible (deposits open, or
  receiver whitelisted)
- **THEN** the deposit mints shares at the current NAV

#### Scenario: Deposit while a proposal is Draft, Pending, GuardianReview or Approved

- **WHEN** a proposal is open but has not executed
- **THEN** `deposit`/`mint` succeed at the live NAV, and the depositor gains no
  voting power over that proposal

#### Scenario: Mid-execution deposit is locked

- **WHEN** a proposal is Executed and not yet Settled
- **THEN** `deposit`/`mint` revert `DepositsLocked` and the depositor's path is
  `requestDeposit`

#### Scenario: Non-whitelisted receiver in closed mode

- **WHEN** `openDeposits` is false and the receiver is not an approved depositor
- **THEN** the deposit reverts `NotApprovedDepositor`

#### Scenario: maxDeposit reflects every deposit gate

- **WHEN** the vault is paused, `depositsLocked()` is true, or the receiver is
  not an approved depositor in closed mode
- **THEN** `maxDeposit(receiver)`/`maxMint(receiver)` return 0; otherwise they
  return `type(uint256).max`

### Requirement: Instant withdrawal flow and capacity

While no proposal is open, and while an open proposal is still a Draft, instant
`withdraw`/`redeem` SHALL be available up to the holder's balance, capped by instant
capacity = available float (idle balance minus the queue's reserved assets). From
Pending through settle, `maxWithdraw`/`maxRedeem` SHALL return 0 for every holder
except the bound withdrawal queue, and exits route through the async queue — full
stop. The lock starts at Pending because that is where the vote snapshot and the veto
electorate are stamped: whoever can vote on a proposal SHALL remain exposed to its
outcome. A requested exit whose assets plus the queue reserve exceed the idle balance
SHALL revert `QueueReserveBreached`; the vault SHALL NOT pull capital from a strategy
to serve an exit.

#### Scenario: Exit served from float

- **WHEN** no proposal is active and a holder withdraws no more than the available
  float
- **THEN** the withdrawal is served instantly from the vault's idle balance

#### Scenario: Exit during a collaborative Draft

- **WHEN** a proposal is in Draft and a holder redeems
- **THEN** the exit is served instantly, and the holder's shares are outside the
  electorate recorded at the later Draft → Pending transition

### Requirement: Async redemption requests (Lane B)

`requestRedeem(shares, owner)` SHALL be callable only while `redemptionsLocked()` is
true (Pending through settle), the vault is not paused, and a withdrawal queue is
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

- **WHEN** no proposal is open, or the only open proposal is a Draft
- **THEN** `requestRedeem` reverts `RedemptionsNotLocked` (instant exit is the
  correct path, and no share can enter the queue before the electorate is recorded)

### Requirement: Async deposit requests (Lane B)
`requestDeposit(assets, receiver)` SHALL be callable only while `depositsLocked()` is true (a proposal is executing), the vault is not paused, and a queue is bound; zero assets SHALL revert `ZeroAssets`, `NoOpenProposal` otherwise, and the receiver SHALL pass the same whitelist rule as instant deposits. Assets SHALL be escrowed in the queue's own balance — never counted in `totalAssets()` and never sweepable into a strategy — tagged with the active proposal id, and a request id strictly greater than 0 SHALL be returned with `DepositRequested` emitted. Exactly one deposit path SHALL be open in every state: the instant one until execute, the lane from execute to settle.

#### Scenario: Escrowed deposit does not inflate NAV
- **WHEN** assets are escrowed via `requestDeposit` during an executing proposal
- **THEN** `totalAssets()` is unchanged until the request is claimed and assets are pushed into the vault

#### Scenario: Lane closed before execution
- **WHEN** a proposal is open but not executing and a depositor calls `requestDeposit`
- **THEN** the call reverts `NoOpenProposal`, because the instant path is the open one

### Requirement: Pause and emergency behavior

Owner-only `pause`/`unpause` SHALL freeze LP flow (`deposit`/`mint`/`withdraw`/`redeem`), strategy execution (`executeGovernorBatch`), and new queue requests (`requestRedeem`/`requestDeposit`), while leaving queue `cancel` available. Owner rescue paths — `rescueEth`, `rescueERC20` (never the vault asset; `CannotRescueAsset`), `rescueERC721` — SHALL remain callable while paused but SHALL revert `RedemptionsLocked` whenever ANY proposal is open, Drafts included, so the owner cannot siphon strategy-transit assets mid-proposal. The vault SHALL have no `receive`/`fallback` (raw ETH sent directly is rejected). `redemptionsLocked()` and `depositsLocked()` SHALL fail closed: a zero governor address SHALL revert `GovernorNotSet` rather than reporting unlocked.

#### Scenario: Rescue blocked mid-proposal
- **WHEN** the owner calls a rescue path while any proposal is open, including a Draft
- **THEN** the call reverts `RedemptionsLocked`

#### Scenario: Missing governor fails closed
- **WHEN** the factory resolves a zero governor for the vault
- **THEN** `redemptionsLocked()` (and everything gated on it) reverts `GovernorNotSet` instead of silently unlocking
