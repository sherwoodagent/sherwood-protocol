# Tokenize-Fund Strategy Template + Launch Adapters

Linear: SHE-153. Spec-only change — this PR is the design for review; implementation follows after feedback.

## Why

A Sherwood fund's only liquidity today is the vault's own deposit/redeem queue, priced once per proposal cycle. The stated product direction ([@sherwoodagent, 2026-08-19](https://x.com/sherwoodagent/status/2090119901918769290)) is that "every agentic fund can have its own LP pool" and that "agents within a fund can choose to 'IPO' onchain" — a secondary market per fund, with the deposit queue no longer the only exit.

A `TokenizeFundStrategy` lets an agent propose exactly that: launch a fund token on a launchpad, seed it with vault capital, hold back a reserve, and let share holders claim a pro-rata slice of the reserve. The launch venue is pluggable through a new `ILaunchAdapter` surface, the same way `PortfolioStrategy` is venue-agnostic through `ISwapAdapter`.

Live venue data on Robinhood Chain (measured 2026-08-22/26, both from verified explorer source and `cast` against mainnet 4663) shapes the design and makes the abstraction non-trivial — the two launch targets are *structurally different*, not two skins of one flow:

- **Sushi Launchpad V1** (`0x104f1ab42674565ec3df0bfebccc4186f72fa7ed`, 2,366 launches): fixed 1B supply minted to the launchpad, fixed $5,000 initial FDV priced off a Chainlink-style quote-token feed, 97% of supply into a one-sided SushiSwap-V3 1% position owned by the launchpad, 3% protocol reserve to Sushi. **The creator receives zero tokens at launch** — a redemption reserve can only be a same-tx dev buy (`launchAndBuy`) funded from vault capital. The creator role is transferable (`transferCreator`) and earns 70% of LP fees via permissionless `distributeFees`. **WOOD is not a supported quote token** (`quoteTokenPriceFeed(WOOD) == 0`); registering it is a Sushi-owner action gated on a WOOD/USD aggregator existing.
- **StonkBrokers Smart Launch V2/V3 pads** (one `StonkSafeLaunchpadV2` per quote lane, 16 pads; lens `SafeLaunchLensV2` at `0x25b5…15B3`): `createLaunch(token = 0)` mints a fresh fixed-supply token **to the creator**, who then `arm`s the curve with a chosen portion of supply — **a redemption reserve is a true allocation, no dev buy**. Creator prices the launch (`startMcapUsd8` $1k–$1M, `gradMcapUsd8` $50k–$10M live bounds), the curve trades with anti-snipe tax schedules, and graduation → permissionless `bond()` mints a **locked** LP. **No `transferCreator` exists** — the creator role (fee recipient, sole `arm`/`abort` caller) is pinned to whoever called `createLaunch`, which rules out a stateless singleton adapter. Quote lanes are fixed per pad (WETH / STONK / USDG / GME / NVDA / AAPL / SPCX / USO): **pairing with WOOD is impossible on this venue**; pairing with a stock token is native. Stock lanes revert `StalePrice` when the stock oracle gaps (weekends) — settlement-adjacent trading must tolerate that.

Designing the adapter surface against only one of these would bake that venue's shape into the strategy (the mistake `ISwapAdapter` avoided). Both are therefore in scope for v1; Uniswap and Bankr adapters are out of scope but must slot into the same interface.

## What Changes

- **New capability `launch-adapters`**: `src/interfaces/ILaunchAdapter.sol`, a lifecycle-shaped venue abstraction (`launch → state → finalize → collectFees`), plus two implementations:
  - `src/adapters/SushiLaunchAdapter.sol` — stateless singleton fronting Sushi Launchpad V1 (creator role handed to the strategy via `transferCreator`).
  - `src/adapters/StonkLaunchAdapter.sol` — an ERC-1167-cloned, per-launch adapter owned by its strategy, fronting the Smart Launch V2/V3 pads (creator role is the clone itself; the clone is the custody boundary).
  - Both gated by the existing `TierRegistry` dual gate (`isAdapterAllowed` codehash snapshot + tier certification) and the counterparty axis for the venue contracts, per `docs/adapter-onboarding-checklist.md`.
- **New capability `tokenize-fund-strategy`**: `src/strategies/TokenizeFundStrategy.sol`, a `BaseStrategy` clone template:
  - `execute()` — pull vault capital, optionally swap into the launch quote asset through the allowlisted `ISwapAdapter`, drive `ILaunchAdapter.launch`, record the snapshot timestamp.
  - A **claim window** in which snapshot share holders claim `reserve × getPastVotes(holder, snap) / getPastTotalSupply(snap)` of the retained fund-token reserve (dividend-in-kind; shares are not burned in v1).
  - `settle()` — return quote-asset proceeds and collected creator fees to the vault, and hand the *ongoing* fee stream to the vault itself (Sushi: `transferCreator` to the vault; Stonk: the clone's `forwardToVault()` goes permissionless), so no post-settlement value re-enters strategy custody; declare any remaining fund-token custody through the `IStrategyDelivery` views (`hasUnvaluedResidue`, latching false once cleared) with a balance-only `sweep()` recovery path, per `docs/nav-residue-design.md`.
- **Modified capability `deployment-docs`**: the deploy ceremony gains a template + adapters script for mainnet 4663 (the only chain where both venues exist), the registry runbook asserts, and new address-book entries (`SUSHI_LAUNCHPAD_V1`, Sushi V3 factory/NFPM, the Smart Launch pad set, `SAFE_LAUNCH_LENS_V2`).

Deliberately **not** in this change: CLI hookup and user docs (separate PR in the sherwood repo once this spec settles), Uniswap/Bankr/Stonk-Launcher-factory adapters (the factory's curve is EOA-only and unusable by a strategy contract), secondary-market making after launch, buybacks, burn-to-redeem.

## Capabilities

### New Capabilities

- `launch-adapters`: the `ILaunchAdapter` lifecycle contract, the custody rules every implementation must satisfy (reserve, fee stream, and recovery levers must end at the strategy), and the two v1 implementations with their venue-specific constraints.
- `tokenize-fund-strategy`: the strategy template — lifecycle, snapshot and claim math, quote-asset routing, and the residue/settlement posture for a template that by construction holds a token the protocol cannot price.

### Modified Capabilities

- `deployment-docs`: deploy ceremony + post-deploy validation reads for the template and both adapters; address-book additions for both venues.

## Impact

**New code**
- `src/interfaces/ILaunchAdapter.sol`
- `src/adapters/SushiLaunchAdapter.sol`, `src/adapters/StonkLaunchAdapter.sol`
- `src/strategies/TokenizeFundStrategy.sol`
- `src/vendor/sushi/ISushiLaunchpad.sol`, `src/vendor/stonkbrokers/IStonkSafeLaunchpadV2.sol` + `ISafeLaunchLensV2.sol` (reduced-surface vendored interfaces with provenance headers, per the `src/vendor/` convention)
- `script/robinhood-mainnet/DeployTokenizeFundStrategy.s.sol`
- Tests: template suite (init-lock, clone-ratchet, live proposer re-check, delivery views), claim-math invariants, adapter allowlist harness, mainnet-4663 fork tests against both live venues.

**Touched state / config (deploy-time only, no contract changes)**
- `StrategyFactory.setTemplateApproval(template, true)`
- `TierRegistry`: `setAdapterAllowed` + certification for both adapters (for `StonkLaunchAdapter`, the *implementation* codehash — see design Decision 2), counterparty-allow for the Sushi launchpad and each Smart Launch pad used
- `chains/4663.json`, `addresses/4663.json`

**Not touched**: `SyndicateVault`, `SyndicateGovernor`, `BaseStrategy`, existing templates and adapters. The template is additive.

**External dependencies / blockers carried as open questions**
1. SHARE/WOOD pairing on Sushi requires the Sushi owner to register a WOOD/USD feed (`setQuoteTokenPriceFeed`) — business conversation, tracked in SHE-153. Until then Sushi launches pair against WETH; StonkBrokers launches pair against a stock token / WETH / USDG by construction.
2. The StonkBrokers never-graduates failure path (curve closes below `gradMcapUsd8`) must be verified on-chain before implementation — it determines the adapter's recovery lever (design Open Question 3).
