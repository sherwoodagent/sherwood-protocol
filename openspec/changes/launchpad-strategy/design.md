# Design — LaunchpadStrategy + Launch Adapters

All venue facts below were verified against mainnet 4663 (verified explorer source + `cast` reads, 2026-08-22/26). Where the two venues disagree, the disagreement is stated first, because reconciling them *is* the design.

## The two venues, side by side

| | Sushi Launchpad V1 | StonkBrokers Smart Launch V2/V3 |
|---|---|---|
| Deployment | `0x104f1ab4…a7ed`, mainnet 4663 only | 16 pads (8 V2 mint-launch, 8 V3 BYO-token), one per quote lane; lens `0x25b5…15B3`; mainnet 4663 only |
| Supply | fixed 1B × 1e18, minted to launchpad | creator-chosen; `createLaunch(token=0)` mints **to the creator**; `arm(id, supplyWei)` loads the curve portion |
| Creator allocation | **zero** — reserve must be a same-tx dev buy (`launchAndBuy`) | supply − loadedSupply stays with the creator — reserve is a free allocation |
| Launch price | fixed $5,000 FDV via quote-token Chainlink feed | creator-chosen `startMcapUsd8` ∈ [$1k, $1M], `gradMcapUsd8` ∈ [$50k, $10M] (live bounds) |
| Liquidity | immediate: 97% of supply in a one-sided Sushi-V3 1% position owned by the launchpad | curve phase first; at graduation, permissionless `bond()` mints a **locked** LP (Slipstream CL box or Uniswap-v3 1% + locker); unsold burned or single-sided-LP'd (`unsoldMode`) |
| Quote assets | feed-gated allowlist: WETH, USDG, SUSHI, GME, TSLA, SPCX, COIN, DELL, AAPL, NVDA. **WOOD absent**; owner-only to add | fixed lane per pad: WETH, STONK, USDG, GME, NVDA, AAPL, SPCX, USO. **WOOD impossible** |
| Creator role | transferable (`transferCreator`) | pinned at `createLaunch`, **no transfer** |
| Fee stream | 70% of LP fees to creator, permissionless `distributeFees` | 16.5% of the per-trade tax to creator (live `creatorFeeBps`), `flushCreatorQuote` |
| Launch fee | 0.0005 native ETH | 0 (live) |
| Contract callers | fine (`nonReentrant` only) | fine unless the launch sets `eoaOnly` (we never set it) |
| Venue-specific hazards | quote feed staleness (3d max) at launch | stock lanes revert `StalePrice` on oracle gaps (weekends); tax changes per minute — all quoting through the lens |

## Decision 1 — `ILaunchAdapter` is a lifecycle, not a function

A single `launch() → tokensOut` call (the shape `ISwapAdapter` has) fits Sushi, where the pool exists and the dev buy settles in the launch transaction. It cannot express StonkBrokers, where the launch is a *process*: create → arm → curve trades for minutes-to-indefinitely → graduate → bond. The interface is therefore four verbs:

```solidity
interface ILaunchAdapter {
    struct LaunchParams {
        string  name;
        string  symbol;
        address quoteToken;      // must satisfy quoteSupported()
        uint256 quoteIn;         // quote spent from the strategy (dev buy on Sushi; 0 allowed on Stonk)
        uint256 minTokensOut;    // slippage floor on any same-tx buy
        uint256 reserveAmount;   // fund tokens the STRATEGY must end up holding at launch
        uint64  deadline;
        bytes   venueData;       // venue-specific: Sushi none; Stonk CreateParams economics (mcaps, tax schedule, buffer, unsoldMode, bondVenue, maxBuyPpm)
    }
    struct LaunchResult {
        address token;
        bytes32 launchRef;       // venue-scoped key: Sushi = token addr; Stonk = keccak(pad, id)
        uint256 reserveHeld;     // fund tokens now held by the strategy
        uint256 quoteSpent;
    }
    enum LaunchPhase { None, Curve, Closing, Live, Failed } // Live = tradable pool exists (Sushi: immediately; Stonk: bonded)

    function launch(LaunchParams calldata p) external payable returns (LaunchResult memory);
    function phase(bytes32 launchRef) external view returns (LaunchPhase);
    function finalize(bytes32 launchRef) external;                        // drive graduate/bond where the venue needs it; no-op on Sushi
    function collectFees(bytes32 launchRef) external returns (uint256 quoteOut, uint256 tokenOut); // creator share → strategy
    function quoteSupported(address quoteToken) external view returns (bool);
    function nativeFeeSource() external view returns (address token, uint256 amount); // what the adapter pulls to cover a native launch fee
    function launchTarget() external view returns (address);
}
```

`nativeFeeSource` was added during implementation, and the omission it fixes is worth recording. Sushi charges its launch fee in native ETH, and the obvious way to fund that from a strategy — unwrap some of the launch quote — silently assumes the quote IS the wrapped native. **It is not: the pair is the agent's choice**, so a proposal pairing against a stable, a stock token, or WOOD would have reverted at execute on exactly the pairings this template exists to enable. The adapter therefore NAMES its fee token and amount, read live (the venue owner can reprice between propose and execute), and the strategy acquires that token through its own allowlisted swap adapter. A venue charging no native fee answers `(address(0), 0)`.

Rules every implementation MUST satisfy (normative in the spec):

- **Custody invariant**: at the end of `launch`, the strategy — not the adapter — holds `reserveHeld ≥ p.reserveAmount` fund tokens, the creator-economics of the venue (fee stream, abort/recovery levers), and nothing of value remains in the adapter. How is venue-specific (Decision 2).
- `phase` and `quoteSupported` MUST NOT revert; `phase` is what the strategy's settlement logic branches on.
- `collectFees` routes only to the strategy that owns the launch, and is safe to call in any phase (0,0 when nothing accrued).
- On Sushi, `reserveAmount` is satisfied by the dev buy (`launchAndBuy` with `recipient = strategy`), so `quoteIn` must be sized to clear it and `minTokensOut ≥ reserveAmount`. On StonkBrokers, `reserveAmount` is `supply − loadedSupply` held back before `arm`, and `quoteIn` may be zero (a pure fair launch) or fund a curve dev buy via the pad's `buy(..., recipient = strategy)`.

## Decision 2 — two custody shapes, one interface: singleton vs per-launch clone

**Sushi**: the launchpad's creator role is transferable. `SushiLaunchAdapter` is a stateless singleton in the `UniswapSwapAdapter` mold: `launch` pulls quote from `msg.sender`, calls `launchAndBuy` (recipient = strategy), then immediately `transferCreator(token, msg.sender)`. After the launch tx the adapter holds nothing and no role. `collectFees` cannot be run *by* the singleton thereafter (the strategy is the creator, and `distributeFees` pays the creator directly and permissionlessly) — the adapter's `collectFees` is a thin wrapper that calls `distributeFees(token)` and reports the amounts that landed on the strategy.

**StonkBrokers**: there is no `transferCreator`. Whoever calls `createLaunch` is the creator forever — fee recipient, sole `arm`/`abort` caller. A stateless singleton would become the creator of every strategy's launch, concentrating every fee stream and recovery lever in one shared contract keyed by internal bookkeeping — exactly the shared-mutable-custody shape the audit rounds kept removing. So `StonkLaunchAdapter` is an **ERC-1167 clone per launch**, deployed and initialized inside `launch()` by a factory entry on the implementation, owned by the calling strategy:

- The clone calls `createLaunch` (clone = creator), receives the minted supply, transfers `reserveAmount` to the strategy, approves and `arm`s the remainder onto the pad.
- Every later verb (`finalize` → `graduate`/`bond`, `collectFees` → `flushCreatorQuote` + forward, recovery → `abort` while trade-free) is `onlyOwner` (the strategy) on the clone.
- The **implementation** contract is what `TierRegistry.setAdapterAllowed` snapshots; the strategy verifies a clone by `ERC1167` target introspection against the allowed implementation, mirroring how `StrategyFactory` clones approved templates. This keeps the registry gate meaningful without allowlisting every ephemeral clone.

The `ILaunchAdapter` spec deliberately does not say "singleton" or "clone" — it says the custody invariant, and each implementation states how it meets it. That is the seam Uniswap/Bankr adapters will slot into.

## Decision 3 — the launch is capital deployment; the claim is a dividend, not a redemption burn

v1 is **dividend-in-kind**: holders keep their shares and claim fund tokens from the reserve. Burn-to-redeem (shares → tokens, shrinking the fund) is rejected for v1 because share supply is the governor's voting base and the queue's pricing base — burning mid-proposal interacts with `VaultWithdrawalQueue`'s single-realized-price invariant and the checkpointed vote balances, a much larger blast radius than this template justifies. The ticket keeps burn-to-redeem as an explicit v2 question.

Claim math: `claimable(h) = reserve × getPastVotes(h, snap) / getPastTotalSupply(snap)`, claimed at most once per holder, window-bounded. This works without new snapshot machinery because the vault is `ERC20VotesUpgradeable` with `clock() = timestamp` and `_update` auto-self-delegates every undelegated recipient (`src/SyndicateVault.sol:1488`; normative in `openspec/specs/syndicate-vault/spec.md`), so past votes equal past balance for everyone who never delegated.

Two known edges, resolved as follows:
- **Queue-escrowed shares** at the snapshot belong to `VaultWithdrawalQueue`, not the user. v1 excludes them (the queue contract never calls `claim`), and the excluded weight stays unclaimed — at settle it stays as unpriced fund tokens warehoused in the vault under the owner-gated rescue surface, not as value returned, and it is not redistributed to other holders. Rationale: attribution-through-the-queue requires reading queue internals the strategy has no interface for.
- **Explicit delegators**: the claim follows the vote. Documented, not corrected — `ERC20Votes` has no historical balance checkpoint and adding one to the vault is out of scope.

Snapshot instant: **execute time** (the moment capital leaves the vault), not init time. Between init and execute the proposal is public and votable; an init-time snapshot would let the proposer freeze the claimant set before depositors can react to the proposal, and execute-time matches how the vault prices the cycle. The timestamp is read once in `_execute` and immutable thereafter.

## Decision 4 — settlement and residue: the template holds a token the protocol must refuse to price

`BaseStrategy`'s delivery-view defaults (`false/0/false`) are only sound for all-or-revert settlement. This template *by construction* can hold fund tokens (unclaimed reserve, fee-collected tokens) and possibly quote tokens at settle. Posture, following `docs/nav-residue-design.md` and the `ConcentratedLiquidityStrategy` precedent:

- `_settle()` returns everything already expressible in the vault asset: quote-asset balances are swapped back through the allowlisted `ISwapAdapter` (when quote ≠ vault asset) and pushed; collected creator-fee quote likewise. It never sells the fund token into its own launch pool inside the settle tx — that price is attacker-movable within the transaction, which is exactly the finding-#3 shape.
- After settle, `hasUnvaluedResidue()` is `true` while the strategy holds fund tokens above `RESIDUE_DUST`; `undeliveredValue()` counts only vault-asset-denominated balances still in custody; `hasUndeliveredValue()` accordingly. All three never revert and read no movable price.
- `sweep()` (`onlyVault`, `Settled`-only) is the recovery lane `SyndicateVault.collectResidue` drives: push remaining vault-asset value, and — the deliberate policy choice — transfer remaining fund tokens to the **vault owner's custody path** is *not* done; fund tokens remain sweep-transferable to the vault itself, where the owner's existing `rescueERC20` governs them. The vault never *prices* them; it only warehouses them.
- Claim window vs settle ordering: claims are only open in `Executed` and only up to the clamped `windowEnd`; `settle()` requires `windowEnd` to have passed, *except* that it never reverts on that gate once anyone-settle is open (below). A claim can therefore never race the residue accounting, and the window can never outlast the proposal.
- Post-settlement, `hasUnvaluedResidue()` **latches** false on its first post-settlement false reading — however custody cleared, sweep or not — while `undeliveredValue()` stays honest (latching a vault-asset figure on a fund-token observation would be the finding-#3 skim), and no post-settlement value transits strategy custody: on Sushi the creator role goes to the vault at settle (`transferCreator`), on Stonk the clone's `forwardToVault()` becomes permissionless. Reason: a strategy that truthfully clears and then truthfully reports residue again is re-markable by permissionless `collectResidue`, and each re-mark re-stamps a 7-day deposit lock — the `_unvaluedBurned` guard only blocks re-marking after a prune. `sweep()` also stays balance-only (no venue calls) because the vault runs it under a hard 1.5M gas cap and ignores its result.
- **StonkBrokers un-graduated at settle**: if `phase()` is still `Curve`/`Closing` when settlement comes due, `_settle` does not force an exit (the pad's `SellExceedsCurve` cap means the strategy can sell at most what it dev-bought, and an un-graduated curve holds the arm'd supply). It settles what is expressible, leaves the adapter clone holding its creator position, and the strategy reports unvalued residue until a later `sweep()`/`finalize()` resolves the launch. This is the deliverable-maximum doctrine, not a failure.

### Why the claim window is clamped at execute, not bounded at init

An init-time static bound cannot do this job: `initialize` runs when the clone is created, *before* the proposal that will carry it exists, so the strategy cannot know the `strategyDuration` it will be executed under. The only universally safe static bound would be `MIN_STRATEGY_DURATION_BEFORE_SELF_SETTLE` (1 hour), which makes the feature useless. So the window is clamped where the proposal is finally known — at execute: `windowEnd = min(executedAt + configuredWindow, executedAt + strategyDuration − CLAIM_SETTLE_BUFFER)`.

Two caveats travel with that read. The pid must be **cached at execute**: `IProposalStatus.getActiveProposal()` names the proposal only while it is `Executed` and reads 0 after settlement, so a lazy read later finds nothing. And the `getProposal(pid)` struct decode is **upgrade-fragile** — `ISyndicateGovernor.sol:97-99` already carries that warning; a governor that reorders the struct silently changes what the strategy reads. The clamp is therefore paired with a backstop that needs no *fresh* governor read: `settle()` never reverts on the window gate once `block.timestamp >= executedAt + strategyDuration`, the same predicate the governor uses to open anyone-settle (`SyndicateGovernor.sol:900-903`). The backstop is not independent of the decode, though — it is built from the same cached struct, so a governor that reorders it poisons clamp and backstop alike. What contains that case is the init-time ceiling `configuredWindow ≤ MAX_CLAIM_WINDOW`: it holds `windowEnd ≤ executedAt + MAX_CLAIM_WINDOW` even with the governor-derived arm of the `min` unusable, capping a wedge at the template's maximum window rather than forever. That backstop is what keeps the failure mode survivable — a strategy whose `settle()` always reverts has *no* permissionless terminal state (`settleProposal` bubbles the revert; `unstick` and `emergencySettleWithCalls` are owner-gated), and pins `openProposalCount() != 0` on the unbounded branch of `depositsLocked()`, locking vault-wide deposits and redemptions permanently.

## Decision 5 — quote-asset routing stays in the strategy, venue constraints stay in the adapter

The vault asset (per-syndicate, WETH or USDG in practice) is rarely the launch quote. The strategy owns the swap: pull vault asset → `ISwapAdapter.swap` into `p.quoteToken` (both adapter and any price source re-certified live, `PortfolioStrategy` doctrine) → hand quote to the launch adapter. The launch adapter owns knowing what quotes its venue accepts (`quoteSupported`): Sushi = feed-registered set; Stonk = the pad lane it was configured for. This keeps "can this venue pair with X" answerable per-adapter — which is where the WOOD asymmetry lives: Sushi *may* gain WOOD by owner action; StonkBrokers structurally cannot, and its native pairing is a stock token.

Native-ETH details absorbed by adapters: Sushi's 0.0005 ETH launch fee is paid by the adapter unwrapping a sliver of quote WETH (the strategy holds no ETH and the governor batch stays value-free); Stonk's launch fee is currently 0.

## Decision 6 — registry gates, enumerated

- Both adapter implementations: `TierRegistry.setAdapterAllowed` + certification (Gate A/Gate B per `docs/adapter-onboarding-checklist.md`). Strategy re-checks `isAdapterAllowed` live at `_initialize` (fail closed, registry-unresolved also fails closed at init) and `_execute` (fail closed); `_settle` is never gated.
- Counterparty axis: the Sushi launchpad address, each Smart Launch pad the deployment will use, and the lens. The fund token itself is *not* counterparty-allowed — the strategy holds it as inventory, never calls it beyond ERC-20.
- The `ISwapAdapter` used for quote routing rides the existing allowlist unchanged.

## Open Questions (blocking implementation, not the spec)

1. **WOOD-on-Sushi feed**: who owns the ask to the Sushi owner (`0x6fA4…4657`), and what do we hand them — the thin-pool `WoodTwapOracle` needs an `AggregatorV3` wrapper and its depth caveats travel with it. Until resolved, Sushi launches spec against WETH quote.
2. **Default economics**: the *default* reserve fraction (the "~10%" from the product framing) and, on Stonk, the `startMcapUsd8`/`gradMcapUsd8`/tax-schedule defaults the CLI will offer. The *bound* is no longer open — review fixed the hard ceiling at `MAX_RESERVE_BPS = 2_000` (20% of launch supply), enforced at init; what remains open is the default the product picks below it.
3. ~~**Stonk never-graduates path**~~ — **RESOLVED on-chain (task 0.1, fork test `StonkLaunchRobinhoodFork.t.sol`): there is no such state.** Timer expiry is itself a graduation trigger (`timerClose = !openEnded && now >= deadline`), so a closed non-open-ended window is one permissionless `graduate()` + `bond()` from a locked LP — mapped to `Closing`, not `Failed`. The creator recovers nothing and nothing is stranded: the armed supply and realized quote were never the creator's, they belong to a close anyone can trigger and which never expires. `Failed` means `aborted`, and `abort` is barred once `buyCount != 0`. The deliverable-maximum reasoning this question carried was solving a problem the venue does not have.
4. ~~**Fee-stream endgame**~~ — **resolved, then simplified further.** The endgame is the **vault**, and the final design does not route fees through the strategy at all: `LaunchParams.feeRecipient` names the vault AT LAUNCH. Routing them through the strategy and forwarding onward meant the destination had to change at settlement, and value resting in a settled strategy is a permissionless deposit-lock lever. Naming the vault up front deletes the lever instead of guarding it — no second lane, no settle-time handoff, no settlement-dependent branch — and leaves the snapshot doing exactly one job, the pro-rata claim on the launch RESERVE. Two consequences are accepted: nothing in-protocol pushes accrued fees (keepers or a later proposal do), and fees arrive in kind and unpriced for governance to dispose of. One constraint follows: the venues bind the payee irrevocably, so on StonkBrokers a vault migration strands the destination; on Sushi the vault holds a transferable creator role, so a governance batch can re-point it.

## Measured venue economics (fork-verified 2026-08-31)

Numbers a proposer needs and the spec previously only implied. All from `SushiLaunchRobinhoodFork.t.sol` / `StonkLaunchRobinhoodFork.t.sol` against live 4663.

- **Sushi's launch pool is the 1% tier (`fee == 10000`)** — not stated anywhere before.
- **Start economics, measured**: a 1,000 USDG dev buy takes ~164.56M tokens, about **16.46% of the float**, implying a starting market cap near **$6.1k**. That is the sizing reference for `reserveAmount` and `minTokensOut`, and it shows why a `minTokensOut` of 1 wei makes the reserve floor vacuous.
- `LaunchInfo.reserveAmount` came back as exactly 3% of the float, confirming `protocolReserveBps` applies to supply.
- **The 70/30 creator split FLOORS**: measured `quoteToSushi / quoteCollected` is 2999 bps, not 3000. The exact invariant is `creatorLeg == collected - toSushi`; "the creator keeps exactly 70%" is wrong at the wei.
- `quoteTokenPriceFeed(WOOD)` was **still zero at head on 2026-08-31** — the WOOD dependency is live, not stale.
- **Fork tests cannot pin a block in source.** Measured block time on 4663 is **0.101s** (~10 blocks/sec), and the public RPC retains roughly 5k–50k blocks — 8 to 83 minutes of state. Any pin written into a file is unreachable before review. Fork tests therefore take the block from `ROBINHOOD_FORK_BLOCK` (0 = latest) and skip entirely without `ROBINHOOD_RPC_URL`.
- **V2 vs V3 pads (task 0.3)**: a bring-your-own token is ACCEPTED on both families — the V2-only pad set is a deliberate choice (the mint path hands the fund its whole supply as a free allocation), not a safety constraint. The V3 build carries a hardened `abort` that only matters for reused external tokens, so it is inert on our mint path.

## Venue 3 — Pons (BUILT IN A SEPARATE PR — #282; gated out of mainnet, tasks.md 0.7)

Investigated at the product owner's request. The adapter itself lives in #282, stacked on this change; the research stays here because it is what justifies the split — the venue is closed to us, so shipping it alongside two mainnet-ready venues would hold them hostage to a third party's decision. All reads are live against mainnet 4663 on 2026-08-30, against the **v2 / "active" factory** (`PonsLaunchFactory`, `0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB`, verified, solc 0.8.30, ~266k transactions). The legacy factory (`0x0c37a24F…`) is v1 and out of scope.

Shape, and how it maps onto `ILaunchAdapter`:

- `launchToken(TokenParams, uint256 launchConfigId, uint256 dexId, bytes32 salt) payable returns (address token)`. The entire supply goes into a one-sided Uniswap-V3 position minted to the factory, then transferred to the locker and locked — so, as on Sushi, **the creator receives zero tokens** and a reserve can only come from the initial buy. The initial buy is funded by `msg.value − launchFee`, i.e. in NATIVE ETH rather than by pulling an ERC-20.
- **The fee recipient is set AT LAUNCH**: `TokenParams.feeWallet` is written straight into the locker via `setFeeRedirect(token, feeWallet)`. There is no creator role to transfer afterwards. This is the cleanest fit of the three venues for the custody invariant — the adapter names the strategy (or the vault) as `feeWallet` and holds no role at any point.
- Live launch config 0 is the only one: `pairToken` = WETH, `supply` = 1e27 (1e9 × 1e18), `graduationThreshold` = 4.2 WETH, `initialTick` = −204200, 5% max wallet / 5.5% max tx for 2 blocks. `pairToken` is per-config, so WETH-only is a CONFIGURATION rather than a protocol constraint — the owner can add configs, which is the hook a future WOOD or stock-token lane would use.
- Uses the chain's canonical Uniswap V3 factory and position manager — the same addresses already in `chains/4663.json`, unlike Sushi which runs its own.

**The blocker, and it shapes the design.** `launchToken` opens with `if (!launchEnabled && !whitelistedLaunchers[msg.sender]) revert NotWhitelisted()`, and `launchEnabled()` reads **false** today. Launching is therefore whitelist-only, and admitting us is an action only the Pons owner (`0x263ed295dAFaE1d9AAdD6E56c4B6F9f38eE019Dd`) can take — the same class of external dependency as the WOOD/USD feed on Sushi, but stricter, because without it NO Pons launch works at all rather than one pairing being unavailable.

That gate also settles the adapter's shape before we write a line of it: whitelisting is **per address**, so a per-launch clone pattern is impossible — every clone would need its own whitelist entry. A Pons adapter MUST be a singleton, and fortunately `feeWallet` makes a singleton correct anyway (it names the payee at launch and keeps nothing), so this is the `SushiLaunchAdapter` shape rather than the `StonkLaunchAdapter` one.

Consequences worth carrying into the build:
1. Get `setWhitelistedLauncher(adapter, true)` agreed before implementation, and note that it pins the adapter address — a re-deploy needs re-whitelisting, which couples our upgrade cadence to theirs. Worth asking whether they will instead flip `launchEnabled`.
2. `nativeFeeSource()` names WETH, as on Sushi, but the adapter must unwrap `launchFee + quoteIn` (the initial buy is native too), not just the fee.
3. Fork tests can prank the Pons owner to whitelist, so the venue is testable before the business ask lands.
