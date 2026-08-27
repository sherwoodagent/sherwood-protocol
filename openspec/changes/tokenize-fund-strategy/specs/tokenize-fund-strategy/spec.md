# tokenize-fund-strategy

## Purpose

The tokenize-fund strategy template lets a syndicate "IPO" onchain: launch a fund token on an allowlisted launch venue with vault capital, retain a reserve, and distribute that reserve pro-rata to the fund's share holders — a secondary market per fund, with the deposit/redeem queue no longer the only liquidity. The template's defining constraint is that it deliberately acquires an asset the protocol must refuse to price: everything in this spec about settlement exists to keep that asset out of the vault's NAV until it is either claimed or warehoused unpriced.

## ADDED Requirements

### Requirement: One-shot lifecycle on BaseStrategy

`src/strategies/TokenizeFundStrategy.sol` SHALL extend `BaseStrategy` and inherit its full posture unchanged: template init-lock in the constructor, one-shot `initialize`, vault-only `execute()` bound to the governor's active proposal, vault-only `settle()` deliberately unbound, and the live `isAgent` re-check on every proposer-gated call. Initialization SHALL decode a single struct (the `ConcentratedLiquidityStrategy` precedent) carrying: launch adapter, swap adapter, launch params (name, symbol, quote token, quote budget, min tokens out, venue data), `reserveAmount`, claim-window duration, and slippage bounds for quote routing.

Initialization SHALL fail closed: registry unresolved reverts; launch adapter and swap adapter must pass `isAdapterAllowed`; `quoteSupported(quoteToken)` must answer true; `reserveAmount`, window, and slippage must sit inside their bounds. `updateParams` SHALL permit only `minTokensOut`, slippage floors, and the launch deadline, and only before execution.

#### Scenario: Unsupported quote at init
- **WHEN** `initialize` runs with a quote token the adapter reports unsupported (e.g. WOOD on a Stonk lane)
- **THEN** init reverts before the clone can be attached to a proposal

#### Scenario: Demoted adapter between init and execute
- **WHEN** the launch adapter loses `isAdapterAllowed` standing after init
- **THEN** `execute()` reverts on the live re-check and no capital leaves the vault

### Requirement: Execute deploys capital and freezes the snapshot

`_execute()` SHALL, in order: pull the proposal's vault-asset budget via `_pullFromVault`; when the launch quote differs from the vault asset, swap into the quote through the allowlisted `ISwapAdapter` under the configured slippage floor; approve and call `ILaunchAdapter.launch`; verify the custody invariant (`reserveHeld ≥ reserveAmount` on the strategy); record `token`, `launchRef`, and the claim reserve; record the snapshot timestamp `snap = clock()` (the vault's timestamp clock); and return any unspent vault asset via `_pushAllToVault`. The snapshot SHALL be immutable after execute.

Adversary the snapshot placement answers: an init-time snapshot lets the proposer freeze the claimant set before depositors can react to the public proposal; execute-time matches the instant capital actually leaves the vault.

#### Scenario: Launch under-delivers the reserve
- **WHEN** `ILaunchAdapter.launch` returns `reserveHeld < reserveAmount`
- **THEN** `_execute` reverts in full — no launch, no snapshot, no capital deployed

### Requirement: Claim window distributes the reserve pro-rata by snapshot

While the clone is `Executed` and within the claim window, `claim()` (and `claimFor(holder)`, paying the holder, callable by anyone) SHALL transfer `reserve × getPastVotes(holder, snap) / getPastTotalSupply(snap)` fund tokens, at most once per holder. This is a dividend-in-kind: shares are not burned. The math relies on the vault's normative auto-self-delegation (past votes == past balance for never-delegators); the two known divergences are accepted and documented: queue-escrowed shares at the snapshot carry no claim (the escrow contract never claims; its weight returns to the vault at settle), and an explicit delegator's claim follows the vote.

Claims outside the window, second claims, and zero-entitlement claims SHALL revert. Σ(claims) SHALL never exceed the recorded reserve.

#### Scenario: Double claim
- **WHEN** a holder claims and then calls `claim()` again inside the window
- **THEN** the second call reverts and no tokens move

#### Scenario: Deposit after the snapshot
- **WHEN** an address first acquires shares after `snap`
- **THEN** its `getPastVotes(addr, snap)` is zero and `claim()` reverts with zero entitlement

#### Scenario: Claim after the window
- **WHEN** the window has elapsed
- **THEN** `claim()` reverts; the unclaimed remainder is settlement inventory

### Requirement: Settlement never prices the fund token; residue is declared, not hidden

`settle()` SHALL be callable only after the claim window has elapsed. `_settle()` SHALL: collect the creator fee stream via `ILaunchAdapter.collectFees`; convert quote-asset balances to the vault asset through the allowlisted swap adapter under the settle slippage floor; and `_pushAllToVault` the vault-asset total. It SHALL NOT sell the fund token into its own launch pool within settlement — that price is attacker-movable inside the transaction.

The clone SHALL override all three `IStrategyDelivery` views: `hasUnvaluedResidue()` true while fund-token custody exceeds `RESIDUE_DUST`; `undeliveredValue()` counting only vault-asset-denominated custody; `hasUndeliveredValue()` consistent with both. All three SHALL NOT revert and SHALL read no attacker-movable price. A `Settled`-only, vault-only `sweep()` SHALL push vault-asset value and transfer remaining fund tokens to the vault as unpriced inventory (the vault warehouses them under its existing rescue surface; it never counts them in NAV).

For a venue whose launch is still in `Curve`/`Closing`/`Failed` phase at settlement (StonkBrokers), `_settle` SHALL take the deliverable maximum — settle what is expressible, leave the adapter clone holding its creator position, keep reporting unvalued residue — and later `finalize()`/`sweep()` calls SHALL remain able to resolve the launch. Settlement SHALL NOT depend on a pad trade that a stock-lane oracle gap can block.

#### Scenario: Unclaimed reserve at settle
- **WHEN** the window closes with part of the reserve unclaimed
- **THEN** settle completes, the vault receives all vault-asset value, and the strategy reports `hasUnvaluedResidue() == true` until the fund tokens are swept to the vault

#### Scenario: Un-graduated Stonk launch at settle
- **WHEN** settlement comes due while `phase(launchRef)` is not `Live`
- **THEN** `_settle` completes without forcing a curve exit, and a later permissioned `finalize` + `sweep` can still resolve the launch

### Requirement: Fee-stream custody after settlement

Creator-fee value accruing after settlement SHALL remain collectable: `collectFees` SHALL stay callable through the settled clone's sweep path, delivering quote value to the vault. The template SHALL NOT strand the stream in the adapter, and SHALL NOT require a new proposal to collect it.

#### Scenario: Fees accrue post-settlement
- **WHEN** the launch pool earns fees after the clone is `Settled`
- **THEN** a permissionless-or-vault-driven path (collectFees via sweep) delivers the creator share to the vault
