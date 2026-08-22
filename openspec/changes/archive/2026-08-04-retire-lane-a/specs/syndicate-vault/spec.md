# syndicate-vault (delta)

Lane A (mid-proposal instant entry/exit at router-priced live NAV) is deleted from v1
(issue #54, deferred to V2). The vault becomes float-NAV only: deposits and instant
exits exist exclusively outside proposals; all mid-proposal LP flow is Lane B (async
queue). The two surviving behaviours are UNCHANGED and that is the point of every
modification below: instant exits outside a proposal against idle float net of the
queue reserve, and mid-proposal flow through the queue.

Note for sync: the capability's Purpose paragraph should drop "prices shares against
vault-side live NAV (Lane A)" and describe Lane B as the only mid-proposal path.

## ADDED Requirements

### Requirement: Deposits are not charged a fee

The vault SHALL charge nothing on entry. (Relocated verbatim from the retired
`instant-exit-fees` capability — it was never Lane-A-specific.)

#### Scenario: A deposit incurs no fee

- **WHEN** a depositor deposits into the vault
- **THEN** the shares issued reflect the full deposited amount, less no fee

## MODIFIED Requirements

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

## REMOVED Requirements

### Requirement: Lane eligibility rule

**Reason**: Lane A is deleted from v1 (issue #54). There is no instant lane during a
proposal, so no eligibility derivation exists; the fail-closed property this rule
provided ("no pricing ⇒ no instant exit") is subsumed by the stronger rule "active
proposal ⇒ no instant exit" in the modified withdrawal requirement.
**Migration**: None on-chain (no vault proxy is live). V2 reintroduces an
eligibility rule together with its pricing infrastructure.

### Requirement: Lane A per-holder lock (anti intra-proposal MEV)

**Reason**: The lock exists solely to bound the deposit-low/exit-high arb of Lane A
mid-proposal entries. With mid-proposal deposits impossible (`DepositsLocked`
unconditionally while a proposal is open), the attack surface the lock closes no
longer exists. `SharesLocked` is removed from the vault error set; share transfers
are unrestricted at all times.
**Migration**: None (no vault proxy is live; no holder can be lock-stranded).

### Requirement: Interim net-flow accounting

**Reason**: `interimNetFlow` only ever changed through Lane A mid-proposal deposits
and Lane A instant exits; without Lane A it is identically zero, so settlement PnL
needs no principal adjustment — mid-proposal LP flow sits in queue escrow, outside
the vault's balance, until after the PnL read.
**Migration**: The governor computes `pnl = balance − snapshot` directly; the
`interimNetFlow()` view is removed from `ISyndicateVault`.
