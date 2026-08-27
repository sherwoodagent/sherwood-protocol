# Design — TokenizeFundStrategy + Launch Adapters

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
    function launchTarget() external view returns (address);
}
```

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
- **Queue-escrowed shares** at the snapshot belong to `VaultWithdrawalQueue`, not the user. v1 excludes them (the queue contract never calls `claim`), and the excluded weight stays unclaimed and returns to the vault at settle — it is not redistributed to other holders. Rationale: attribution-through-the-queue requires reading queue internals the strategy has no interface for.
- **Explicit delegators**: the claim follows the vote. Documented, not corrected — `ERC20Votes` has no historical balance checkpoint and adding one to the vault is out of scope.

Snapshot instant: **execute time** (the moment capital leaves the vault), not init time. Between init and execute the proposal is public and votable; an init-time snapshot would let the proposer freeze the claimant set before depositors can react to the proposal, and execute-time matches how the vault prices the cycle. The timestamp is read once in `_execute` and immutable thereafter.

## Decision 4 — settlement and residue: the template holds a token the protocol must refuse to price

`BaseStrategy`'s delivery-view defaults (`false/0/false`) are only sound for all-or-revert settlement. This template *by construction* can hold fund tokens (unclaimed reserve, fee-collected tokens) and possibly quote tokens at settle. Posture, following `docs/nav-residue-design.md` and the `ConcentratedLiquidityStrategy` precedent:

- `_settle()` returns everything already expressible in the vault asset: quote-asset balances are swapped back through the allowlisted `ISwapAdapter` (when quote ≠ vault asset) and pushed; collected creator-fee quote likewise. It never sells the fund token into its own launch pool inside the settle tx — that price is attacker-movable within the transaction, which is exactly the finding-#3 shape.
- After settle, `hasUnvaluedResidue()` is `true` while the strategy holds fund tokens above `RESIDUE_DUST`; `undeliveredValue()` counts only vault-asset-denominated balances still in custody; `hasUndeliveredValue()` accordingly. All three never revert and read no movable price.
- `sweep()` (`onlyVault`, `Settled`-only) is the recovery lane `SyndicateVault.collectResidue` drives: push remaining vault-asset value, and — the deliberate policy choice — transfer remaining fund tokens to the **vault owner's custody path** is *not* done; fund tokens remain sweep-transferable to the vault itself, where the owner's existing `rescueERC20` governs them. The vault never *prices* them; it only warehouses them.
- Claim window vs settle ordering: claims are only open in `Executed`; `settle()` requires the window to have elapsed (or the proposal's settle gate to have passed, whichever is later within the proposal's `strategyDuration`). A claim can therefore never race the residue accounting.
- **StonkBrokers un-graduated at settle**: if `phase()` is still `Curve`/`Closing` when settlement comes due, `_settle` does not force an exit (the pad's `SellExceedsCurve` cap means the strategy can sell at most what it dev-bought, and an un-graduated curve holds the arm'd supply). It settles what is expressible, leaves the adapter clone holding its creator position, and the strategy reports unvalued residue until a later `sweep()`/`finalize()` resolves the launch. This is the deliverable-maximum doctrine, not a failure.

## Decision 5 — quote-asset routing stays in the strategy, venue constraints stay in the adapter

The vault asset (per-syndicate, WETH or USDG in practice) is rarely the launch quote. The strategy owns the swap: pull vault asset → `ISwapAdapter.swap` into `p.quoteToken` (both adapter and any price source re-certified live, `PortfolioStrategy` doctrine) → hand quote to the launch adapter. The launch adapter owns knowing what quotes its venue accepts (`quoteSupported`): Sushi = feed-registered set; Stonk = the pad lane it was configured for. This keeps "can this venue pair with X" answerable per-adapter — which is where the WOOD asymmetry lives: Sushi *may* gain WOOD by owner action; StonkBrokers structurally cannot, and its native pairing is a stock token.

Native-ETH details absorbed by adapters: Sushi's 0.0005 ETH launch fee is paid by the adapter unwrapping a sliver of quote WETH (the strategy holds no ETH and the governor batch stays value-free); Stonk's launch fee is currently 0.

## Decision 6 — registry gates, enumerated

- Both adapter implementations: `TierRegistry.setAdapterAllowed` + certification (Gate A/Gate B per `docs/adapter-onboarding-checklist.md`). Strategy re-checks `isAdapterAllowed` live at `_initialize` (fail closed, registry-unresolved also fails closed at init) and `_execute` (fail closed); `_settle` is never gated.
- Counterparty axis: the Sushi launchpad address, each Smart Launch pad the deployment will use, and the lens. The fund token itself is *not* counterparty-allowed — the strategy holds it as inventory, never calls it beyond ERC-20.
- The `ISwapAdapter` used for quote routing rides the existing allowlist unchanged.

## Open Questions (blocking implementation, not the spec)

1. **WOOD-on-Sushi feed**: who owns the ask to the Sushi owner (`0x6fA4…4657`), and what do we hand them — the thin-pool `WoodTwapOracle` needs an `AggregatorV3` wrapper and its depth caveats travel with it. Until resolved, Sushi launches spec against WETH quote.
2. **Default economics**: reserve fraction (the "~10%" from the product framing), and on Stonk the `startMcapUsd8`/`gradMcapUsd8`/tax-schedule defaults the CLI will offer. Proposal-level knobs either way; defaults are a product decision.
3. **Stonk never-graduates path**: confirm on-chain what `closing` permits (curve closed, `!graduated`) — specifically whether the creator can recover arm'd supply or realized quote after a failed window with buys present (`abort` requires zero buys). The answer decides whether `LaunchPhase.Failed` maps to a recovery verb or to permanent-residue documentation.
4. **Fee-stream endgame**: after the strategy settles and (on Sushi) the vault could hold the creator role — leave the stream with the settled strategy + sweep, hand to the vault, or a protocol treasury? v1 default: stays claimable through the strategy's `collectFees`/`sweep` path.
