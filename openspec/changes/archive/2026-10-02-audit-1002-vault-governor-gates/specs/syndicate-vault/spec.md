## MODIFIED Requirements

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
