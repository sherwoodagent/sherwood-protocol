## MODIFIED Requirements

### Requirement: Settlement price stamping

When the governor notifies settlement via `onProposalSettled(pid)` (governor-only),
the vault SHALL stamp one frozen settle price into the queue: `num = totalAssets() +
1`, `den = _pricingSupply() + 10^decimalsOffset`, where `_pricingSupply()` is
`totalSupply()` minus the shares of earlier stamped-but-unclaimed redeems (whose
assets `totalAssets()` already excludes); on a queueless vault the call SHALL be a
no-op. The queue SHALL accept at most one stamp per proposal id (`AlreadySettled` on
re-stamp) and SHALL, at stamp time, reserve `mulDiv(queuedRedeemShares(pid), num,
den)` assets for that proposal's queued redemptions, adding it to the aggregate
`reservedAssets`.

#### Scenario: One frozen price per proposal

- **WHEN** a proposal settles with queued requests tagged to it
- **THEN** every redeem request tagged to that proposal claims against a single stamped
  `num/den`, and a second stamp for the same pid reverts

#### Scenario: Reserve created at stamp

- **WHEN** a proposal with queued redeem shares is stamped
- **THEN** `reservedAssets` increases by the aggregate asset value of those shares at
  the stamped price

### Requirement: Claiming settled requests
`claim(requestId)` SHALL be permissionless and SHALL reject already-claimed (`AlreadyClaimed`) or cancelled (`AlreadyCancelled`) requests. A redeem claim SHALL require the request's proposal to be stamped (`NotSettled` otherwise) and redemptions to be unlocked (`VaultLocked` while a proposal is active), and SHALL pay `mulDiv(shares, num, den)` at the request's own proposal's stamped price via the vault's queue-only `settleRedeem` (burn escrowed shares, transfer assets to the request owner). A deposit claim SHALL require that deposits are unlocked (`VaultLocked` while a proposal is active); it carries no stamped price and SHALL mint `previewDeposit(assets)` shares at the live price read before the escrowed assets are pushed into the vault, then the queue-only `settleDeposit` mints them (`ZeroShares` if that rounds to zero).

#### Scenario: Redeem claim at frozen price
- **WHEN** a settled redeem request is claimed
- **THEN** the escrowed shares are burned, the owner receives assets at the request's own stamped price, and `RequestClaimed` is emitted

#### Scenario: Deposit claim priced live
- **WHEN** a deposit request is claimed while no proposal is open
- **THEN** shares are minted at `previewDeposit(assets)` read immediately before the assets reach the vault, whatever proposal the request was tagged to

#### Scenario: No claims mid-proposal
- **WHEN** a later proposal is active at claim time
- **THEN** `claim` reverts `VaultLocked`

### Requirement: Request cancellation
`cancel(requestId)` SHALL be callable only by the request owner. A redeem request SHALL be cancellable only before its proposal is stamped; after stamping it SHALL revert `AlreadySettled` (a post-settle cancel would be a free look-back option). A deposit request carries no stamped price and SHALL be cancellable at any time until it is claimed. Cancellation SHALL return the escrowed shares (redeem) or assets (deposit) to the owner, mark the request cancelled, and emit `RequestCancelled`. Cancellation SHALL remain available while the vault is paused.

#### Scenario: Pre-stamp cancel returns escrow
- **WHEN** an owner cancels an unstamped redeem request
- **THEN** the escrowed shares transfer back and pending counters decrease

#### Scenario: Post-stamp redeem cancel is forbidden
- **WHEN** a redeem request's proposal has been stamped
- **THEN** `cancel` reverts `AlreadySettled` and the request must be claimed

#### Scenario: Deposit cancel after settlement
- **WHEN** a deposit request's proposal has settled and the request is still unclaimed
- **THEN** the owner can still `cancel` it and recover the escrowed assets

#### Scenario: Paused vault does not trap queued LPs
- **WHEN** the vault is paused with unclaimed requests outstanding
- **THEN** owners can still `cancel` (a redeem only while unstamped) and recover their escrow
