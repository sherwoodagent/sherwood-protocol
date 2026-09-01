# syndicate-vault (delta)

<!-- Change: club-vaults-and-transfer-gating (SHE-197, SHE-201). Adds two
     requirements — a whitelist-gated share-transfer guard and a
     beneficial-owner cap — and modifies four existing ones so the queue
     escrow round trip, the delegation heal, and the depositor-access surface
     stay coherent under the guard. No fee, coverage, or governor behavior
     is touched here. -->

## ADDED Requirements

### Requirement: Whitelist-gated share transfers

While the vault is in whitelist mode (`openDeposits() == false`), every ERC-20 share movement SHALL require the RECEIVER to be an approved depositor, and SHALL revert `ReceiverNotApproved(receiver)` otherwise. The guard SHALL live on the single internal update hook every mint, burn and transfer passes through — the same hook that carries auto-delegation — and SHALL be evaluated BEFORE balances and voting checkpoints are written, so no checkpoint is produced on a rejected movement. The guard SHALL NOT inspect the SENDER: a holder may always send shares out and may always redeem, and the vault SHALL expose no path by which an owner or any other party can restrict, freeze, seize, or forcibly move a holder's shares. Adversary: a whitelisted member who mints into a permissioned vault and then transfers the shares to an unvetted third party, defeating the register the whitelist is supposed to be.

The guard SHALL be skipped, and ONLY skipped, for: a mint (`from == address(0)`, already gated on the receiver at both deposit entrypoints); a burn (`to == address(0)`); any movement where the vault itself is the sender or receiver; **both directions of withdrawal-queue custody** (`to == withdrawalQueue()` for the escrow leg, `from == withdrawalQueue()` for the cancel-return leg); and any zero-value movement, which creates no beneficial ownership and whose only effect is the permissionless delegation heal. In open-deposit mode (`openDeposits() == true`) the guard SHALL be inert, exactly as the deposit gate is.

When a vault flips from open to whitelist mode with shares already held outside the whitelist, those holders SHALL be grandfathered for EXIT only: they may transfer to any approved address, redeem or withdraw instantly, escrow into the redemption queue, and cancel back out of it; they SHALL NOT be able to receive further shares by any path. No grandfather register SHALL exist — receiver-only gating is what produces this behavior, and a design requiring a snapshot of existing holders at flip time is explicitly rejected.

A rejected movement SHALL produce no event: the named revert is the entire signal, and the vault SHALL NOT implement a silent-failure ERC-20 return-`false` path.

#### Scenario: Transfer to a non-approved receiver is rejected
- **WHEN** a holder transfers shares to an address that is not an approved depositor while `openDeposits()` is false
- **THEN** the call SHALL revert `ReceiverNotApproved` and no balance, checkpoint, or delegation SHALL change

#### Scenario: Transfer between approved members succeeds
- **WHEN** an approved depositor transfers shares to another approved depositor
- **THEN** the transfer SHALL succeed with unchanged ERC20Votes semantics — the receiver's post-receipt balance checkpoints and an undelegated receiver still auto-delegates to itself

#### Scenario: Grandfathered holder can leave but cannot accumulate
- **WHEN** a vault flips to whitelist mode while an address outside the whitelist holds shares
- **THEN** that address SHALL still be able to transfer to an approved address, to redeem, and to use the redemption queue — and SHALL revert `ReceiverNotApproved` if anyone tries to send it more shares

#### Scenario: Queue escrow is not blocked
- **WHEN** a holder in a whitelisted vault calls `requestRedeem` and the shares move into queue custody
- **THEN** the movement SHALL succeed even though the queue is not an approved depositor, and the queue SHALL NOT be added to the whitelist to achieve this

#### Scenario: Cancelled escrow returns to a de-listed owner
- **WHEN** an owner escrows a redeem request and is removed from the whitelist before the request's proposal is stamped, then cancels
- **THEN** the escrowed shares SHALL return to them — the cancel-return leg is exempt, so a whitelist removal can never strand shares whose only other exit (post-stamp cancel) is already forbidden

#### Scenario: Zero-value delegation heal survives the guard
- **WHEN** anyone transfers 0 shares to an undelegated holder that is not on the whitelist
- **THEN** the call SHALL succeed and the holder SHALL become self-delegated, preserving the permissionless heal

#### Scenario: Open mode is unaffected
- **WHEN** `openDeposits()` is true
- **THEN** share transfers SHALL behave exactly as they do today, with no whitelist consultation

### Requirement: Beneficial-owner cap

The vault SHALL carry a `maxHolders` parameter, where 0 means uncapped and is the default for every vault created before or without this setting, and SHALL maintain a count of distinct addresses holding a nonzero share balance. The count SHALL be maintained in the same internal update hook as the transfer guard: incremented when a movement takes a counted receiver from a zero to a nonzero balance, decremented when it takes a counted sender from a nonzero balance to zero. `address(0)`, the vault itself, and the bound withdrawal queue SHALL NOT be counted — none is a beneficial owner. Adversary: a fund that claims an Investment Company Act §3(c)(1) exemption while its ownership is unbounded and unobserved.

When `maxHolders != 0`, any movement that would CREATE a new counted holder SHALL revert `MaxHoldersExceeded` if the count is already at the cap. This SHALL apply to mints (both the instant deposit path and the queue's settled-deposit mint) as well as to gated transfers — a cap that bound only transfers would be bypassed by depositing to a fresh address. The check SHALL be evaluated on the gain alone and SHALL NOT be netted against a simultaneous departure in the same movement, so admissibility never depends on the sender's exact balance; a transfer that both empties its sender and creates its receiver is net-neutral and SHALL be permitted at the cap.

Movements originating from the withdrawal queue (`from == withdrawalQueue()`) SHALL be exempt from the cap as well as from the transfer guard: a returning escrow is a holder the vault already counted, and refusing it would strand shares whose post-stamp cancel path is already closed. The count MAY therefore transiently exceed `maxHolders` by at most the number of live redeem requests whose owners emptied their balance; it self-heals on the next claim or exit, and the club preset's 99 (rather than 100) is the headroom that keeps this slack below the statutory line. The queue's settled-deposit mint SHALL remain cap-checked, which is safe because a deposit request can be cancelled unconditionally, even after its proposal is stamped.

`maxHolders != 0` SHALL require whitelist mode. `setMaxHolders` with a nonzero value SHALL revert `HolderCapRequiresWhitelist` while `openDeposits()` is true, `setOpenDeposits(true)` SHALL revert `HolderCapRequiresWhitelist` while `maxHolders != 0`, and creation SHALL validate the same pair before any side effect. Adversary: a griefer who, on an open-deposit vault with a cap, deposits dust to `maxHolders` fresh addresses and permanently locks out every real depositor for the price of gas. Both `maxHolders` and the holder count SHALL be readable, and `setMaxHolders` SHALL be owner-only and SHALL emit a change event. Setting `maxHolders` below the current count SHALL be permitted and SHALL NOT reduce anyone's balance — it forbids creating new holders and nothing else.

#### Scenario: Cap blocks a new holder
- **WHEN** a vault at `maxHolders` receives a transfer or mint to an approved address with a zero balance
- **THEN** the call SHALL revert `MaxHoldersExceeded`

#### Scenario: Cap does not block topping up an existing holder
- **WHEN** a vault at `maxHolders` receives a transfer or mint to an address that already holds a nonzero balance
- **THEN** the movement SHALL succeed — no new beneficial owner is created

#### Scenario: A full club can still churn
- **WHEN** a holder at a full vault transfers their entire balance to a new approved address
- **THEN** the movement SHALL succeed: the departure and the arrival are counted independently and the net count is unchanged

#### Scenario: Escrow return is never blocked by the cap
- **WHEN** an owner who emptied their balance into the redemption queue cancels, and joiners have taken the freed slot in the meantime
- **THEN** the shares SHALL return and the count MAY transiently sit above `maxHolders` until the next burn or exit

#### Scenario: Holder cap requires whitelist mode
- **WHEN** an owner sets a nonzero `maxHolders` on an open-deposit vault, or reopens deposits on a capped vault
- **THEN** the call SHALL revert `HolderCapRequiresWhitelist`

#### Scenario: Lowering the cap below the count is not confiscatory
- **WHEN** an owner lowers `maxHolders` below the current holder count
- **THEN** the call SHALL succeed, no balance SHALL change, and only the creation of further holders SHALL be blocked

#### Scenario: Uncapped is the default and is byte-identical to today
- **WHEN** `maxHolders == 0`
- **THEN** no counting logic SHALL affect any outcome and the vault SHALL behave exactly as it does before this change

## MODIFIED Requirements

### Requirement: Vote checkpointing and auto-delegation
The vault share token SHALL implement ERC20Votes with a timestamp-based clock (`clock()` returns `block.timestamp`; `CLOCK_MODE()` is `mode=timestamp`). On every share receipt (mint or transfer, including zero-value transfers), the vault SHALL auto-delegate an undelegated recipient to itself, after balances update, so checkpointed voting power tracks balance for every holder that has not explicitly delegated elsewhere. The same internal update hook SHALL additionally host the whitelist transfer guard and the beneficial-owner count, evaluated BEFORE the balance update so that a rejected movement writes no checkpoint; neither addition SHALL change the arguments passed to the inherited update, so checkpoint arithmetic on every surviving path is identical to today's.

#### Scenario: Recipient auto-delegates on receipt
- **WHEN** shares are transferred or minted to an address whose delegate is unset
- **THEN** the recipient is delegated to itself and its post-receipt balance is checkpointed

#### Scenario: Permissionless heal via zero-value transfer
- **WHEN** anyone transfers 0 shares to an undelegated legacy holder
- **THEN** that holder becomes self-delegated and checkpointed from that moment, whether or not the holder is on the whitelist

#### Scenario: Explicit delegation preserved
- **WHEN** shares arrive at a holder that has already delegated to another address
- **THEN** the existing delegation choice is unchanged

#### Scenario: Rejected movement leaves no checkpoint
- **WHEN** a movement is rejected by the transfer guard or the holder cap
- **THEN** the whole call SHALL revert, and no balance, checkpoint, delegation, or high-water-mark side effect SHALL be observable

### Requirement: Depositor access control
The vault owner SHALL control share-holding access via an open/closed mode flag (`setOpenDeposits`), an approved-depositor whitelist (`approveDepositor`, `approveDepositors`, `removeDepositor`), and a beneficial-owner cap (`setMaxHolders`), all owner-only. In closed mode the whitelist SHALL govern who may RECEIVE shares by any route — minting and transfer alike — not merely who may deposit. Approving the zero address SHALL revert `InvalidDepositor`; re-approving via the single-address path SHALL revert `DepositorAlreadyApproved`; removing an unapproved depositor SHALL revert `DepositorNotApproved`. Removing a depositor SHALL NOT touch their existing balance: removal stops them receiving more, and never blocks their exit. `setOpenDeposits(true)` SHALL revert `HolderCapRequiresWhitelist` while a nonzero `maxHolders` is set. Whitelist membership SHALL be readable via `isApprovedDepositor` and paginated via `approvedDepositorsPaginated`, with page size hard-clamped to `MAX_PAGE_LIMIT` (100); the whitelist is an ELIGIBILITY list and SHALL NOT be read as the holder register, since an approved member may hold nothing and one member may hold across several approved addresses.

#### Scenario: Batch approval is idempotent
- **WHEN** the owner calls `approveDepositors` with an already-approved address
- **THEN** the call does not revert for the duplicate (only zero addresses revert) and emits `DepositorApproved` per entry

#### Scenario: Pagination clamp
- **WHEN** a paginated view is called with `limit > 100`
- **THEN** at most 100 rows are returned

#### Scenario: Removal stops receipt, never exit
- **WHEN** the owner removes an approved depositor who currently holds shares
- **THEN** that holder SHALL keep every exit path and SHALL be unable to receive further shares

#### Scenario: Reopening deposits on a capped vault is refused
- **WHEN** the owner calls `setOpenDeposits(true)` while `maxHolders != 0`
- **THEN** the call SHALL revert `HolderCapRequiresWhitelist`

### Requirement: Async redemption requests (Lane B)

`requestRedeem(shares, owner)` SHALL be callable only while `redemptionsLocked()` is
true, the vault is not paused, and a withdrawal queue is bound; zero shares SHALL
revert `InsufficientShares`, an unset queue `WithdrawalQueueNotSet`, and an unlocked
vault `RedemptionsNotLocked`. A caller other than the share owner SHALL spend ERC-20
allowance. The shares SHALL be transferred (not burned) into queue custody, tagged
with the active proposal id, and a request id strictly greater than 0 SHALL be
returned with `RedeemRequested` emitted. The escrow leg SHALL be exempt from the
whitelist transfer guard and SHALL decrement the beneficial-owner count when it
empties the owner's balance; the queue SHALL NOT be an approved depositor and SHALL
NOT be counted as a holder.

#### Scenario: Queued exit escrows shares

- **WHEN** a holder requests a redemption mid-proposal
- **THEN** their shares move into queue custody (retaining checkpointed voting weight
  at the queue), and burning is deferred to claim time

#### Scenario: Request outside the lock window

- **WHEN** no proposal is active
- **THEN** `requestRedeem` reverts `RedemptionsNotLocked` (instant exit is the
  correct path)

#### Scenario: Whitelisted vault does not block its own queue

- **WHEN** a holder of a closed-deposit, holder-capped vault requests a redemption
- **THEN** the escrow SHALL succeed — neither the transfer guard nor the cap applies
  to queue custody

### Requirement: Request cancellation
`cancel(requestId)` SHALL be callable only by the request owner and only before the request's proposal is stamped for a REDEEM request; a DEPOSIT request SHALL remain cancellable unconditionally. A post-stamp redeem cancel SHALL revert `AlreadySettled` (it would be a free look-back option). Cancellation SHALL return the escrowed shares (redeem) or assets (deposit) to the owner, mark the request cancelled, and emit `RequestCancelled`. Cancellation SHALL remain available while the vault is paused. The share-return leg SHALL be exempt from BOTH the whitelist transfer guard and the beneficial-owner cap — adversary: an owner who de-lists a depositor, or a club that fills to `maxHolders`, while that depositor's escrow is outstanding and their only other exit is already closed.

#### Scenario: Pre-stamp cancel returns escrow
- **WHEN** an owner cancels an unstamped redeem request
- **THEN** the escrowed shares transfer back and pending counters decrease

#### Scenario: Post-stamp cancel is forbidden
- **WHEN** a redeem request's proposal has been stamped
- **THEN** `cancel` reverts `AlreadySettled` and the request must be claimed

#### Scenario: Paused vault does not trap queued LPs
- **WHEN** the vault is paused with unstamped requests outstanding
- **THEN** owners can still `cancel` and recover their escrow

#### Scenario: De-listed or capped-out owner still recovers escrow
- **WHEN** the owner of an unstamped redeem request has been removed from the whitelist, or the vault has since reached `maxHolders`
- **THEN** `cancel` SHALL still return their shares
