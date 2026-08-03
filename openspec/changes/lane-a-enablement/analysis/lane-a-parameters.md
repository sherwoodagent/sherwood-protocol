# Lane A Parameter Analysis — Robinhood Chain (4663)

Workstream C deliverable (design D3 / D8, tasks 4.1–4.5). Quantifies the instant-exit
oracle-vs-execution arbitrage and derives per-token `instantCap`, fee, and gating
recommendations for mainnet Lane A enablement.

## Snapshot provenance

| Item | Value |
|---|---|
| Chain | Robinhood Chain mainnet, chain id 4663 |
| RPC | `https://rpc.mainnet.chain.robinhood.com` |
| Pinned block | **25,280,017** |
| Block timestamp | 1785611465 = **2026-08-01 19:11:05 UTC (Saturday — US equity markets closed)** |
| Method | All prices/quotes are read-only `eth_call`s (`cast call --block 25280017`); no transactions, no fork build |
| Off-chain sources | Chainlink reference-data-directory (`feeds-robinhood-mainnet.json`, fetched 2026-08-01), GeckoTerminal API network slug `robinhood` (pool liquidity / 24h volume — **indicative only, not at the pinned block**) |

The Saturday timestamp is deliberate context, not an accident of scheduling: it captures
the 24/5 equity feeds in their "hold last price" weekend regime (all four equity feeds
last updated Fri 2026-07-31 evening UTC, ages 19.2–22.2 h at the snapshot) while DEX pools
kept trading — a live measurement of the exact staleness regime the adversary model
stresses.

---

## 1. Headline findings

1. **Chainlink equity push feeds EXIST on Robinhood Chain — feed availability does NOT
   block Workstream A.** Chainlink's RDD lists **56 feeds** on 4663, including **34
   "Robinhood <TICKER> / USD" tokenized-equity feeds** (AAPL, AMD, AMZN, ASML, BABA,
   CLSK, COIN, CRCL, CRWV, DELL, EWY, GME, GOOGL, INTC, IONQ, META, MSFT, MSTR, MU,
   NBIS, NVDA, ORCL, PLTR, QQQ, RGTI, RKLB, SGOV, SLV, SNDK, SPCX, SPY, TSLA, TSM,
   USAR, USO). All are AggregatorV3, 8 decimals, **heartbeat 86400 s (24 h), deviation
   threshold 0.5 %**. The four feeds relevant to the liquid basket set were verified
   on-chain at the pinned block (`description()`, `decimals()`, `latestRoundData()`).
   Feeds report **total-return value** (underlying price × the token's `uiMultiplier()`;
   currently `1e18` = 1.0 for TSLA/AAPL, verified on-chain).

2. **The instant-exit fee currently defaults to 0 — enabling Lane A without first calling
   `setInstantExitFeeBps(200)` is an immediate, riskless arbitrage.** The fee is
   `SyndicateVault.instantExitFeeBps` (`src/SyndicateVault.sol:183`), owner-set via
   `setInstantExitFeeBps` (`:673`), capped by
   `MAX_INSTANT_EXIT_FEE_BPS = 200` (2 %, `:96`), **never initialized — storage default
   0**, and no deploy script sets it. At the snapshot the TSLA oracle mark sat **~40 bps
   above** its deepest pool: with fee = 0, any pre-existing LP exit is paid ~40 bps above
   what the vault can realize, at every size.

3. **The fee is charged only on the strategy-pulled portion** (`_exitPenalty`,
   `src/SyndicateVault.sol:1424` — "Charged on the PULLED portion only"; spec scenario
   "An exit served entirely from idle balance pays no penalty"). An exit absorbed by idle
   float pays **zero** fee yet is still paid at the oracle mark — the fee lever does not
   cover basis harvesting on float-served exits at all (§5, residual risk R1).

4. **Weekend/off-hours basis is real and measured**: at the Saturday snapshot,
   oracle-vs-pool-mid basis was **TSLA +40 bps (adverse), NVDA +10 bps, AAPL −44 bps,
   AMD −40 bps** (positive = oracle above pool = exit-adversary-profitable direction).
   Within the 0.5 % deviation bound this time — but off-hours drift is structurally
   unbounded by the feed (it cannot update against a closed market), so Lane A must be
   gated shut off-hours (§5).

5. **AMD is not Lane-A-viable**: its only real USDG pool (~$34 k liquidity, 1 % fee tier)
   exhausts near $9.3 k — total executable depth is under $10 k. Exclude it.

6. **The July "native-paired v4 pools are the deepest routes" assumption is dead.** The
   stock→native(5 %)→USDG two-hop routes hard-coded as the CLI agent's default deep-route
   set (see `test/integration/strategies/UniswapAdapterRobinhoodFork.t.sol:31-34`,
   verified 2026-07-06) now exhaust at ~$8 k (AAPL leg) and are dominated at every size
   by direct stock/USDG 0.3 % pools (v4) and, for NVDA, the v3 0.05 % pool. Unwind
   `swapExtraData` routes frozen at proposal review must be re-verified against current
   depth, and Workstream A's fork tests should pin the direct-pool routes below.

7. **Token name marker drift**: on-chain names are `"Tesla • Robinhood Token"` etc., NOT
   `"<X> (Robinhood Tokenized Stock)"`. Any tooling using the old name marker as a
   deterministic RWA classifier will silently match nothing.

---

## 2. Instruments, feeds, pools (task 4.1)

All tokens 18 decimals; USDG (`Global Dollar`) 6 decimals. USDG/USD feed read
1.00018032 at the snapshot; USDG is treated as $1 throughout (≤ 1.8 bps error).

| Token | Address | Oracle feed (8 dec) | Feed mark @ block | Feed age @ block |
|---|---|---|---|---|
| TSLA `Tesla • Robinhood Token` | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` | RHTSLA/USD `0x4A1166a659A55625345e9515b32adECea5547C38` | $309.40255 | 22.2 h |
| AAPL `Apple • Robinhood Token` | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | Robinhood AAPL/USD `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` | $306.37855 | 21.8 h |
| NVDA `NVIDIA • Robinhood Token` | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | RHNVDA/USD `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` | $199.06800 | 21.3 h |
| AMD `AMD • Robinhood Token` | `0x86923f96303D656E4aa86D9d42D1e57ad2023fdC` | RHAMD/USD `0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72` | $472.14405 | 19.2 h |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | USDG/USD `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` | $1.00018 | 3.9 h |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | ETH/USD `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` | $1,832.53 | 14 min |

Principal pools (liquidity / 24 h volume from GeckoTerminal at fetch time — indicative;
v4 PoolKeys recovered deterministically by matching `keccak256(abi.encode(PoolKey))`
against GeckoTerminal v4 pool ids):

| Token | Best venue(s) | PoolKey / pool | Liq (USD) | Vol 24h |
|---|---|---|---|---|
| TSLA | v4 TSLA/USDG **0.3 %** (fee 3000, ts 60, hookless) | id `0x8517f8…d32e` | $350 k | $71 k |
| TSLA | v3 TSLA/USDG 0.3 % | `0xf4acdaeeb7022862a763c9b1b885e11191c889e3` | $100 k | $92 k |
| AAPL | v4 USDG/AAPL **0.3 %** (3000/60, hookless) | id `0xc748f4…8fdb` | $433 k | $230 k |
| NVDA | v3 NVDA/USDG **0.05 %** | `0xd4eb21209c4d6093f80b5b84f5c45cc093ea14a3` | $764 k | $1.77 M |
| NVDA | v4 USDG/NVDA 0.3 % (3000/60, hookless) | id `0x3bb34a…4bf1` | $1.57 M | $219 k |
| AMD | v4 USDG/AMD **1 %** (10000/200, hookless) | id `0xde9f85…1274` | $34 k | $13 k |
| (legacy route) stock/native 5 % (50000/1000) + native/USDG (500/10, 460/9) | — | see §1 finding 6 | thin | — |

Venue infra (from `test/integration/RobinhoodMainnetIntegrationTest.sol`, exercised
live here): Uniswap v3 QuoterV2 `0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7`, v4 Quoter
`0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94`, v4 PoolManager
`0x8366a39CC670B4001A1121B8F6A443A643e40951`. Morpho Blue
`0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010` verified to have code at the pinned block.

## 3. Slippage curves (task 4.2) — MEASURED

Sell direction stock → USDG (the instant-exit unwind direction), exact-input quotes at
block 25,280,017 via QuoterV2 / V4Quoter `eth_call`. `slip_meas` is execution vs the
**oracle mark** (the number the adversary model consumes directly);
`slip_neutral = slip_meas − basis_now` removes the snapshot's momentary oracle-vs-pool
basis, leaving LP fee + price impact (the depth-only cost, used for cap sizing).
`basis_now` (oracle − pool mid, **estimated** from the $1 k quote minus the route's LP
fee): TSLA **+40 bps**, AAPL **−44 bps**, NVDA **+10 bps**, AMD **−40 bps**.

| Size (USD) | TSLA slip_meas / neutral | AAPL slip_meas / neutral | NVDA slip_meas / neutral | AMD slip_meas / neutral |
|---:|---:|---:|---:|---:|
| 1,000 | 70.5 / 30.0 | −14.4 / 30.0 | 15.1 / 5.0 | 60.4 / 100.0 |
| 5,000 | 85.5 / 45.0 | −9.5 / 34.9 | 18.5 / 8.4 | 100.6 / 140.2 |
| 10,000 | 103.1 / 62.6 | −3.4 / 41.0 | 19.7 / 9.6 | 651.9 / 691.5 |
| 25,000 | 148.6 / 108.1 | 15.0 / 59.4 | 21.5 / 11.4 | 6,260.7 / — (pool exhausted at ~$9.3 k out) |
| 50,000 | 223.1 / 182.6 | 46.1 / 90.5 | 23.9 / 13.8 | — |
| 100,000 | 660.0 / 619.5 | 127.2 / 171.6 | 47.7 / 37.6 | — |
| 150,000 | — | 477.7 / 522.1 | 91.5 / 81.4 | — |
| 200,000 | — | 2,742 (exhausting) | 142.3 / 132.2 | — |
| 300,000 | — | — | 289.0 / 278.9 | — |

Intermediate measured points (fine grid): TSLA 15 k → 118.6/78.1, 20 k → 133.7/93.2,
30 k → 163.5/123.0, 40 k → 193.0/152.5, 60 k → 271.4/230.9, 75 k → 387.7/347.2;
AAPL 75 k → 79.6/124.0; AMD 2 k → 70.5/110.1, 4 k → 90.6/130.2, 6 k → 115.0/154.6,
8 k → 224.3/263.9.

Best routes: TSLA v4-3000 (v3-3000 comparable to ~$5 k); AAPL v4-3000; NVDA v3-500 to
~$200 k then v4-3000; AMD v4-10000 only. Numbers are best **single-route** execution —
split-routing would do slightly better, so the impact figures are mildly conservative.

## 4. Adversary model and break-evens (task 4.3)

Model (design D8): the exiter is paid at the oracle mark; the vault unwinds at execution.

```
profit(s) = s · (oracle_mark / execution_value − 1) − s · instantExitFeeBps/10⁴
          ≈ s · (slip_neutral(s) + b) − s · fee            b = adverse oracle basis (bps)
```

Safety condition with the required ≥ 25 % margin: `slip_neutral(s) + b ≤ 0.8 · fee`.
With `fee = 200 bps` (the hard maximum): `slip_neutral(s) ≤ 160 − b`.

Break-even exit sizes (largest s with adversary profit ≤ 0 at 25 % margin, linear
interpolation between measured grid points):

| Stress b | Interpretation | TSLA | AAPL | NVDA | AMD |
|---|---|---:|---:|---:|---:|
| 50 bps | feed fresh, within its 0.5 % deviation bound (market hours, gates live) | **$25.6 k** | **$64.5 k** | **$178 k** | $2.0 k |
| 100 bps | deviation bound + drift ≈ adapter divergence-gate tolerance | **$9.3 k** | **$25.5 k** | **$126 k** | $0 |
| 200 bps | stale-mark regime (off-hours / gate absent) | $0 | $0 | $0 | $0 |
| any b, fee = 0 (current default) | adversary profitable at any size whenever adverse basis > LP fee + impact | $0 | $0 | $0 | $0 |

Readings:

- **The 200 bps fee ceiling cannot cover the stale-oracle regime** (row 3): if the mark
  can be 200 bps off, no size is safe. Lane A safety therefore rests on the adapter's
  staleness + divergence gates keeping `b` small, not on the fee alone.
- With gates holding `b ≲ 100 bps`, the fee ceiling supports economically meaningful
  caps on NVDA/AAPL and a small cap on TSLA.
- AMD never clears the bar (its pool's own 1 % LP fee eats half the fee wedge).

## 5. Required gates and residual risks

**G1 — `instantExitFeeBps = 200` before any Lane A enablement.** Mandatory; default is 0
(finding 2). Deploy script must set and assert it.

**G2 — `haircutBps = 0` for every Lane-A-enabled kind (`ERC20_SPOT`,
`MORPHO_BLUE_SUPPLY`) — CONFIRMED and re-affirmed.** `PriceRouter.setHaircutBps`'s own
natspec (`src/pricing/PriceRouter.sol:137-155`) documents the one-sided asymmetry: the
haircut marks the single `totalAssets()` both directions consume, so on deposit it mints
against understated NAV — a wealth transfer to Lane A depositors. Per design D3 the
slippage cost is carried by `instantCap` + the instant-exit fee instead. The deploy
script must assert `haircutBps[kind] == 0`; note `setHaircutBps` is
monotone-increasing (`HaircutCannotDecrease`), so a nonzero haircut is a one-way door —
never set it "temporarily".

**G3 — feed staleness gate (`maxAge`) ≤ 24 h, and off-hours closure is load-bearing.**
The feeds' heartbeat is 24 h; `maxAge = 24 h` in the adapter registry guarantees Lane A
closes by Saturday evening each weekend (measured ages 19–22 h on Saturday afternoon
confirm the trajectory). But a 24 h `maxAge` still leaves Lane A open Friday evening →
Saturday afternoon on frozen Friday-close marks while pools trade — the measured
regime of this snapshot (b up to ±44 bps this calm weekend; unbounded around
earnings/news). A tighter `maxAge` cannot fix this without also closing Lane A during
calm market hours (deviation-triggered feeds legitimately go hours without pushing).
Therefore:

**G4 — adapter divergence (sanity) gate, tolerance ≤ 100 bps.** `Erc20SpotAdapter`
should cross-check the Chainlink mark against the position token's primary pool mid
(spot read, e.g. v3 `slot0`/v4 sqrtPrice of the pools in §2) and return `ok = false`
when |oracle − pool| exceeds ~100 bps, failing the vault closed to Lane B. This bounds
`b` to the gate tolerance regardless of market hours, making the b = 100 row of §4 the
binding design point. The proposal already budgets "staleness and sanity gates" for the
adapter; this analysis makes the sanity gate a **requirement for mainnet**, not an
option. (A TWAP or last-trade read is acceptable; the gate is a comparator, not a price
source, so manipulation of the pool can only *close* Lane A — grief, not theft.)

**R1 — SUPERSEDED, both premises implemented as fixes.** This paragraph originally
accepted two residuals for v1: `_exitPenalty` charging only the strategy-pulled
portion, and entry-side timing being "already blocked" by `_laneALockPid`. Neither
holds against the shipped code.

The float-scoped exit fee was closed directly: `_exitPenalty` now charges the WHOLE
exit, unconditionally, whenever Lane A is live — see `SyndicateVault._exitPenalty`.
A float-served exit no longer pays zero fee.

The entry-side claim was actively FALSE, not merely unhardened, and its own
parenthetical names the reason it looks true without being true: `_laneALockPid`
locks entrants "until settlement" — but `SyndicateGovernor.settleProposal` is
PERMISSIONLESS once `strategyDuration` has elapsed. An entrant does not wait for
settlement; they trigger it. `deposit → settleProposal → redeem` in ONE
transaction: the lock expires inside the same call frame that realizes true
prices, so there is no elapsed time, no strategy risk, and no need for
pre-committed capital (flash-loanable). The post-settlement exit additionally
lands in Lane B, paying neither the exit fee this paragraph's own fix relies on
nor any depth cap. This was RISKLESS, not "hold pre-committed capital and eat
strategy risk to wait for an episode" as originally assessed — see audit finding
#14.

Fixed by removing the door rather than pricing it: `SyndicateVault._deposit` now
reverts `DepositsLocked` for ANY instant deposit while a proposal is open, Lane A
live or not. Mid-proposal entry routes through `requestDeposit` (the async queue),
which mints at the realized settlement price and is correctly priced by
construction — the mechanism this whole finding exploited never starts. See
`test/fees/InstantEntryDoorClosed.t.sol` for the regression pin.

(Separately, G4 above — "a TWAP or last-trade read is acceptable; manipulation
of the pool can only *close* Lane A" — undersold the requirement: an
instantaneous `slot0()`/last-trade read is exactly what let an attacker set the
gate's own comparison value inside the transaction consuming it, opening it as
readily as closing it. The shipped adapter reads a TWAP over a fixed window
(`Erc20SpotAdapter.TWAP_WINDOW`); see audit finding #1. Both corrections are
dated 2026-08-02, this session.)

**R2 — residual: `maxSlippageBps` is the last-line bound on unwind execution.**
`PortfolioStrategy` enforces per-leg min-out vs the Chainlink mark
(`MAX_SLIPPAGE_CEILING_BPS = 1000`; init range 1–1000 bps, tighten-only thereafter,
`src/strategies/PortfolioStrategy.sol:96-134,355-361`). For Lane-A-enabled portfolio
strategies set **`maxSlippageBps = 150`**: any unwind leg worse than 150 bps vs the mark
reverts (`UnwindShortfall` — the exit fails rather than remaining LPs eating an outsized
gap), and 150 < 160 = 0.8·fee keeps a reverting bound consistent with the fee margin.
All recommended routes (5–30 bps LP fee) clear 150 bps at the recommended caps; the
legacy 5 % native-hop routes do not — they must not be in Lane-A `swapExtraData`.

## 6. Recommended parameters (task 4.4)

Caps are set from the **b = 100 bps** row (the divergence-gate design point), rounded
down conservatively; the b = 50 row is the upside if operations later demonstrate the
gate holds tighter. All caps in USDG 6-decimal units (vault asset).

**Router-mechanics caveat (important for the deploy script):** `instantCap`,
`laneAEnabled`, and `haircutBps` are keyed **per kind, not per token**
(`src/pricing/PriceRouter.sol:38-46`), and `instantCap` bounds each single **position's
priced value**, failing the whole strategy closed to Lane B when exceeded (`_priceOne`,
`:110-121`). Per-token caps therefore cannot live in the router. Recommendation:
**Workstream A adds a per-token cap to `Erc20SpotAdapter`'s registry** (token →
aggregator, maxAge, cap; over-cap → `ok = false`), and the router-level
`instantCap[ERC20_SPOT]` is set to the largest per-token cap ($100 k) as an outer
backstop. **If the adapter does not get per-token caps, the router cap must instead be
the minimum over allow-listed tokens ($7,500 with TSLA included; $25,000 for an
NVDA+AAPL-only allowlist), or thin tokens must be excluded from Lane-A baskets by
guardian policy.**

Instant-exit fee adequacy verdict: **adequate only at the 200 bps ceiling, only on the
strategy-pulled portion, and only inside the caps below with gates G3+G4 live.**
Inadequate: at its current default (0), in the stale-oracle regime (b ≥ 200 bps), and
for float-served exits (R1). The fee is a wedge-coverage term, not a general defense.

## 7. Go / no-go: two-sided-quote router change

**GO for mainnet Lane A without the two-sided-quote `IPriceRouter` change**, strictly
conditional on: haircut pinned 0 (G2), fee at 200 bps (G1), adapter staleness gate
≤ 24 h (G3) **and** divergence gate ≤ 100 bps (G4), per-token caps per §6,
`maxSlippageBps = 150` for Lane-A portfolio strategies (R2), and AMD (and every token
outside {NVDA, AAPL, TSLA}) excluded from Lane-A baskets pending its own depth analysis.

The two-sided-quote change becomes **required** before any of: raising caps beyond the
b = 50 column, relaxing the divergence gate above ~100 bps, off-hours Lane A, any
nonzero haircut, or if float-served basis harvesting (R1) is observed at material size.
Sizing rationale: a bid/ask spread of ±(basis bound) would replace both the deposit-side
inversion risk and most of R1, at the cost of an interface migration — not justified
while caps keep the exposure under ~$100 k per position.

## 8. Machine-readable parameter table (task 4.5)

Consumable by the group-5 deploy script. `instantCap` in vault-asset units (USDG,
6 decimals). `perTokenCap` is the adapter-registry cap of §6; `instantCap[kind]` is the
single router value. Feed `maxAge = 86400` s (heartbeat); divergence gate 100 bps.

| kind | token | address | feed | perTokenCap (USDG 6-dec) | haircutBps | laneAEnabled recommendation |
|---|---|---|---|---:|---:|---|
| `keccak256("ERC20_SPOT")` | NVDA | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` | `100000000000` ($100,000) | 0 | **yes** |
| `keccak256("ERC20_SPOT")` | AAPL | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` | `25000000000` ($25,000) | 0 | **yes** |
| `keccak256("ERC20_SPOT")` | TSLA | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` | `0x4A1166a659A55625345e9515b32adECea5547C38` | `7500000000` ($7,500) | 0 | **yes** (drop if adapter lacks per-token caps) |
| `keccak256("ERC20_SPOT")` | AMD | `0x86923f96303D656E4aa86D9d42D1e57ad2023fdC` | `0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72` | `0` (excluded) | 0 | **no** |
| `keccak256("MORPHO_BLUE_SUPPLY")` | USDG (supply) | Morpho `0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010` | par (vault asset) | `250000000000` ($250,000, initial ops bound) | 0 | **yes** |

Router-level values: `instantCap[ERC20_SPOT] = 100000000000` **only if** the adapter
enforces the per-token caps above (else `7500000000`, or `25000000000` with TSLA
excluded); `instantCap[MORPHO_BLUE_SUPPLY] = 250000000000`;
`haircutBps[*] = 0` (assert, do not merely set); `SyndicateVault.setInstantExitFeeBps(200)`
before `setLaneAEnabled`; `setLaneAEnabled` last (per migration plan).
Morpho note: no DEX unwind exists for this kind — valuation is view-side share→asset
conversion at par, the wedge is ≈ 0, and under-delivery on a utilization spike reverts
same-tx via the vault's balance-difference check; the cap is an operational bound, not
an arbitrage bound.

## 9. Measured vs assumed

**Measured on-chain at block 25,280,017**: token names/decimals; all feed
descriptions/decimals/answers/timestamps; `uiMultiplier()` (TSLA, AAPL); every
execution quote in §3 (v3 QuoterV2 + v4 Quoter `eth_call`); v4 PoolKey recovery
(keccak match); Morpho Blue code presence.

**Measured off-chain (not block-pinned)**: Chainlink RDD feed list with
heartbeat/deviation configs; GeckoTerminal pool liquidity / 24 h volume.

**Estimated**: `basis_now` per token (from $1 k quote minus route LP fee — accurate to
a few bps, the residual being $1 k-size impact); break-even interpolation between grid
points.

**Assumed**: USDG = $1.000 (feed read 1.00018); adversary achieves the oracle mark
exactly (worst case for LPs); stress values b ∈ {50, 100, 200} bps (b = 50 anchored to
the feeds' documented 0.5 % deviation threshold; b = 100 to the recommended G4 gate;
b = 200 to a gate-absent stale regime); single-route execution (mildly conservative).

**Known gaps**: (1) GeckoTerminal liquidity/volume are point-in-time API values, not
pinned-block state — used only for venue selection, never in the profit math.
(2) Depth was measured on a weekend; market-hours depth is typically equal or better
(volume concentrates then), so caps derived here are conservative, but a market-hours
re-measurement before the mainnet parameter transaction is cheap and recommended.
(3) Only the four fork-test tokens were curve-measured; the other ~30 feed-covered
tokens (SPY, GME, SPCX, HOOD, …) have visible pools and need the same analysis before
allow-listing. (4) Split-route execution and Synthra-venue quotes were not measured
(single best route only). (5) The b = 100 divergence-gate design point assumes
Workstream A implements G4; if it ships staleness-only, re-derive caps from the
stale-regime row (result: no safe caps — Lane A should then not be enabled on ERC20_SPOT).
