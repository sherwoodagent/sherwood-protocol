# launchpad-strategy

## Purpose

The launchpad strategy template lets a syndicate "IPO" onchain: launch a fund token on an allowlisted launch venue with vault capital, retain a reserve, and distribute that reserve pro-rata to the fund's share holders — a secondary market per fund, with the deposit/redeem queue no longer the only liquidity. The template's defining constraint is that it deliberately acquires an asset the protocol must refuse to price: everything in this spec about settlement exists to keep that asset out of the vault's NAV until it is either claimed or warehoused unpriced.

## ADDED Requirements

### Requirement: One-shot lifecycle on BaseStrategy

`src/strategies/LaunchpadStrategy.sol` SHALL extend `BaseStrategy` and inherit its full posture unchanged: template init-lock in the constructor, one-shot `initialize`, vault-only `execute()` bound to the governor's active proposal, vault-only `settle()` deliberately unbound, and the live `isAgent` re-check on every proposer-gated call. Initialization SHALL decode a single struct (the `ConcentratedLiquidityStrategy` precedent) carrying: launch adapter, swap adapter, launch params (name, symbol, quote token, quote budget, min tokens out, venue data), `reserveAmount`, claim-window duration, and slippage bounds for quote routing.

Initialization SHALL fail closed: registry unresolved reverts; launch adapter and swap adapter must pass `isAdapterAllowed`; `quoteSupported(quoteToken)` must answer true; the configured claim window must satisfy `configuredWindow ≤ MAX_CLAIM_WINDOW`, a template constant and the only ceiling that survives a corrupt governor decode at execute (see the settlement requirement); slippage must sit inside its bounds; and `reserveAmount ≤ launchSupply × MAX_RESERVE_BPS / 10_000`, where `MAX_RESERVE_BPS` is a template constant fixed at `2_000` (20%) and `launchSupply` is DECLARED by the proposer at init and VERIFIED at execute against the launched token's own `totalSupply()` — the template stays venue-agnostic about how supply is decided (Sushi fixes it at 1e9 × 1e18, StonkBrokers takes it from `venueData`), and the execute-time equality is what stops a proposer from inflating the declared figure to lift their own ceiling. `quoteIn` SHALL NOT exceed the proposal's vault-asset budget. `updateParams` SHALL permit only `minTokensOut`, slippage floors, and the launch deadline, only before execution, and only in the tightening direction — `minTokensOut` may be raised, never lowered.

#### Scenario: Unsupported quote at init
- **WHEN** `initialize` runs with a quote token the adapter reports unsupported (e.g. WOOD on a Stonk lane)
- **THEN** init reverts before the clone can be attached to a proposal

#### Scenario: Demoted adapter between init and execute
- **WHEN** the launch adapter loses `isAdapterAllowed` standing after init
- **THEN** `execute()` reverts on the live re-check and no capital leaves the vault

### Requirement: Execute deploys capital and freezes the snapshot

`_execute()` SHALL, in order: pull the proposal's vault-asset budget via `_pullFromVault`; when the launch quote differs from the vault asset, swap into the quote through the allowlisted `ISwapAdapter` under the configured slippage floor; acquire the token `ILaunchAdapter.nativeFeeSource()` names, in the amount it names, through that same swap adapter when the vault asset differs (the venue's native launch fee cannot be assumed to come from the quote — the pair is the agent's choice); approve and call `ILaunchAdapter.launch`; verify the custody invariant (`reserveHeld ≥ reserveAmount` on the strategy) AND that the launched token's `totalSupply()` equals the supply the proposer declared at init — without that check the `MAX_RESERVE_BPS` ceiling is self-scored, since a proposer who inflates the declared supply lifts their own cap; record `token`, `launchRef`, and the claim reserve; record the snapshot timestamp `snap = clock()` (the vault's timestamp clock); cache the proposal id and clamp the claim window (below); and return any unspent vault asset via `_pushAllToVault`. The snapshot SHALL be immutable after execute.

Adversary the snapshot placement answers: an init-time snapshot lets the proposer freeze the claimant set before depositors can react to the public proposal; execute-time matches the instant capital actually leaves the vault.

The claim window SHALL be clamped to the proposal's own clock at execute: `_execute` caches `pid = getActiveProposal()` (via `vault().governor()`; it reads 0 after settlement, hence the cache), reads `executedAt`/`strategyDuration` from `getProposal(pid)`, and records an immutable `windowEnd = min(executedAt + configured window, executedAt + strategyDuration − CLAIM_SETTLE_BUFFER)`, `CLAIM_SETTLE_BUFFER` being a template constant. `_execute` SHALL require `strategyDuration > CLAIM_SETTLE_BUFFER` and revert with the template's own named error otherwise — not a checked-arithmetic panic and not a saturating clamp, because saturating would floor `windowEnd` at `executedAt`, an empty claim window, and deploy vault capital on a launch whose entire purpose (the holder claim) can never happen; reverting at execute strands nothing, since the proposal simply never executes and expires at `executeBy`. `strategyDuration`'s floor is the governor's `ABSOLUTE_MIN_STRATEGY_DURATION` (1 hour), so `CLAIM_SETTLE_BUFFER` SHALL be chosen below it or no proposal is executable at all. Adversary: a window outlasting the proposal keeps `settle()` reverting on its own gate forever, pinning `openProposalCount() != 0` — the *unbounded* branch of `depositsLocked()` (`SyndicateVault.sol:1574`; the `_unvaluedCount` branch is at least capped at 7 days) — with no permissionless exit: `settleProposal` bubbles the strategy revert (`BatchExecutorLib.sol:92-97`), and `unstick` (which replays the identical batch) and `emergencySettleWithCalls` are both owner-gated. Deposits *and* redemptions would stay locked vault-wide, permanently.

Launch-price MEV and proposer self-dealing are an accepted risk, bounded not eliminated. Two mitigations are normative: `minTokensOut` is an init parameter — visible to voters before they vote — and `updateParams` may only raise it, so the floor ratchets toward depositors and never away; and on Sushi the dev buy is atomic inside `launchAndBuy`, leaving only the gap between that floor and realized output as sandwich surface, a gap the proposer chose in public. Stonk's native levers (`maxBuyPpm`, the tax schedule) ride `venueData` under the same visibility.

#### Scenario: Launch under-delivers the reserve
- **WHEN** `ILaunchAdapter.launch` returns `reserveHeld < reserveAmount`
- **THEN** `_execute` reverts in full — no launch, no snapshot, no capital deployed

#### Scenario: Configured window outlasts the proposal
- **WHEN** a proposer configures a claim window that would end after `executedAt + strategyDuration`
- **THEN** `_execute` truncates `windowEnd` to `executedAt + strategyDuration − CLAIM_SETTLE_BUFFER`, and `settle()` succeeds when anyone-settle opens

#### Scenario: Proposal too short for the settle buffer
- **WHEN** a proposal's `strategyDuration` is at or below `CLAIM_SETTLE_BUFFER`
- **THEN** `_execute` reverts with the template's named error and no capital is deployed

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

`settle()` SHALL be callable once `block.timestamp > windowEnd`, and — as a backstop that needs no *fresh* governor read — SHALL NOT revert on the window gate at any time when the governor's anyone-settle predicate holds (`block.timestamp >= executedAt + strategyDuration`, `SyndicateGovernor.sol:900-903`). The window truncates; settlement never waits on it. That backstop is built from the same execute-time `getProposal(pid)` struct decode the clamp uses, which design.md calls upgrade-fragile, so a garbage decode poisons clamp and backstop identically; what actually contains a corrupt decode is the init-time ceiling — with the governor-derived arm of the `min` unusable, `configuredWindow ≤ MAX_CLAIM_WINDOW` still holds `windowEnd ≤ executedAt + MAX_CLAIM_WINDOW`, capping any wedge at the template's maximum window rather than forever. `_settle()` SHALL: collect the creator fee stream via `ILaunchAdapter.collectFees`; convert quote-asset balances to the vault asset through the allowlisted swap adapter under the settle slippage floor; and `_pushAllToVault` the vault-asset total. It SHALL NOT sell the fund token into its own launch pool within settlement — that price is attacker-movable inside the transaction.

The clone SHALL override all three `IStrategyDelivery` views: `hasUnvaluedResidue()` true while fund-token custody exceeds `RESIDUE_DUST`; `undeliveredValue()` counting only vault-asset-denominated custody; `hasUndeliveredValue()` consistent with `undeliveredValue()` (not with the unvalued flag — the two are split below). All three SHALL NOT revert and SHALL read no attacker-movable price. `undeliveredValue()` is additionally clamped vault-side by `_residueCap = min(capital snapshot, effective max capital)` (`SyndicateVault.sol:1828-1830`, `:1954-1966`); the template SHALL NOT rely on figures above the proposal's capital being counted. A `Settled`-only, vault-only `sweep()` SHALL push vault-asset value and transfer remaining fund tokens to the vault as unpriced inventory (the vault warehouses them under its existing rescue surface; it never counts them in NAV).

`sweep()` SHALL move only balances already held, over a bounded token count under a per-token gas budget in the `CallSandbox` precedent's spirit (`_TOKEN_SWEEP_GAS = 80_000`), and SHALL make no venue call — no NFPM collect, no cross-clone flush. Fee collection is settle-time or venue-direct, never sweep-time. Adversary: the vault drives `sweep()` under a hard `_SWEEP_GAS = 1_500_000` cap, ignores the result and measures recovery as a balance delta (`SyndicateVault.sol:2565`, `:1728`), and probes the views under `_PROBE_GAS = 150_000` (`:2556`) — an out-of-gas sweep silently recovers nothing, the failure `CallSandbox.sol:75-80` already records. Sweep and all three views SHALL fit those caps.

`hasUnvaluedResidue()` SHALL be MONOTONE after settlement: once it has been observed false at any point after the clone reached `Settled` — whether a clearing `sweep()` drove fund-token custody below `RESIDUE_DUST` or custody was already below it at settlement — it SHALL be permanently false and SHALL NEVER return true again, whatever balance later appears at the strategy address. The arming observation is the first false one *after* settlement, never settlement itself: at settlement the flag legitimately reads true, custody being at its maximum before any sweep. Adversary: a clone that never runs a clearing sweep is still `tracked` on `_residueAmount != 0` alone (`SyndicateVault.sol:1724`, gate `:1741`), so a donation of `RESIDUE_DUST + 1` fund tokens flips the probe false→true, `_refreshUnvalued` marks it (never burned, `:1988`) and `_bumpUnvalued` re-stamps `_unvaluedSince` (`:2011-2013`) for a fresh 7-day deposit lock, repeatable per donation; `releaseUnconvertible` is the zero-cost trigger — a template with no release hatch reverts the recovery call, `swept` is discarded (`:1729`), nothing moves, and the probe still reads the donated state as true. Monotonicity is sound because every vault-side flow moves the flag true→false only and a clone cannot settle twice (the settlement-time `_refreshUnvalued` at `:1821` can never re-fire); the residual cost — a genuinely unvaluable residue arriving later stops blocking mints — is the bounded-mispricing trade `_unvaluedSince`'s own natspec already makes (`:417-422`), and strictly narrower than `_unvaluedBurned`'s permanent immunity.

`undeliveredValue()` SHALL NOT be latched on that predicate: it SHALL keep reporting vault-asset-denominated custody honestly until that value is actually delivered to the vault, reaching 0 only when the custody itself is 0, and SHALL NOT rise again thereafter; `hasUndeliveredValue()` SHALL track that quantity, not the unvalued flag. Adversary: the two measure disjoint legs — the dust predicate measures the leg the template cannot price, `undeliveredValue()` the leg it can — and they feed disjoint vault machinery. `depositsLocked()` reads only `_unvaluedCount` (`SyndicateVault.sol:1578`, `:1581`, enforced `:2191`), while `undeliveredValue()` feeds `depositNav() = totalAssets() + _residueTotal` (`:1589-1590`) into `previewDeposit`/`previewMint` (`:2156`, `:2163`). Latching a vault-asset figure to 0 on a fund-token observation, with real vault-asset residue still held, would therefore under-price mints — the finding-#3 skim itself, which `IStrategyDelivery.sol:44-53` names outright: a report that is too low IS the skim, and bias-low is not safe here. A fund-token donation cannot inflate `undeliveredValue()` at all (it counts only vault-asset custody) and is a pure lock vector; a vault-asset donation can inflate it but is benign — clamped by `_residueCap`, genuinely recoverable, and over-counting only over-charges that depositor (`IStrategyDelivery.sol:271-281`). Post-settlement value SHALL NOT transit strategy custody at all; it reaches the vault venue-direct (see the fee-stream requirement).

For a venue whose launch is still in `Curve`/`Closing`/`Failed` phase at settlement (StonkBrokers), `_settle` SHALL take the deliverable maximum — settle what is expressible, leave the adapter clone holding its creator position, keep reporting unvalued residue — and later `finalize()`/`sweep()` calls SHALL remain able to resolve the launch. Settlement SHALL NOT depend on a pad trade that a stock-lane oracle gap can block.

#### Scenario: Unclaimed reserve at settle
- **WHEN** the window closes with part of the reserve unclaimed
- **THEN** settle completes, the vault receives all vault-asset value, and the strategy reports `hasUnvaluedResidue() == true` until the fund tokens are swept to the vault

#### Scenario: Un-graduated Stonk launch at settle
- **WHEN** settlement comes due while `phase(launchRef)` is not `Live`
- **THEN** `_settle` completes without forcing a curve exit, and a later permissioned `finalize` + `sweep` can still resolve the launch

#### Scenario: Donation to a strategy that settled already clear
- **WHEN** a strategy settles with fund-token custody already below `RESIDUE_DUST` — only vault-asset residue outstanding, so no clearing `sweep()` ever runs — and someone later donates fund tokens to it
- **THEN** `hasUnvaluedResidue()` stays false, `collectResidue` cannot re-mark the strategy, and no deposit lock is re-stamped

### Requirement: The native-fee overshoot has a destination

Acquiring the venue's native-fee token uses an exact-INPUT swap, which cannot hit an exact output, so an overshoot is STRUCTURAL rather than incidental. `_execute` SHALL deliver any residual fee-token balance to the vault before it returns, whenever the fee token is neither the vault asset nor the launch quote — those two already have homes (`_pushAllToVault` and the quote lane's conversion plus `sweep()` respectively).

Adversary this closes, found by an end-to-end run rather than by reasoning: the fee token was a local variable, so `sweep()` could not see it, `undeliveredValue()` counts only vault-asset custody and `hasUnvaluedResidue()` only the launch token and quote — leaving the overshoot unrecoverable AND undeclared. Measured on a live fork: a USDG-quoted Sushi launch stranded 15,002,662,640,967 wei of WETH on the clone, still present after two residue collections. Bounded by `launchFee × settleSlippageBps`, so small, but it is vault capital with no path home.

The delivery is a hard transfer, so a fee token that refuses it reverts `execute()`. That is the intended direction: this template's doctrine is that blocking `execute()` strands nothing, while a tolerated transfer would recreate the defect on exactly the token that triggers it.

#### Scenario: Fee-token overshoot reaches the vault
- **WHEN** the fee token is neither the vault asset nor the quote, and the swap overshoots
- **THEN** the exact residual is delivered to the vault before `_execute` returns and the clone holds none of it

#### Scenario: The other two lanes are untouched
- **WHEN** the fee token IS the vault asset, or IS the launch quote
- **THEN** no residual delivery occurs — the existing lanes already carry it

### Requirement: Creator fees are paid to the vault, named at launch

The strategy SHALL name the FUND'S VAULT as the launch's fee recipient, passing `vault()` into `ILaunchAdapter.LaunchParams.feeRecipient` at execute. It SHALL NOT accept that address as proposer input: a proposer-supplied recipient would let a proposal point a fund's fee stream at something other than the fund.

Creator fees SHALL therefore never enter strategy custody at any point in the launch's life. Collection SHALL be permissionless — the venues expose their payouts permissionlessly, the payee is fixed at launch and cannot be re-pointed, and a later proposal decides what the vault does with what accumulates.

THIS DELETES A CLASS OF PROBLEM RATHER THAN GUARDING IT. Routing fees through the strategy gave the stream a destination that had to change when the strategy settled, and value sitting in a settled strategy is a permissionless deposit-lock lever: anyone can drive the vault's residue collection and re-stamp a fresh lock episode. Naming the vault up front means there is no second lane to get wrong, no handoff that can fail at settlement, and no settlement-dependent branch to reason about.

Two consequences are ACCEPTED, not overlooked. First, no protocol code path pushes accrued fees: with the payee fixed at launch, collection is left to whoever cares — a keeper, a holder, or a later proposal — and the template makes no venue call for fees at any point, so a settled launch keeps earning at the venue with no on-chain reminder. Second, fees reach the vault IN KIND and unpriced, including a quote the vault may not be able to price, and disposing of them is a governance act rather than a template one. Both follow directly from wanting fees to be a plain vault receipt rather than a second distribution mechanism.

One CONSTRAINT falls out of naming the recipient at the venue: it is irrevocable. The venues bind the payee at launch and this template offers no re-point, so a fund that ever migrates vaults leaves its existing launches paying the OLD vault forever. `_execute` reads `vault()`, so the address is correct by construction at launch time; the exposure is migration, not misconfiguration. Any future vault-migration work must treat live launches as a thing it cannot carry across.

The SNAPSHOT machinery SHALL remain scoped to the launch RESERVE alone. The reserve is fixed at execute and cannot grow, so per-holder claim accounting is once-only.

#### Scenario: Fees are the vault's from the first block
- **WHEN** a launch completes
- **THEN** the venue's fee recipient is the fund's vault, and it remains so without any later handoff

#### Scenario: Fees never reach the strategy
- **WHEN** anyone drives a fee payout, at any point before or after settlement
- **THEN** the value lands on the vault, the strategy's balances are unchanged, the reserve is unchanged, and the caller receives nothing

#### Scenario: The reserve is not a fee sink
- **WHEN** fees accrue over the life of a launch
- **THEN** the claimable reserve is exactly what execute recorded — snapshot holders claim the launch allocation, never the fee stream

### Requirement: The fee stream outlives settlement without a proposal

A launch keeps earning after the strategy settles, and that value SHALL stay collectable permissionlessly, forever, without a new proposal — the recipient named at launch is the vault, and settlement does not change it.

- **Sushi**: the vault is the venue's creator, so the permissionless `distributeFees(token)` pays it both legs — quote and launch token — with no involvement from the strategy at all.
- **StonkBrokers**: the per-launch clone must stay creator (the venue's `arm`/`abort` levers are creator-only), so it forwards what it receives to the recipient it was initialized with. The clone is not the strategy, so what it briefly holds is invisible to the vault's residue machinery either way.

Both deliver IN KIND — quote and launch token, warehoused unpriced, counted in NAV by neither. There is no post-settlement conversion, and no requirement here claims one.

Note what this requirement no longer has to say. It previously specified a settle-time handoff that moved the fee role to the vault, and the residue-latch reasoning that made a post-settlement fee arrival safe. Naming the vault at launch removes the need for both: nothing arrives at the strategy, so there is no arrival to make safe.

#### Scenario: Fees accrue long after settlement
- **WHEN** the launch earns fees after the strategy is `Settled`
- **THEN** any caller can push them to the vault, no proposal is required, and no balance passes through the strategy

