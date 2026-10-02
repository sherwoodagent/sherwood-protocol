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

## ADDED Requirements

### Requirement: Claiming queued requests
`claim(requestId)` SHALL be permissionless and SHALL reject already-claimed (`AlreadyClaimed`) or cancelled (`AlreadyCancelled`) requests. A redeem claim SHALL require the request's proposal to be stamped (`NotSettled` otherwise) and redemptions to be unlocked (`VaultLocked` while a proposal is active), and SHALL pay `mulDiv(shares, num, den)` at the request's own proposal's stamped price via the vault's queue-only `settleRedeem` (burn escrowed shares, transfer assets to the request owner). A deposit claim SHALL require that deposits are unlocked (`VaultLocked` while a proposal is active); it carries no stamped price and SHALL mint `previewDeposit(assets)` shares at the live price read before the escrowed assets are pushed into the vault (`ZeroShares` if that rounds to zero), then the queue-only `settleDeposit` mints them. `settleDeposit` SHALL revert while the vault is paused and when the receiver fails the depositor whitelist rule (`NotApprovedDepositor`); the receiver recovers the assets with `cancel`.

#### Scenario: Redeem claim at frozen price
- **WHEN** a settled redeem request is claimed
- **THEN** the escrowed shares are burned, the owner receives assets at the request's own stamped price, and `RequestClaimed` is emitted

#### Scenario: Deposit claim priced live
- **WHEN** a deposit request is claimed while no proposal is open
- **THEN** shares are minted at `previewDeposit(assets)` read immediately before the assets reach the vault, whatever proposal the request was tagged to

#### Scenario: No claims mid-proposal
- **WHEN** a later proposal is active at claim time
- **THEN** `claim` reverts `VaultLocked`

#### Scenario: Deposit claim refused while paused
- **WHEN** a deposit request is claimed while the vault is paused
- **THEN** the claim reverts and the receiver can `cancel` the request

## REMOVED Requirements

### Requirement: Claiming settled requests
**Reason**: A deposit claim is not priced at a stamp: it mints at the live `previewDeposit` price and does not need its proposal stamped.
**Migration**: Replaced by "Claiming queued requests".
