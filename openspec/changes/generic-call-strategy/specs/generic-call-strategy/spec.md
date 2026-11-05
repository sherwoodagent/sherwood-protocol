## ADDED Requirements

### Requirement: The generic-call plan is fixed at initialize

`GenericCallStrategy._initialize` SHALL decode `abi.encode(uint256 pullAmount, Call[] executeCalls, Call[] settleCalls, address[] sweepTokens)`, where `Call` is `BatchExecutorLib.Call (address target, bytes data, uint256 value)`, and store it for the clone's life. `_updateParams` SHALL always revert `NoTunableParams()`. The clone SHALL expose `configHash()` equal to `keccak256(abi.encode(pullAmount, executeCalls, settleCalls, sweepTokens))` over the decoded values.

ADVERSARY: a proposer who could change targets, calldata, the pull or the sweep list after the guardian vote would execute a plan nobody reviewed.

`_initialize` SHALL revert `TooManyCalls(leg)` when a leg holds more than 16 calls, `CalldataTooLarge(leg)` when a leg's summed calldata exceeds 16,384 bytes, `TooManySweepTokens()` above 16 sweep tokens, and `ZeroAddress()` for a zero sweep token. Empty legs and `pullAmount == 0` SHALL be accepted.

#### Scenario: Proposer tries to retune after execute
- **GIVEN** an executed generic-call clone
- **WHEN** its proposer calls `updateParams` with any data
- **THEN** the call reverts `NoTunableParams()` and every getter returns what it returned before

#### Scenario: Oversized leg refused
- **WHEN** a clone is initialized with 17 execute calls, or with settle calldata summing to more than 16,384 bytes
- **THEN** initialization reverts `TooManyCalls(leg)` or `CalldataTooLarge(leg)` and no clone state is written

#### Scenario: Config hash is canonical
- **WHEN** a guardian re-encodes the values the getters return and hashes them
- **THEN** the result equals `configHash()`

### Requirement: Every call target is checked at initialize

For every call in both legs `_initialize` SHALL revert:

- `NativeValueUnsupported(leg, index)` when `value != 0`;
- `ForbiddenTarget(leg, index, target)` when `target` is zero, the clone, the vault, the vault's governor, the vault's SyndicateFactory (`vault.factory()`), the governor's TierRegistry or that registry's StrategyFactory;
- `TargetHasNoCode(leg, index, target)` when `target` has no code;
- `AssetCallNotAllowed(leg, index, selector)` when `target` is the vault asset and the selector is not `approve(address,uint256)` or `transfer(address,uint256)`, or the calldata is shorter than 68 bytes.

The protocol addresses SHALL be resolved through raw length-checked staticcalls (`vault.governor()`, `vault.factory()`, `governor.tierRegistry()`, `tierRegistry.strategyFactory()`), and any hop that does not answer a clean address SHALL revert `ProtocolAddressUnresolved()`. The clone SHALL make every forwarded call with `call`, never `delegatecall`, and SHALL have no `receive` or `fallback`.

ADVERSARY (asset rule): inside the execute batch the vault's allowance to the clone is live until the batch ends. A clone allowed `transferFrom(vault, …)` or a token extension such as `transferFromBatch` on the asset could spend that allowance beyond `pullAmount`. With only `approve` and `transfer`, both bounded by the clone's own balance, the most the clone can lose is `pullAmount`.

ADVERSARY (denylist): the clone touching the lifecycle contracts directly. None grants the clone a privilege, but the list keeps a guardian from having to prove it per proposal.

#### Scenario: Vault allowance cannot be widened
- **WHEN** a clone is initialized with an execute call `asset.transferFrom(vault, attacker, n)`
- **THEN** initialization reverts `AssetCallNotAllowed(0, index, transferFrom.selector)`

#### Scenario: Lifecycle contract as a target
- **WHEN** a call in either leg targets the vault, the governor, the SyndicateFactory, the TierRegistry, the StrategyFactory, the clone itself or the zero address
- **THEN** initialization reverts `ForbiddenTarget(leg, index, target)`

#### Scenario: Native value refused
- **WHEN** a call carries `value = 1`
- **THEN** initialization reverts `NativeValueUnsupported(leg, index)`

#### Scenario: Codeless target refused
- **WHEN** a call targets an address with no code
- **THEN** initialization reverts `TargetHasNoCode(leg, index, target)`

### Requirement: Target code is pinned at initialize and re-checked at execute only

`_initialize` SHALL record `pinnedCodehash(target) = target.codehash` for every target. `_execute` SHALL, before pulling any capital, revert `TargetCodeChanged(target)` when any target of either leg no longer has its pinned codehash. `_settle` SHALL NOT re-check codehashes.

ADVERSARY: a target whose code changes between the guardian review and execution (a redeploy at the same address, a changed EIP-7702 delegation) runs code nobody reviewed. A refused execute is recoverable; a refused settle would wedge the proposal in `Executed`, so settle does not check. A proxy whose implementation is swapped keeps its codehash and is NOT covered; that is a review-time judgement.

#### Scenario: Target code changed before execute
- **GIVEN** a clone whose settle-leg target's code was replaced after initialize
- **WHEN** the proposal's execute batch calls `execute()`
- **THEN** the call reverts `TargetCodeChanged(target)` and no asset leaves the vault

#### Scenario: Target code changed between execute and settle
- **GIVEN** an executed clone whose settle-leg target's code was then replaced
- **WHEN** the settle batch calls `settle()`
- **THEN** no codehash check runs and the settle leg executes against the current code

### Requirement: Execute pulls, runs the execute leg and revokes grants

`_execute` SHALL, after the codehash check, pull `pullAmount` of the vault asset with `_pullFromVault` (skipped when zero), run the execute leg in order, and then revoke grants. A call that fails SHALL revert `CallFailed(leg, index, reason)` with the callee's revert data as `reason`.

#### Scenario: Happy path through a real vault and governor
- **WHEN** a proposal with execute batch `[asset.approve(clone, pullAmount), clone.execute()]` executes
- **THEN** the clone holds the venue position, the vault's asset dropped by `pullAmount`, and no allowance granted in the execute leg is still open

#### Scenario: Failed inner call bubbles
- **WHEN** an execute-leg call reverts with error data `E`
- **THEN** `execute()` reverts `CallFailed(0, index, E)` and the whole batch reverts

### Requirement: Settle runs the settle leg, revokes grants and returns custody

`_settle` SHALL run the settle leg in order (a failing call reverts `CallFailed(1, index, reason)`), revoke grants, push the clone's whole asset balance to the vault, and push the clone's whole balance of each declared sweep token to the vault. The template SHALL NOT impose its own minimum-return floor: the governor's `maxDrawdownBps` floor in `settleProposal` is the price check.

Settlement P&L counts only the vault asset. Sweep tokens and ERC-721s returned to the vault, and anything left on the clone, SHALL be documented as a realised loss for that proposal.

#### Scenario: Settle returns the asset and sweep tokens
- **GIVEN** an executed clone holding asset `A` and sweep token `T`
- **WHEN** the settle batch `[clone.settle()]` runs
- **THEN** the vault receives all of `A` and all of `T`, the clone holds neither, and the clone's state is `Settled`

#### Scenario: Empty settle leg
- **WHEN** a clone with no settle calls is settled
- **THEN** it pushes its asset balance and sweep balances to the vault and settles

### Requirement: Approval revocation is best-effort over two named selectors

`_initialize` SHALL record a grant for every call in either leg whose selector is `approve(address,uint256)` with at least 68 bytes of calldata, as `(target, spender)`, and for every call whose selector is `setApprovalForAll(address,bool)` with at least 68 bytes, as `(target, operator)`. After each leg the clone SHALL revoke each recorded grant that a live read reports open: `allowance(this, spender) != 0` leads to `approve(spender, 0)`, and `isApprovedForAll(this, operator) == true` leads to `setApprovalForAll(operator, false)`. A read that does not return exactly one word SHALL skip the grant, and a failed revoke call SHALL be ignored. `grants()` SHALL return the recorded list.

ADVERSARY: a venue keeping an approval over tokens the clone holds between execute and settle. Revocation is hygiene, not the bound: the clone only holds what it pulled, and settle pushes the asset and every declared token home. Other grant shapes (Permit2, `increaseAllowance`, ERC-777 operators) are NOT revoked and are left to the guardian review.

#### Scenario: Execute-leg approval revoked before settle
- **WHEN** the execute leg calls `asset.approve(venue, x)` and the venue pulls less than `x`
- **THEN** after `execute()` returns, `asset.allowance(clone, venue) == 0`

#### Scenario: Operator approval revoked
- **WHEN** a leg calls `nft.setApprovalForAll(market, true)`
- **THEN** after that leg `nft.isApprovedForAll(clone, market)` is false

#### Scenario: Selector collision does not wedge
- **WHEN** a leg calls an ERC-721's `approve(to, tokenId)`, which shares the ERC-20 selector
- **THEN** the revoke step's `allowance` read fails, the grant is skipped and the leg completes

### Requirement: Recovery hooks reach every asset the clone can hold

The clone SHALL keep `BaseStrategy.rescueTo(token)` for ERC-20s and SHALL add `rescueERC721To(address token, uint256 tokenId)`, `onlyVault`, callable in any state, which moves the token with `transferFrom(address(this), vault, tokenId)`. The clone SHALL implement `onERC721Received` returning its selector and SHALL NOT implement ERC-1155 receiver hooks.

ADVERSARY: an execute that lands an NFT, followed by a settle leg that can no longer sell it. Without a vault-only NFT exit the NFT is stranded on the clone forever, because the emergency path can only call registered strategies and the asset. An ERC-1155 the clone held could never reach the vault (no receiver hook there, no non-safe transfer), so refusing receipt keeps that failure at execute.

#### Scenario: NFT rescued by an emergency batch
- **GIVEN** an executed clone holding an ERC-721 whose settle leg reverts
- **WHEN** the owner's emergency batch calls `clone.rescueERC721To(nft, id)`
- **THEN** the vault owns the NFT

#### Scenario: Only the vault rescues
- **WHEN** any address other than the vault calls `rescueERC721To`
- **THEN** the call reverts `NotVault()`

### Requirement: The template is tier 2 and never certified

The generic-call template and its clones SHALL NOT be certified at tier 0 or 1, by address or by class: it is an arbitrary-call forwarder whose destinations are set by calldata, the surface `docs/adapter-onboarding-checklist.md` §2.1 refuses. Its calls SHALL therefore price at `(2, 10_000)` and need full-notional coverage. Its documentation SHALL state that it is outside the audit scope and offered at the syndicate's own risk, and SHALL list what a guardian checks: provenance (`StrategyFactory.cloneTemplate(clone)` equals the book's `GENERIC_CALL_TEMPLATE`), the two batch shapes, every inner call, and a simulation of both batches.

#### Scenario: A clone prices at full notional
- **WHEN** a proposal's execute batch calls a generic-call clone's `execute()` with cap `c`
- **THEN** `tierOf(clone, execute.selector)` is `(2, 10_000)` and the call contributes `c` to required coverage
