# tokenize-fund-strategy

## Purpose

The tokenize-fund strategy template lets a syndicate "IPO" onchain: launch a fund token on an allowlisted launch venue with vault capital, retain a reserve, and distribute that reserve pro-rata to the fund's share holders — a secondary market per fund, with the deposit/redeem queue no longer the only liquidity. The template's defining constraint is that it deliberately acquires an asset the protocol must refuse to price: everything in this spec about settlement exists to keep that asset out of the vault's NAV until it is either claimed or warehoused unpriced.

## ADDED Requirements

### Requirement: One-shot lifecycle on BaseStrategy

`src/strategies/TokenizeFundStrategy.sol` SHALL extend `BaseStrategy` and inherit its full posture unchanged: template init-lock in the constructor, one-shot `initialize`, vault-only `execute()` bound to the governor's active proposal, vault-only `settle()` deliberately unbound, and the live `isAgent` re-check on every proposer-gated call. Initialization SHALL decode a single struct (the `ConcentratedLiquidityStrategy` precedent) carrying: launch adapter, swap adapter, launch params (name, symbol, quote token, quote budget, min tokens out, venue data), `reserveAmount`, claim-window duration, and slippage bounds for quote routing.

Initialization SHALL fail closed: registry unresolved reverts; launch adapter and swap adapter must pass `isAdapterAllowed`; `quoteSupported(quoteToken)` must answer true; window and slippage must sit inside their bounds; and `reserveAmount ≤ launchSupply × MAX_RESERVE_BPS / 10_000`, where `MAX_RESERVE_BPS` is a template constant fixed at `2_000` (20%) and `launchSupply` is the Stonk `venueData` supply `p.supply` or, on Sushi, the venue's fixed `TOKEN_TOTAL_SUPPLY` (1e9 × 1e18). `quoteIn` SHALL NOT exceed the proposal's vault-asset budget. `updateParams` SHALL permit only `minTokensOut`, slippage floors, and the launch deadline, only before execution, and only in the tightening direction — `minTokensOut` may be raised, never lowered.

#### Scenario: Unsupported quote at init
- **WHEN** `initialize` runs with a quote token the adapter reports unsupported (e.g. WOOD on a Stonk lane)
- **THEN** init reverts before the clone can be attached to a proposal

#### Scenario: Demoted adapter between init and execute
- **WHEN** the launch adapter loses `isAdapterAllowed` standing after init
- **THEN** `execute()` reverts on the live re-check and no capital leaves the vault

### Requirement: Execute deploys capital and freezes the snapshot

`_execute()` SHALL, in order: pull the proposal's vault-asset budget via `_pullFromVault`; when the launch quote differs from the vault asset, swap into the quote through the allowlisted `ISwapAdapter` under the configured slippage floor; approve and call `ILaunchAdapter.launch`; verify the custody invariant (`reserveHeld ≥ reserveAmount` on the strategy); record `token`, `launchRef`, and the claim reserve; record the snapshot timestamp `snap = clock()` (the vault's timestamp clock); cache the proposal id and clamp the claim window (below); and return any unspent vault asset via `_pushAllToVault`. The snapshot SHALL be immutable after execute.

Adversary the snapshot placement answers: an init-time snapshot lets the proposer freeze the claimant set before depositors can react to the public proposal; execute-time matches the instant capital actually leaves the vault.

The claim window SHALL be clamped to the proposal's own clock at execute: `_execute` caches `pid = getActiveProposal()` (via `vault().governor()`; it reads 0 after settlement, hence the cache), reads `executedAt`/`strategyDuration` from `getProposal(pid)`, and records an immutable `windowEnd = min(executedAt + configured window, executedAt + strategyDuration − CLAIM_SETTLE_BUFFER)`, `CLAIM_SETTLE_BUFFER` being a template constant. Adversary: a window outlasting the proposal keeps `settle()` reverting on its own gate forever, pinning `openProposalCount() != 0` — the *unbounded* branch of `depositsLocked()` (`SyndicateVault.sol:1574`; the `_unvaluedCount` branch is at least capped at 7 days) — with no permissionless exit: `settleProposal` bubbles the strategy revert (`BatchExecutorLib.sol:92-97`), and `unstick` (which replays the identical batch) and `emergencySettleWithCalls` are both owner-gated. Deposits *and* redemptions would stay locked vault-wide, permanently.

Launch-price MEV and proposer self-dealing are an accepted risk, bounded not eliminated. Two mitigations are normative: `minTokensOut` is an init parameter — visible to voters before they vote — and `updateParams` may only raise it, so the floor ratchets toward depositors and never away; and on Sushi the dev buy is atomic inside `launchAndBuy`, leaving only the gap between that floor and realized output as sandwich surface, a gap the proposer chose in public. Stonk's native levers (`maxBuyPpm`, the tax schedule) ride `venueData` under the same visibility.

#### Scenario: Launch under-delivers the reserve
- **WHEN** `ILaunchAdapter.launch` returns `reserveHeld < reserveAmount`
- **THEN** `_execute` reverts in full — no launch, no snapshot, no capital deployed

#### Scenario: Configured window outlasts the proposal
- **WHEN** a proposer configures a claim window that would end after `executedAt + strategyDuration`
- **THEN** `_execute` truncates `windowEnd` to `executedAt + strategyDuration − CLAIM_SETTLE_BUFFER`, and `settle()` succeeds when anyone-settle opens

### Requirement: Claim window distributes the reserve pro-rata by snapshot

While the clone is `Executed` and at or before the clamped `windowEnd` recorded at execute, `claim()` (and `claimFor(holder)`, paying the holder, callable by anyone) SHALL transfer `reserve × getPastVotes(holder, snap) / getPastTotalSupply(snap)` fund tokens, at most once per holder. This is a dividend-in-kind: shares are not burned. The math relies on the vault's normative auto-self-delegation (past votes == past balance for never-delegators); the two known divergences are accepted and documented: queue-escrowed shares at the snapshot carry no claim (the escrow contract never claims; its weight stays as unpriced fund tokens warehoused in the vault under the owner-gated rescue surface), and an explicit delegator's claim follows the vote.

Claims SHALL be accepted only when `clock() > snap`: OZ's `getPastVotes`/`getPastTotalSupply` revert `ERC5805FutureLookup` for `timepoint >= clock()` (`>=`, not `>`), so a claim landing in the execute block SHALL be rejected by the template's own named error rather than bubbling the OZ revert. Claims outside the window, same-timestamp claims, second claims, and zero-entitlement claims SHALL revert. Σ(claims) SHALL never exceed the recorded reserve.

#### Scenario: Double claim
- **WHEN** a holder claims and then calls `claim()` again inside the window
- **THEN** the second call reverts and no tokens move

#### Scenario: Claim in the execute block
- **WHEN** a holder calls `claim()` at `clock() == snap`
- **THEN** the call reverts with the template's own error, never OZ's `ERC5805FutureLookup`

#### Scenario: Deposit after the snapshot
- **WHEN** an address first acquires shares after `snap`
- **THEN** its `getPastVotes(addr, snap)` is zero and `claim()` reverts with zero entitlement

#### Scenario: Claim after the window
- **WHEN** the window has elapsed
- **THEN** `claim()` reverts; the unclaimed remainder is settlement inventory

### Requirement: Settlement never prices the fund token; residue is declared, not hidden

`settle()` SHALL be callable once `block.timestamp > windowEnd`, and — unconditionally, as a backstop that needs no governor read — SHALL NOT revert on the window gate at any time when the governor's anyone-settle predicate holds (`block.timestamp >= executedAt + strategyDuration`, `SyndicateGovernor.sol:900-903`). The window truncates; settlement never waits on it. `_settle()` SHALL: collect the creator fee stream via `ILaunchAdapter.collectFees`; convert quote-asset balances to the vault asset through the allowlisted swap adapter under the settle slippage floor; and `_pushAllToVault` the vault-asset total. It SHALL NOT sell the fund token into its own launch pool within settlement — that price is attacker-movable inside the transaction.

The clone SHALL override all three `IStrategyDelivery` views: `hasUnvaluedResidue()` true while fund-token custody exceeds `RESIDUE_DUST`; `undeliveredValue()` counting only vault-asset-denominated custody; `hasUndeliveredValue()` consistent with both. All three SHALL NOT revert and SHALL read no attacker-movable price. `undeliveredValue()` is additionally clamped vault-side by `_residueCap = min(capital snapshot, effective max capital)` (`SyndicateVault.sol:1828-1830`, `:1954-1966`); the template SHALL NOT rely on figures above the proposal's capital being counted. A `Settled`-only, vault-only `sweep()` SHALL push vault-asset value and transfer remaining fund tokens to the vault as unpriced inventory (the vault warehouses them under its existing rescue surface; it never counts them in NAV).

`sweep()` SHALL move only balances already held, over a bounded token count under a per-token gas budget in the `CallSandbox` precedent's spirit (`_TOKEN_SWEEP_GAS = 80_000`), and SHALL make no venue call — no NFPM collect, no cross-clone flush. Fee collection is settle-time or venue-direct, never sweep-time. Adversary: the vault drives `sweep()` under a hard `_SWEEP_GAS = 1_500_000` cap, ignores the result and measures recovery as a balance delta (`SyndicateVault.sol:2565`, `:1728`), and probes the views under `_PROBE_GAS = 150_000` (`:2556`) — an out-of-gas sweep silently recovers nothing, the failure `CallSandbox.sol:75-80` already records. Sweep and all three views SHALL fit those caps.

The delivery views SHALL latch: once the first post-settle `sweep()` has driven fund-token custody below `RESIDUE_DUST`, `hasUnvaluedResidue()` and `hasUndeliveredValue()` SHALL be permanently false and `undeliveredValue()` permanently 0, whatever balance later appears. Adversary: a strategy that truthfully clears and then truthfully reports residue *again* is re-markable by permissionless `collectResidue`, re-stamping a fresh 7-day deposit lock each time fees trickle in — `_unvaluedBurned` blocks only the post-prune direction (`SyndicateVault.sol:1988`, `:2011-2013`). Post-settlement value therefore SHALL NOT transit strategy custody at all; it reaches the vault venue-direct (see the fee-stream requirement).

For a venue whose launch is still in `Curve`/`Closing`/`Failed` phase at settlement (StonkBrokers), `_settle` SHALL take the deliverable maximum — settle what is expressible, leave the adapter clone holding its creator position, keep reporting unvalued residue — and later `finalize()`/`sweep()` calls SHALL remain able to resolve the launch. Settlement SHALL NOT depend on a pad trade that a stock-lane oracle gap can block.

#### Scenario: Unclaimed reserve at settle
- **WHEN** the window closes with part of the reserve unclaimed
- **THEN** settle completes, the vault receives all vault-asset value, and the strategy reports `hasUnvaluedResidue() == true` until the fund tokens are swept to the vault

#### Scenario: Un-graduated Stonk launch at settle
- **WHEN** settlement comes due while `phase(launchRef)` is not `Live`
- **THEN** `_settle` completes without forcing a curve exit, and a later permissioned `finalize` + `sweep` can still resolve the launch

### Requirement: Fee-stream custody after settlement

Creator-fee value accruing after settlement SHALL remain collectable without a new proposal, and SHALL NEVER transit strategy custody — the views are latched, so a balance arriving there is invisible, or before the latch a re-lock lever. `_settle` SHALL hand the stream to the vault, venue-shaped:

- **Sushi**: `_settle` calls `transferCreator(token, vault())` on the adapter's `launchTarget()`, making the VAULT the creator; the venue's permissionless `distributeFees(token)` thereafter pays BOTH legs — quote and fund token — straight to the vault.
- **StonkBrokers**: no creator transfer exists and the creator is the per-launch clone, which is not the strategy and so is invisible to the vault's residue machinery. The clone's `forwardToVault()` — owner-only before settlement, permissionless after — flushes creator quote and sends every clone balance to the strategy's vault.

Both post-settlement paths deliver IN KIND: quote and fund token, warehoused unpriced under the vault's owner-gated rescue surface, priced into NAV by neither. Conversion to the vault asset is a settle-time act only, the `_settle` swap already specced; no requirement here claims post-settlement conversion.

#### Scenario: Fees accrue post-settlement
- **WHEN** the launch pool earns creator fees after the clone is `Settled`
- **THEN** a permissionless call (`distributeFees` on Sushi, `forwardToVault` on Stonk) delivers both legs to the vault in kind, and no balance passes through the strategy

#### Scenario: Fees accrue after the latch
- **WHEN** fees accrue after the first post-settle `sweep()` cleared fund-token custody
- **THEN** the delivery views stay false/0/false, `collectResidue` cannot re-mark the strategy or re-stamp a deposit lock, and the value still reaches the vault venue-direct
