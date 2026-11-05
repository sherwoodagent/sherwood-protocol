## ADDED Requirements

### Requirement: The generic-call plan is fixed at initialize

`GenericCallStrategy._initialize` SHALL decode `abi.encode(uint256 pullAmount, Call[] executeCalls, Call[] settleCalls, BalancePatch[] settlePatches, address[] sweepTokens)`, where `Call` is `BatchExecutorLib.Call (address target, bytes data, uint256 value)` and `BalancePatch` is `(uint256 callIndex, uint256 wordIndex, address token)`, and store it for the clone's life. `_updateParams` SHALL always revert `NoTunableParams()`. The clone SHALL expose `configHash()` equal to `keccak256(abi.encode(pullAmount, executeCalls, settleCalls, settlePatches, sweepTokens))` over the decoded values.

ADVERSARY: a proposer who could change targets, calldata, the pull, the patches or the sweep list after the guardian vote would execute a plan nobody reviewed.

`_initialize` SHALL revert `TooManyCalls(leg)` when a leg holds more than 16 calls, `CalldataTooLarge(leg)` when a leg's summed calldata exceeds 16,384 bytes, `TooManySweepTokens()` above 16 sweep tokens, and `InvalidSweepToken(index)` for a sweep token that has no code or is a denied contract (the target denylist, including zero). Empty legs and `pullAmount == 0` SHALL be accepted.

#### Scenario: Proposer tries to retune after execute
- **GIVEN** an executed generic-call clone
- **WHEN** its proposer calls `updateParams` with any data
- **THEN** the call reverts `NoTunableParams()` and every getter returns what it returned before

#### Scenario: Oversized leg refused
- **WHEN** a clone is initialized with 17 execute calls, or with settle calldata summing to more than 16,384 bytes
- **THEN** initialization reverts `TooManyCalls(leg)` or `CalldataTooLarge(leg)` and no clone state is written

#### Scenario: Unusable sweep token refused
- **WHEN** a sweep token is zero, has no code, or is the vault
- **THEN** initialization reverts `InvalidSweepToken(index)`

#### Scenario: Config hash is canonical
- **WHEN** a guardian re-encodes the values the getters return and hashes them
- **THEN** the result equals `configHash()`

### Requirement: Every call target is checked at initialize

For every call in both legs `_initialize` SHALL revert:

- `NativeValueUnsupported(leg, index)` when `value != 0`;
- `ForbiddenTarget(leg, index, target)` when `target` is zero, the clone, the vault, the vault's governor, the vault's SyndicateFactory (`vault.factory()`), the governor's TierRegistry, that registry's StrategyFactory, the governor's GuardianRegistry, that registry's sWOOD, or (when set) the vault's withdrawal queue, the governor's ExposureLedger or that ledger's ChallengeGame (`coverageFreezer()`);
- `TargetHasNoCode(leg, index, target)` when `target` has no code;
- `AssetCallNotAllowed(leg, index, selector)` when `target` is the vault asset and the selector is not `approve(address,uint256)` or `transfer(address,uint256)`, or the calldata is shorter than 68 bytes.

The protocol addresses SHALL be resolved through raw length-checked staticcalls (`vault.governor()`, `vault.factory()`, `governor.tierRegistry()`, `tierRegistry.strategyFactory()`, `governor.guardianRegistry()`, `guardianRegistry.swood()`), and any of those hops that does not answer a clean address SHALL revert `ProtocolAddressUnresolved()`. `vault.withdrawalQueue()`, `governor.exposureLedger()` and `exposureLedger.coverageFreezer()` MAY be unset; a zero read denies nothing extra. WOOD SHALL NOT be denied: denying it would only strand WOOD a clone bought through a venue. The clone SHALL make every forwarded call with `call`, never `delegatecall`, and SHALL have no `receive` or `fallback`.

ADVERSARY (asset rule): inside the execute batch the vault's allowance to the clone is live until the batch ends. A clone allowed `transferFrom(vault, …)` or a token extension such as `transferFromBatch` on the asset could spend that allowance beyond `pullAmount`. With only `approve` and `transfer`, both bounded by the clone's own balance, the most the clone can lose is `pullAmount`.

ADVERSARY (denylist): the clone touching the lifecycle contracts directly, queueing vault shares through the withdrawal queue, staking through sWOOD or the GuardianRegistry with vault capital mid-proposal, or filing a ChallengeGame challenge with WOOD it holds and burning the bond. None grants the clone a privilege today, but the list keeps a guardian from having to prove it per proposal.

#### Scenario: Vault allowance cannot be widened
- **WHEN** a clone is initialized with an execute call `asset.transferFrom(vault, attacker, n)`
- **THEN** initialization reverts `AssetCallNotAllowed(0, index, transferFrom.selector)`

#### Scenario: Lifecycle contract as a target
- **WHEN** a call in either leg targets the vault, the governor, the SyndicateFactory, the TierRegistry, the StrategyFactory, the GuardianRegistry, sWOOD, the withdrawal queue, the ExposureLedger, the ChallengeGame, the clone itself or the zero address
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

`_settle` SHALL run the settle leg in order (a failing call reverts `CallFailed(1, index, reason)`), revoke grants, push the clone's whole asset balance to the vault (a failure reverts), and then try to push the clone's whole balance of each declared sweep token to the vault. A sweep SHALL be best-effort: a balance read that fails or does not return one word counts as zero and is skipped, and a transfer that fails SHALL emit `SweepFailed(token)` and leave the token on the clone. The template SHALL NOT impose its own minimum-return floor: the governor's `maxDrawdownBps` floor in `settleProposal` is the price check.

Settlement P&L counts only the vault asset. Sweep tokens and ERC-721s returned to the vault, and anything left on the clone, SHALL be documented as a realised loss for that proposal.

ADVERSARY (sweeps): a sweep token that reverts, burns gas or loses its code after the vote. A strict sweep would wedge the asset's return behind it.

#### Scenario: Settle returns the asset and sweep tokens
- **GIVEN** an executed clone holding asset `A` and sweep token `T`
- **WHEN** the settle batch `[clone.settle()]` runs
- **THEN** the vault receives all of `A` and all of `T`, the clone holds neither, and the clone's state is `Settled`

#### Scenario: A broken sweep token does not block the asset
- **GIVEN** an executed clone whose sweep token's `transfer` reverts, and another sweep token whose code is gone
- **WHEN** the settle batch runs
- **THEN** the vault receives the asset, `SweepFailed(token)` is emitted for the reverting token, the codeless one is skipped, and the clone is `Settled`

#### Scenario: Empty settle leg
- **WHEN** a clone with no settle calls is settled
- **THEN** it pushes its asset balance and sweep balances to the vault and settles

### Requirement: Settle calls may take the clone's live balance as an argument

A `BalancePatch(callIndex, wordIndex, token)` SHALL make `_settle`, immediately before settle call `callIndex` runs, overwrite the 32-byte word at calldata offset `4 + 32 * wordIndex` with `IERC20(token).balanceOf(address(this))` read at that moment. Patches SHALL apply to the settle leg only. `_initialize` SHALL revert `InvalidPatch(patchIndex)` when `callIndex` is outside the settle leg, when a second patch names the same call, when the word does not lie wholly inside that call's calldata, when `token` is not already in the plan (the vault asset, a target of either leg, or a sweep token), or when the patch targets an address word: word 0 of `approve(address,uint256)`, `setApprovalForAll(address,bool)` or `transfer(address,uint256)`, or word 0 or 1 of `transferFrom(address,address,uint256)`, `safeTransferFrom(address,address,uint256)` or `safeTransferFrom(address,address,uint256,bytes)`. `settlePatches()` SHALL return the stored patches.

ADVERSARY: a settle leg sized at init cannot unwind a position whose size is only known after execute (shares, LP tokens, a market-price buy). The position is stranded and settlement, which counts only the vault asset, books it as a total loss. The patched amount is the clone's own balance, so it can never move more than the clone holds. A balance written into an address word aims the call at whatever address the number spells, and anyone can move a token balance after the vote; word 0 of an approve is also the spender the revocation step recorded. Restricting the token to the plan means a patch adds no contract the guardian has not already reviewed.

#### Scenario: Market-price buy is sold whole at settle
- **GIVEN** an execute leg that buys a token at a price unknown at init, and a settle sell call patched with that token's balance
- **WHEN** the settle batch runs
- **THEN** the sell call receives the clone's whole balance of the token and the clone holds none of it afterwards

#### Scenario: Patch outside the calldata refused
- **WHEN** a patch names a word past the end of its call's calldata, a call index outside the settle leg, or a second patch on the same call
- **THEN** initialization reverts `InvalidPatch(patchIndex)`

#### Scenario: Address words cannot be patched
- **WHEN** a patch names word 0 of a settle-leg `approve`, `setApprovalForAll` or `transfer`, or word 0 or 1 of a `transferFrom` or `safeTransferFrom`
- **THEN** initialization reverts `InvalidPatch(patchIndex)`

#### Scenario: Patch token outside the plan refused
- **WHEN** a patch names a token that is not the asset, a leg target or a sweep token
- **THEN** initialization reverts `InvalidPatch(patchIndex)`

### Requirement: Approval revocation is best-effort over two named selectors

`_initialize` SHALL record a grant for every call in either leg whose selector is `approve(address,uint256)` with at least 68 bytes of calldata, as `(target, spender)`, and for every call whose selector is `setApprovalForAll(address,bool)` with at least 68 bytes, as `(target, operator)`. After each leg the clone SHALL revoke each recorded grant that a live read reports open: `allowance(this, spender) != 0` leads to `approve(spender, 0)`, and `isApprovedForAll(this, operator) == true` leads to `setApprovalForAll(operator, false)`. A read that does not return exactly one word SHALL skip the grant, and a failed revoke call SHALL emit `RevokeFailed(token, spender)` and be ignored. Each read and each revoke call SHALL be made with at most 100,000 gas. `grants()` SHALL return the recorded list.

ADVERSARY: a venue keeping an approval over tokens the clone holds between execute and settle. Revocation is hygiene, not the bound: the clone only holds what it pulled, and settle pushes the asset and every declared token home. Other grant shapes (Permit2, `increaseAllowance`, ERC-777 operators) are NOT revoked and are left to the guardian review.

#### Scenario: Execute-leg approval revoked before settle
- **WHEN** the execute leg calls `asset.approve(venue, x)` and the venue pulls less than `x`
- **THEN** after `execute()` returns, `asset.allowance(clone, venue) == 0`

#### Scenario: Operator approval revoked
- **WHEN** a leg calls `nft.setApprovalForAll(market, true)`
- **THEN** after that leg `nft.isApprovedForAll(clone, market)` is false

#### Scenario: A gas-burning token cannot starve the settle
- **WHEN** a granted token burns all gas it is given on the `allowance` read or on the revoke
- **THEN** that read or revoke fails after 100,000 gas and the settle completes

#### Scenario: Selector collision does not wedge
- **WHEN** a leg calls an ERC-721's `approve(to, tokenId)`, which shares the ERC-20 selector
- **THEN** the revoke step's `allowance` read fails, the grant is skipped and the leg completes

### Requirement: Recovery hooks reach every asset the clone can hold

The clone SHALL keep `BaseStrategy.rescueTo(token)` for ERC-20s and SHALL add `rescueERC721To(address token, uint256 tokenId)`, `onlyVault`, callable in any state, which moves the token with `transferFrom(address(this), vault, tokenId)`. The clone SHALL implement `onERC721Received` returning its selector and SHALL NOT implement ERC-1155 receiver hooks.

ADVERSARY: an execute that lands an NFT, followed by a settle leg that can no longer sell it. Without a vault-only NFT exit the NFT is stranded on the clone forever, because the emergency path can only call registered strategies and the asset. An ERC-1155 the clone held could never reach the vault (no receiver hook there, no non-safe transfer), so refusing receipt keeps that failure at execute.

These hooks reach only what the clone holds. The documentation SHALL state that a position recorded inside a venue whose settle leg can never succeed is a realised loss, and SHALL tell guardians to prefer venues that issue the clone a token.

#### Scenario: NFT rescued by an emergency batch
- **GIVEN** an executed clone holding an ERC-721 whose settle leg reverts
- **WHEN** the owner's emergency batch calls `clone.rescueERC721To(nft, id)`
- **THEN** the vault owns the NFT

#### Scenario: A venue-held position is lost when the settle leg cannot run
- **GIVEN** an executed clone that holds part of its pull and deposited the rest into a venue that now refuses every withdrawal
- **WHEN** `settleProposal` and `unstick` run, and then the owner's emergency batch calls `clone.rescueTo(asset)`
- **THEN** both replays revert `CallFailed(1, 0, reason)`, the emergency batch returns only the part the clone held, the venue still holds the rest, and the proposal ends `Settled`

#### Scenario: Only the vault rescues
- **WHEN** any address other than the vault calls `rescueERC721To`
- **THEN** the call reverts `NotVault()`

### Requirement: The template is tier 2 and never certified

The generic-call template and its clones SHALL NOT be certified at tier 0 or 1, by address or by class: it is an arbitrary-call forwarder whose destinations are set by calldata, the surface `docs/adapter-onboarding-checklist.md` §2.1 refuses. Its calls SHALL therefore price at `(2, 10_000)` and need full-notional coverage. Its documentation SHALL state that it is outside the audit scope and offered at the syndicate's own risk, and SHALL list what a guardian checks: provenance (`StrategyFactory.cloneTemplate(clone)` equals the book's `GENERIC_CALL_TEMPLATE`), the two batch shapes, that the approve amount equals `pullAmount` and `pullAmount` is at most the cap on `clone.execute()` (nothing on chain ties them), every inner call, and a simulation of both batches.

#### Scenario: A clone prices at full notional
- **WHEN** a proposal's execute batch calls a generic-call clone's `execute()` with cap `c`
- **THEN** `tierOf(clone, execute.selector)` is `(2, 10_000)` and the call contributes `c` to required coverage
