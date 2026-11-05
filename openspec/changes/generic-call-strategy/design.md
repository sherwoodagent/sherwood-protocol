## Context

Batches run under `delegatecall`, so every sub-call reaches its target with `msg.sender == vault`. `structural-batch-rules` (archived 2026-10-02) made the batch guard four structural rules: a non-asset target must be a registered strategy; an asset call is a metered transfer or an approve-family call whose spender is reset after the batch; the meters run last. Its design (D3) recorded the intent this change serves: anyone can write a strategy, and a proposal may call any contract with any calldata, but only through strategy code. A `vault() == this` callee predicate was rejected there and is not revived here.

`registerStrategy` is permissionless, so a hand-written forwarder can already reach any venue. This change ships one such forwarder as a Sherwood template. It adds no protocol surface: the vault, governor, factory and registry are unchanged. It adds a recognisable shape (`StrategyFactory.cloneTemplate(clone) == GENERIC_CALL_TEMPLATE`), fixed getters for guardians, and removes the Solidity step for agents.

The open change `permissionless-tier2-sandbox` (not implemented on `post-audit-v2`) pursued the same goal with a vault-minted sandbox and vault/governor changes. This template reaches the same structural max-loss property (the clone holds only what it pulled) without touching the core. This change neither edits nor retires that change.

## Goals / Non-Goals

- Goals: an agent reaches any venue by encoding call lists; the clone's maximum loss is `pullAmount` by construction; everything a guardian votes on is fixed at `initialize` and readable on-chain; the clone fits the existing batch shape `[asset.approve(clone, cap), clone.execute()]` / `[clone.settle()]`.
- Non-Goals: no change to `_guardBatchCalls`, `_mirrorBatchLeg`, `StrategyFactory`, `TierRegistry`, `BaseStrategy` or the governor; no deploy, no `setTemplateApproval`, no address-book entry; no tier 0/1 certification, ever; no native value; no dynamic calldata (live-balance substitution) in this version; no ERC-1155 custody.

## Decisions

### D1 — Init data, fixed for the clone's life

`abi.encode(uint256 pullAmount, Call[] executeCalls, Call[] settleCalls, address[] sweepTokens)`, with `Call` the existing `BatchExecutorLib.Call` `(address target, bytes data, uint256 value)`. Reusing the batch struct means the SDK's `BatchCall` type and the CLI's batch encoders/decoders apply unchanged.

- `value` must be zero (`NativeValueUnsupported`). The vault holds USDG, never native; the clone has no `receive`/`fallback`, so a venue cannot refund native to it either.
- `pullAmount` may be zero: `_execute` then skips `_pullFromVault` (some tokens revert a zero `transferFrom`). A zero-pull clone sells tokens the owner moved onto it with `SyndicateVault.rescueERC20`, which only pays clones of that vault.
- Legs may be empty. An empty settle leg still pushes the asset and sweep tokens home.
- `_updateParams` always reverts `NoTunableParams`. Calls, targets, the pull and the sweep list are what guardians approve; a proposer who could edit them after the vote would void the review. No non-call parameter is tunable either: the only candidate, a minimum asset return, is dropped (D6).
- `configHash = keccak256(abi.encode(pullAmount, executeCalls, settleCalls, sweepTokens))` over the decoded values, so a non-canonical encoding of the same config hashes the same. A proposer can cite it in `metadataURI`; a guardian recomputes it from the getters.

Caps, to bound the template's own overhead (storage reads per call, loop length): at most 16 calls per leg, at most 16,384 bytes of calldata summed per leg, at most 16 sweep tokens. These do not bound a venue's own gas (D8).

### D2 — Target rules, checked at `initialize`

For every call in both legs:

1. `target` is not zero, not `address(this)`, not the vault, not the governor (`vault.governor()`), not the SyndicateFactory (`vault.factory()`), not the TierRegistry (`governor.tierRegistry()`), not the StrategyFactory (`tierRegistry.strategyFactory()`). Each hop is a raw length-checked staticcall; a hop that does not resolve reverts `ProtocolAddressUnresolved` (fail-closed: a clone that cannot name the protocol around it refuses to exist, and `execute()` needs the governor anyway).
2. `target.code.length != 0` (`TargetHasNoCode`): a call to a codeless address succeeds and does nothing, so a typo'd router would "execute" with the capital idle on the clone.
3. On the vault asset, the selector is `approve(address,uint256)` or `transfer(address,uint256)` and nothing else (`AssetCallNotAllowed`).
4. `pinnedCodehash[target] = target.codehash` is recorded (D4).

None of the denied contracts grants the clone a privilege: the clone is not an agent, not the vault and not the governor, and the lifecycle entry points are reentrancy-locked while a batch runs (D7). The denylist exists so a guardian never has to reason about the clone touching the lifecycle directly. A venue can still call those contracts with its own identity; that confers nothing a stranger lacks. The list is read once at `initialize`: a later re-pointing of these addresses is an owner action, not an adversary.

### D3 — The asset rule is the load-bearing control

Inside the execute batch the vault's allowance to the clone (`asset.approve(clone, cap)`) is live until `executeGovernorBatch` resets it after the delegatecall. The clone pulls `pullAmount` itself. If the clone could call `asset.transferFrom(vault, x, n)` or any token-specific extension (Paxos `transferFromBatch`, the V1-01 shape), it could spend the rest of that allowance. Rule D2.3 forbids every asset selector except `approve` and `transfer`, both bounded by the clone's own balance. The vault approves only its asset (`AssetCallRules`), so the clone reaches no other vault-held token. Together: the most the clone can lose is `pullAmount`, whatever its calls do. `pullAmount` itself is bounded by the batch's per-call cap on `clone.execute()` and the proposal's `maxCapital`.

### D4 — Codehash pinning: what it covers

Each target's codehash is pinned at `initialize` and re-checked for every call of BOTH legs at the start of `execute()` (`TargetCodeChanged`). A refused execute is recoverable (the proposal expires, the agent re-proposes). `settle()` does not re-check: a code change between execute and settle would otherwise wedge the proposal in `Executed`, and settle is where capital comes home.

Covered: code at a target address changing between review and execute (redeploy at the same address, an EIP-7702 delegation change). Not covered: a proxy whose implementation is swapped (the proxy's own code is unchanged), owner-settable venue parameters, venue state. Same position as `structural-batch-rules` D2: proxy swaps are a review-time judgement, not an on-chain check. Pinning is per target; the clone's own registration pin is per strategy (`StrategyFactory.registeredCodehash`) and covers only the clone.

### D5 — Execute

```
_execute():
  require every pinned codehash (both legs)
  if pullAmount != 0: _pullFromVault(asset, pullAmount)
  run execute leg      // call only, never delegatecall
  revoke grants (D7)
```

A failed call reverts `CallFailed(uint8 leg, uint256 index, bytes reason)` carrying the venue's revert data verbatim: the index tells an agent which call broke, the data keeps the venue error decodable. `BaseStrategy.execute` has already set `Executed` and checked the active-proposal binding before `_execute` runs.

### D6 — Settle and value accounting

```
_settle():
  run settle leg
  revoke grants (D7)
  _pushAllToVault(asset)
  for t in sweepTokens: _pushAllToVault(t)
```

Settlement counts only the vault asset: `_finishSettlement` measures `asset.balanceOf(vault)` against the execute snapshot. Anything the clone returns in another token, and anything left on the clone, is a realised loss in the proposal's P&L. Sweep tokens land in the vault, outside the share price; the owner can move them to a clone of that vault with `rescueERC20` for a later proposal to sell. ERC-721s returned to the vault are NAV-zero the same way.

No template-level minimum return. `settleProposal` already refuses a settle whose price per share is below the proposer-declared `maxDrawdownBps` floor (`_requireSettlePriceAboveFloorHook`); a second, USDG-denominated floor on the clone would be a duplicate knob guardians must reconcile, with the same wedge-on-miss behaviour. Venue-level bounds (a router's `amountOutMin`) live in the settle calldata.

A sweep token that reverts on `balanceOf` or `transfer` reverts the settle; the list is fixed and reviewed, and the emergency path (D9) recovers.

### D7 — Approval revocation is best-effort and names two selectors

At `initialize` the template records a grant for every call (either leg) whose selector is `approve(address,uint256)` (`0x095ea7b3`, data ≥ 68 bytes) as `(target, spender)`, and every call whose selector is `setApprovalForAll(address,bool)` (`0xa22cb465`) as `(target, operator)`. After each leg it revokes each grant whose live read says it is open: `allowance(this, spender) != 0` → `approve(spender, 0)`; `isApprovedForAll(this, operator)` → `setApprovalForAll(operator, false)`. A read that does not answer one word (an ERC-721 `approve(to, tokenId)` shares the selector but has no `allowance`) skips the grant; a revoke call that fails is ignored. Revocation must never wedge settle.

Consequence: an approval the settle leg needs must be granted in the settle leg. Not recognised: Permit2 approvals, `increaseAllowance`, ERC-777 operators, any other grant shape. This is the enumeration pattern the core moved away from, so it is hygiene, not a bound. The bounds are D3 (the clone only ever holds what it pulled) and D6 (settle empties the clone of the asset and every declared token, so a lingering approval has nothing left to pull). The guardian reads the legs.

### D8 — Gas

The caps in D1 bound the template's own work. A venue's gas is not bounded by the template. A leg too expensive to execute fails the execute (the proposal expires). A settle leg too expensive to run leaves the proposal `Executed`; the owner's emergency path recovers it (D9). The returndata of each call is copied into memory; a venue returning a huge payload costs the caller of the batch gas, and the proposer chose that venue.

### D9 — Recovery

- `BaseStrategy.rescueTo(token)` (vault-only, any state) pushes any ERC-20 straggler home, from a later proposal's batch or the owner's `emergencySettleWithCalls`.
- `rescueERC721To(token, tokenId)` (vault-only, any state) does `IERC721(token).transferFrom(address(this), vault, tokenId)`. Plain `transferFrom`, because the vault has no ERC-721 receiver hook. The vault owner's `rescueERC721` takes it from there.
- `onERC721Received` returns its selector so a venue that delivers with `safeTransferFrom` succeeds. No ERC-1155 hooks: the vault cannot receive an ERC-1155 (no receiver hook and no non-safe transfer), so a 1155 the clone held could never come home; refusing receipt keeps that failure at execute.

### D10 — Guardian reviewability

Getters: `name() == "Generic Call"`, `asset()`, `pullAmount()`, `executeCalls() returns (Call[])`, `settleCalls() returns (Call[])`, `sweepTokens() returns (address[])`, `grants() returns (Grant[])`, `pinnedCodehash(address)`, `configHash()`, plus `BaseStrategy`'s `vault()`, `proposer()`, `state()`, `executed()`.

What a guardian checks before approving:

1. Provenance: `StrategyFactory.cloneTemplate(clone)` equals the book's `GENERIC_CALL_TEMPLATE`, and `vault()` is the proposal's vault.
2. The batches are `[asset.approve(clone, cap), clone.execute()]` and `[clone.settle()]`, with `cap >= pullAmount` after any coverage scaling.
3. Every call in both legs: target identity, decoded calldata, where tokens can go. `transfer` of the asset to an arbitrary address, or a venue call paying an arbitrary recipient, is allowed by the template and is exactly what the review must catch.
4. Simulation: the execute batch as the governor calling `vault.executeGovernorBatch` (the Arena runner already does this with `eth_simulateV1`), then the settle batch, and the vault's asset delta.

The CLI's guardian walk reads every zero-argument getter whose output holds an address, including tuple fields, so `executeCalls()` / `settleCalls()` expose every inner target once the CLI adds a `TEMPLATE_ABIS` entry for this template (follow-up in `sherwood`).

### D11 — Tier and coverage

`tierOf(clone, execute.selector)` is `(2, 10_000)`: the clone is uncertified, so coverage is the full declared cap on `clone.execute()`. The template SHALL never be certified, by address or by class: it is the surface `docs/adapter-onboarding-checklist.md` §2.1 refuses at tier 0/1 (an arbitrary-call forwarder whose destinations are fixed by calldata, not code). The template is outside the audit scope and offered at the syndicate's own risk, like the CL and Morpho templates.

`_scanCalls` refuses a tier-2 call whose cap exceeds `tier2CallCapBps` of TVL (`Tier2CallCapExceedsCeiling`). Arena vaults must keep `tier2CallCapBps` at or above the Arena size cap (8,000 bps) or a generic-call proposal at that size reverts at propose (SHE-407). Nothing here changes that parameter.

### D12 — `check-template-destinations.sh`

The SHE-209 gate scans `src/strategies/` for token movements whose destination is not the vault or the clone, and for destination-shaped identifiers. The template's own movements (`_pullFromVault`, `_pushAllToVault`, `rescueERC721To`) pay the vault or the clone and pass. Its forwarded calls are opaque `call`s the gate cannot see, which is why D11 forbids certification: the gate is a backstop for certified templates, and this one is never certified.

## Threats

| Threat | Closed by |
| --- | --- |
| Reentrancy into the vault or governor during a leg | Direct calls refused (D2.1). Indirect: `executeGovernorBatch`, `_deposit`, `_withdraw`, `requestRedeem`, `requestDeposit`, `settleRedeem` share the vault's `nonReentrant`; `executeProposal`, `settleProposal`, `unstick`, `finalizeEmergencySettle` share the governor's lock. Every leg runs inside one of those. |
| A venue calls back into the clone | `execute`, `settle`, `rescueTo`, `rescueERC721To` are `onlyVault`; `updateParams` always reverts; `initialize` is one-shot; `onERC721Received` is stateless. |
| A venue multicall targeting the clone's `rescueTo`/`settle` | `msg.sender` is the multicall contract, not the vault: `NotVault`. A direct self-call is refused at init (D2.1). |
| The clone spends more than it pulled | D3: no `transferFrom` or extension selector on the asset; no allowance to the clone on any other vault token. |
| Proposer edits the plan after the vote | Nothing is tunable (D1). |
| Proposer times settle against a moved market | Same as every template: the governor's drawdown floor and venue-level bounds in the settle calldata. The proposer can settle early; that is the existing governor rule. |
| Target self-destructs, is redeployed or re-delegated between propose and execute | D4 at execute. Proxy upgrades not covered; stated. |
| Gas griefing with long lists | D1 caps; venue gas unbounded (D8). |
| Lingering approvals | D7 best-effort revoke; D6 pushes leave nothing to pull. |
| Dust in non-asset tokens | Declared sweep tokens pushed at settle; anything else via `rescueTo`; all of it is a realised loss in the P&L (D6). |
| Native value or `delegatecall` tricks | `value == 0` enforced; `call` only; no `receive`/`fallback`. |
| A look-alike contract posing as this template | Provenance check (D10.1); a hand-registered contract has no `cloneTemplate` entry. |

## Risks / Trade-offs

- The template does not bound where funds go. A leg may `transfer` the pulled asset to any address. That is the definition of the template; tier-2 full-notional coverage and the guardian vote are the controls, as for any hand-written strategy.
- Calldata is fixed at init, so settle amounts are fixed too. Venues whose exit needs the live position size (redeem-all by shares, sell-whatever-was-bought) work only through a venue's own max sentinel or an exact-output execute. Live-balance substitution is a follow-up, not this change.
- Revocation recognises two selectors only (D7).
- Storing call data costs proposer gas at clone time (about 20k gas per 32 bytes); the 16 KB per-leg cap bounds it.

## Migration

None on-chain. The template ships in source and in the ceremony; the live-chain path is a GO item: run `script/robinhood-mainnet/DeployGenericCallStrategy.s.sol:DeployGenericCallTemplate` (mints the template only), have the Safe call `StrategyFactory.setTemplateApproval(template, true)` (a `DeployAll` re-run cannot approve it on 4663, because `DeployStrategyFactory.deploy` requires the deployer to still own the TierRegistry), and add `GENERIC_CALL_TEMPLATE` to `chains/4663.json`.
