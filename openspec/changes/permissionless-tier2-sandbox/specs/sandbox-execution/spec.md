## Purpose

Isolated, per-proposal execution of proposer-supplied arbitrary calls, so tier-2 calldata can reach any target with no owner action while the maximum loss stays structurally equal to the capital deliberately funded in — the figure tier-2 coverage already charges for.

## ADDED Requirements

### Requirement: The sandbox is protocol code, admitted by nobody
A sandbox SHALL be minted by the vault from an implementation address fixed at vault deployment. It SHALL NOT require a TierRegistry allowlist entry, a class grant, a certification, or a strategy-template approval, and no owner transaction SHALL be a precondition of any sandbox proposal or of any target a sandbox calls.

The gate being removed is the per-venue gatekeeper: the adapter allowlist is owner-managed, so every new target a proposer wanted to reach cost an owner transaction, making the strategy surface permissioned in practice even though proposing is not. Replacing that with a protocol-minted sandbox moves the review to the party that already underwrites the risk — the guardian cohort, at approval time, against slashable stake.

#### Scenario: An unlisted target executes with no owner action
- **WHEN** a sandbox proposal names a target with no allowlist entry, no certification, and no class membership, and passes the ordinary proposal lifecycle
- **THEN** the calls SHALL execute, with no owner transaction having been required at any point

#### Scenario: The sandbox holds no registry standing to lose
- **WHEN** any demotion path runs against any address in the registry
- **THEN** the sandbox path SHALL be unaffected — it depends on no registry entry, so no demotion can wedge an in-flight sandbox out of its own settlement

#### Scenario: The batch guard is untouched
- **WHEN** a governor batch names a non-allowlisted target directly, rather than routing through a sandbox
- **THEN** the vault SHALL still revert `DisallowedBatchCallee` — the sandbox path SHALL NOT relax, exempt, or widen the batch callee gate

### Requirement: Sandbox proposals are opened by registered agents under the ordinary lifecycle
A sandbox proposal SHALL be openable only by an address registered as an agent on the vault, and SHALL traverse the same lifecycle as every other proposal: proposer bond, LP vote, guardian review period, covering approve quorum, and the execution window.

The sandbox widens which TARGETS are reachable, deliberately not which PROPOSERS are admitted. Arbitrary calldata from an uncurated caller is a distinct risk with its own spam and review-load questions, and conflating the two would smuggle an unreviewed decision into this one.

#### Scenario: A non-agent cannot open one
- **WHEN** an address that is not a registered agent attempts to open a sandbox proposal
- **THEN** the call SHALL revert `NotRegisteredAgent`

#### Scenario: The coverage quorum is mandatory
- **WHEN** a sandbox proposal carries non-zero required coverage
- **THEN** it SHALL NOT execute without covering approvals from stake-backed approvers; silence alone SHALL NOT pass it

#### Scenario: Under-raised coverage scales the funding down
- **WHEN** approvers raise less coverage than the proposal requires
- **THEN** the sandbox funding SHALL be scaled down by the same raised-over-required ratio applied to effective capital, rather than the proposal reverting

### Requirement: Arbitrary calls execute under the sandbox's own identity
A sandbox SHALL dispatch its calls from its own address. No path SHALL cause an arbitrary call to carry `msg.sender == vault`, and sandbox calls SHALL NOT be routed through the governor batch.

The adversary is the identity itself: a governor batch executes under `delegatecall`, so a sub-call reaching an arbitrary target as the vault can spend the vault's standing ERC20 allowances, move vault-held position tokens through selectors no allowlist enumerates, and satisfy any `msg.sender == vault` gate on a third-party contract. Executing from a sandbox that holds only its funded balance removes every one of those capabilities at once — which is why arbitrary targets need no allowlist here and do need one in a batch.

#### Scenario: Callee observes the sandbox, never the vault
- **WHEN** a sandbox dispatches a stored call to any target
- **THEN** the target observes `msg.sender` equal to the sandbox address, and any vault-gated function on that target SHALL revert as it would for an unrelated caller

#### Scenario: Sandbox calls bypass the batch guard by not being a batch
- **WHEN** a sandbox dispatches calls
- **THEN** those calls SHALL NOT pass through the vault's batch callee or selector guards, because they are not governor-batch sub-calls

### Requirement: Maximum loss is bounded by funded capital
A sandbox SHALL receive vault capital only by an explicit transfer from the vault at execute time, and the total the vault can lose to it SHALL never exceed the amount transferred. A sandbox SHALL NOT hold any allowance against the vault at any point, and SHALL NOT be able to acquire vault capital by any other route.

The adversary is authorization-shaped calldata: the per-call meter observes only the vault's own asset balance delta, so an approval grant moves zero, meters zero and prices zero coverage while licensing an unbounded later withdrawal. Confining the callee to the sandbox's balance makes the loss ceiling structural rather than measured, so tier-2 coverage priced at full notional is an honest ceiling instead of a decorative one.

#### Scenario: Funding is capped by the live ceiling
- **WHEN** a sandbox is funded with an amount exceeding `tier2CallCapBps()` of the vault's `totalAssets()` read in that same transaction
- **THEN** execution SHALL revert — the ceiling live at execute time binds, not one captured at propose time

#### Scenario: No allowance is ever created
- **WHEN** a sandbox is funded
- **THEN** the vault SHALL transfer the assets directly, and the sandbox's allowance to spend the vault's assets SHALL be zero before, during and after execution

#### Scenario: A hostile call set cannot exceed the funded amount
- **WHEN** every stored call is chosen to maximize extraction, including approvals granted to third parties on tokens the sandbox holds
- **THEN** the vault's total loss across that proposal and every subsequent transaction SHALL be at most the amount funded into the sandbox

#### Scenario: A sandbox cannot be funded twice
- **WHEN** any caller attempts to fund or run an already-executed sandbox
- **THEN** the attempt SHALL revert

### Requirement: Privileged protocol addresses are unreachable from a sandbox
A sandbox SHALL refuse to dispatch any call whose target is the vault, the withdrawal queue, the governor, the tier registry, the exposure ledger, the WOOD token or the staked-WOOD token, reverting rather than skipping.

The adversary is not fund theft — the funded cap already bounds that — but protocol accounting: a sandbox holding vault capital could otherwise deposit it back into the vault to mint shares while an open proposal has deposits locked, stamp or queue against the withdrawal queue, or move stake in the guardian system, corrupting figures other guards assume only the vault itself can move.

#### Scenario: Calling the vault is refused
- **WHEN** a stored call targets the vault
- **THEN** execution SHALL revert with a distinct error naming the refused target

#### Scenario: Refusal is a revert, not a silent skip
- **WHEN** a stored call set contains one denied target among otherwise valid calls
- **THEN** the whole execution SHALL revert — no call in the set SHALL take effect

### Requirement: Settlement returns everything and reports what it cannot value
At settlement a sandbox SHALL transfer its entire vault-asset balance back to the vault and SHALL report any remaining value it holds through the strategy-delivery interface the vault's residue machinery reads.

A sandbox can end holding a token it has no means to value, because the calls that acquired it were proposer-authored. The proposer SHALL declare, when the proposal is created, the set of tokens the sandbox may come to hold; the sandbox SHALL report unvalued residue whenever it holds a non-zero balance of any declared token other than the vault asset, which locks deposits until the residue is cleared. This liveness cost is intended and is the honest reading of "the vault cannot price what it owns."

A contract cannot enumerate every token it holds, so the declared set is what makes the report checkable rather than a constant. An under-declared leftover SHALL be stranded in the sandbox and SHALL NOT be counted as vault value — the safe direction of error, and the proposer's own loss rather than the vault's.

The lock SHALL have an exit that no one can withhold. Residue collection SHALL therefore also push each declared non-asset token to the vault, and a declared token that proves unmovable — a transfer attempt that fails — SHALL stop being counted. Without both, the lock is permanent: nothing else can move a token out of a sandbox whose one-shot run is already spent, so a proposer could shut minting forever by declaring a token its payload leaves behind, or one whose transfer always reverts. An abandoned token is stranded exactly as an undeclared one is, which is a loss already accepted; a deposit brick nobody can clear is not.

Abandonment SHALL require the transfer failure to persist. Collection is permissionless, so a single failed attempt is a moment someone else chose: a token that is merely paused or temporarily restricted would otherwise be written off by anyone who called at the right time, and the vault would then price mints as though value it still holds were gone. A token SHALL therefore only be abandoned once its transfer has been observed failing across a delay, and the mark SHALL be cleared if the token ever transfers successfully. The cost — a genuinely unmovable token holds the lock for that delay rather than clearing on the first attempt — is bounded and self-clearing, which is the trade the deposit gate already makes everywhere else.

Both residue reads run on gas BORROWED from the vault, and the declared set is proposer-authored, so each entry SHALL be bounded by a share of the budget actually remaining rather than by a fixed per-entry ceiling alone. A fixed ceiling does not bound a loop: entries at the ceiling exceed what the caller lent, and an entry that consumes what the entries behind it need makes the whole read revert. That failure is silent in the direction that matters — the vault treats an unreadable residue probe as "keep the last known flag", so a payload could latch the deposit lock on and then make it unclearable, and a collection sweep could run out before returning the asset. Every declared-token loop SHALL therefore terminate and return an answer regardless of how any single entry behaves.

The declared set SHALL contain no duplicates, and that SHALL be enforced when the proposal is created rather than only when the sandbox is minted: a rule enforced only at execution kills a proposal that has already cleared the vote and the review period, with the proposer's bond locked and no way to amend it.

#### Scenario: Asset balance returns in full
- **WHEN** a sandbox settles holding a vault-asset balance
- **THEN** the entire balance SHALL be transferred to the vault and its reported undelivered value SHALL become zero

#### Scenario: A declared leftover locks deposits
- **WHEN** a sandbox holds a non-zero balance of a declared token other than the vault asset after settling
- **THEN** it SHALL report unvalued residue, and the vault SHALL refuse deposits until the residue is cleared

#### Scenario: An undeclared leftover is stranded, never counted
- **WHEN** a sandbox holds a token the proposer did not declare
- **THEN** the balance SHALL NOT be reported as vault value and SHALL NOT be included in any deposit price — it is stranded in the sandbox

#### Scenario: The declared-leftover lock always has an exit
- **WHEN** residue collection is called against a sandbox holding a declared non-asset token
- **THEN** the token SHALL be pushed to the vault, or — if it proves unmovable across the abandonment delay — abandoned and no longer counted, and deposits SHALL reopen in either case

#### Scenario: A transiently unmovable token is not written off
- **WHEN** a declared token's transfer fails once and then succeeds before the abandonment delay elapses
- **THEN** the token SHALL NOT be abandoned, and its balance SHALL be recovered to the vault rather than stranded

#### Scenario: A gas-hostile declared token cannot freeze the residue report
- **WHEN** a declared token consumes every drop of gas offered to it while other declared tokens remain to be read
- **THEN** the residue report SHALL still return an answer, and the deposit lock SHALL remain clearable

#### Scenario: A gas-hostile declared token cannot strand the funded capital
- **WHEN** residue collection is called against a sandbox whose declared set is full of gas-consuming tokens
- **THEN** the vault-asset balance SHALL still be returned to the vault in full

#### Scenario: A duplicated declared token is refused at propose
- **WHEN** a proposal declares the same token more than once
- **THEN** it SHALL be rejected when the proposal is created, not when the sandbox is minted

#### Scenario: Recovery does not depend on the batch
- **WHEN** the vault's permissionless residue collection is called against a sandbox
- **THEN** it SHALL recover the asset balance by a direct call, without requiring a governor batch or any owner action

### Requirement: The call set is fixed at propose time and readable before approval
The calls a sandbox will dispatch, the funding amount, and the declared token set SHALL be recorded when the proposal is created, SHALL NOT be alterable afterwards by anyone, and SHALL be readable on-chain in full for the whole review period.

The adversary is the proposer themselves: a mutable call set would let a proposal be reviewed, approved and covered against one payload and executed against another, defeating the guardian review the coverage quorum exists to obtain. Readability is the other half — a review the reviewer cannot perform is not a gate.

#### Scenario: Calls cannot be rewritten after propose
- **WHEN** anyone attempts to change the stored call set, funding amount or declared token set after the proposal is created
- **THEN** the attempt SHALL revert

#### Scenario: Reviewers can read the exact call set
- **WHEN** a guardian inspects a proposal during the review period
- **THEN** the full stored call set, funding amount and declared token set SHALL be readable on-chain before the approval decision
