# Lane A activation runbook

Operator procedure for enabling instant (Lane A) pricing on a deployment:
`ERC20_SPOT` (tokenized stocks via `Erc20SpotAdapter`) and `MORPHO_BLUE_SUPPLY`
(Morpho Blue supply via `MorphoSupplyAdapter`). The wiring transaction set is
`script/DeployLaneA.s.sol`; the numbers come from
`openspec/changes/lane-a-enablement/analysis/lane-a-parameters.md` (pinned
block 25,280,017). Line references are against `src/pricing/PriceRouter.sol`,
`src/pricing/Erc20SpotAdapter.sol` and `src/SyndicateVault.sol` as of this
commit — re-verify them if the contracts move.

**The one-line rule: `setLaneAEnabled` is the LAST call, always.** Everything
before it — adapters, registry, caps, fee — is inert while the switch is off,
so an interrupted wiring leaves Lane A closed, never half-armed. The script
enforces this order; do not re-order it by hand.

---

## 1. Go-live preconditions (G1–G4, design D9)

All four are hard preconditions. The deploy script asserts each and refuses to
flip the switch otherwise; they are restated here because three of them are
governance-settable later, and un-setting them after enablement re-opens the
corresponding attack.

### G1 — `instantExitFeeBps = 200` on every Lane A vault

`SyndicateVault.instantExitFeeBps` (`src/SyndicateVault.sol:183`) **defaults to
0** and no other deploy path sets it. At fee 0, any resting oracle-vs-pool
basis is a riskless arbitrage: the exiter is paid at the oracle mark while the
vault unwinds at execution (~40 bps adverse basis was measured on TSLA at rest
on a calm weekend). 200 bps is the vault's hard cap
(`MAX_INSTANT_EXIT_FEE_BPS`, `:96`) and the only level at which the analysis'
adversary model clears with margin.

- Setter: `setInstantExitFeeBps(200)` — `onlyOwner` on each vault (`:673`).
- If the deployer does not own a target vault, the script prints the exact
  calldata for the vault owner and **refuses `ENABLE_LANE_A=true`** until the
  fee reads 200 on-chain.
- Verify: `cast call <vault> "instantExitFeeBps()(uint16)"` → `200`.
- Known residual (accepted for v1): the fee is charged on the strategy-pulled
  portion only — an exit served entirely from idle float pays no fee (analysis
  R1). Bounded by G4's 100 bps divergence ceiling.

### G2 — `haircutBps == 0` for both Lane-A kinds, forever

`PriceRouter.setHaircutBps`'s own natspec (`src/pricing/PriceRouter.sol:137-155`)
documents the asymmetry: the haircut marks the single `totalAssets()` both
directions consume. Correct for redemptions; **inverted for deposits** — a
Lane A depositor on a haircut kind mints against understated NAV, a wealth
transfer from existing holders. The setter is also monotone-increasing
(`HaircutCannotDecrease`): a nonzero haircut is a one-way door. Slippage is
covered by the per-token caps + the instant-exit fee instead (design D3).

- The script asserts this twice (pre-flight and immediately before the
  switch) and refuses on failure — there is nothing to "fix"; a nonzero
  haircut means the kind must not be Lane-A-enabled until the two-sided-quote
  router change ships.
- Verify: `cast call <router> "haircutBps(bytes32)(uint16)" $(cast keccak "ERC20_SPOT")` → `0`
  (and the same for `MORPHO_BLUE_SUPPLY`).

### G3 — feed staleness bound `maxAge <= 24h`

The equity push feeds heartbeat at 24 h. A `maxAge` above that leaves Lane A
open on marks the market abandoned more than a full heartbeat ago; the script
refuses any registry entry beyond 86,400 s.

### G4 — divergence gate on, bound `<= 100 bps`, for every seeded token

Every `Erc20SpotAdapter` registry entry must carry a nonzero v3-style
reference pool and a divergence bound of at most 100 bps. This is the gate
that closes Lane A when the held oracle mark drifts away from the executable
pool price — the regime the fee cannot cover (analysis §4: at ≥ 200 bps basis,
no exit size is safe). The 100 bps bound is the design point the per-token
caps were derived at; the script refuses larger bounds and ungated entries.

The pool leg is a **30-minute `observe()` TWAP** (`Erc20SpotAdapter.TWAP_WINDOW`),
never the instantaneous `slot0`. A spot price is the endpoint of the last swap
in the current block, so reading it would let the party consuming the gate set
the value the gate checks — opening Lane A onto a stale mark, or shoving the
pool to force a close and revert someone's exit, both atomically for the cost
of a round-trip fee. Averaging over the window makes either direction cost
sustained inventory risk across many blocks. Registration probes `observe()`
with the window, so a pool whose observation buffer is too short is rejected
at `setFeed` time — grow `observationCardinalityNext` on the pool first.

---

## 2. Activation order

Run `script/DeployLaneA.s.sol` (simulate first, never `--broadcast` blind):

```
PRICE_ROUTER=<router> \
LANE_A_VAULTS=<vault1,vault2> \
forge script script/DeployLaneA.s.sol:DeployLaneA --rpc-url <rpc> -vvvv
```

The script executes, in order:

1. **Pre-flights** (before anything deploys): router ownership, G2 haircuts,
   no live adapter in either kind slot (a re-run must never silently swap an
   audited adapter), G3/G4 table validation, per-vault numeraire binding
   (`vault.asset() == USDG`) and G1 fee authority.
2. **Deploy adapters**: `Erc20SpotAdapter(deployer, USDG)`,
   `MorphoSupplyAdapter(MORPHO_BLUE)`.
3. **Seed the registry** from the parameter table (§3 below). `setFeed`
   live-probes each aggregator and pool, so a wrong address fails loudly here.
4. **Register kinds + caps** on the router: `registerAdapter` ×2,
   `setInstantCap(ERC20_SPOT, $100k)`, `setInstantCap(MORPHO_BLUE_SUPPLY, $250k)`.
5. **Set the fee**: `setInstantExitFeeBps(200)` on every deployer-owned target
   vault; printed calldata for foreign-owned ones (G1).
6. **`setLaneAEnabled(kind, true)` LAST** — only with `ENABLE_LANE_A=true`
   (defaults **false**), and only after re-asserting G1 + G2 against live
   chain state.

Post-run manual steps (also printed by the script):

- Hand `Erc20SpotAdapter` ownership to governance (`transferOwnership`) — the
  feed registry is a pricing-of-record control surface.
- Lane-A portfolio strategies must be initialized with `maxSlippageBps = 150`
  (analysis R2) — a strategy-init parameter, enforced at proposal review, not
  by this script. Legacy stock→native 5% two-hop routes must NOT appear in
  Lane-A `swapExtraData` (they cannot clear 150 bps).
- Per strategy at proposal review: run the script's `checkStrategyCoverage`
  helper (basket tokens all present in the adapter registry). Feed *identity*
  cannot be cross-checked on-chain (the strategy's `_feedIds` are internal);
  identity drift only degrades to Lane B, never misprices.

Verification reads after an enabling run:

```
cast call <router> "laneAEnabled(bytes32)(bool)"  $(cast keccak "ERC20_SPOT")            # true
cast call <router> "laneAEnabled(bytes32)(bool)"  $(cast keccak "MORPHO_BLUE_SUPPLY")    # true
cast call <router> "adapterOf(bytes32)(address)"  $(cast keccak "ERC20_SPOT")            # spot adapter
cast call <router> "instantCap(bytes32)(uint256)" $(cast keccak "ERC20_SPOT")            # 100000000000
cast call <vault>  "instantExitFeeBps()(uint16)"                                         # 200
cast call <spotAdapter> "feedOf(address)" <TSLA>   # aggregator, maxAge, ..., pool, cap
```

## 3. Parameter table (Robinhood mainnet 4663, analysis §8)

Caps in USDG 6-dec raw units. `maxAge = 86400` s, divergence bound 100 bps for
every entry.

| Kind | Token | Address | Feed | Reference pool | Per-token cap |
|---|---|---|---|---|---|
| ERC20_SPOT | NVDA | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` | v3 NVDA/USDG 0.05% `0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3` | `100000000000` ($100k) |
| ERC20_SPOT | AAPL | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` | **none known — see below** | `25000000000` ($25k) |
| ERC20_SPOT | TSLA | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` | `0x4A1166a659A55625345e9515b32adECea5547C38` | v3 TSLA/USDG 0.3% `0xf4ACdAEEB7022862A763C9B1B885e11191c889E3` | `7500000000` ($7.5k) |
| ERC20_SPOT | AMD | — | — | — | **excluded** (depth < $10k, never clears the fee wedge) |
| MORPHO_BLUE_SUPPLY | USDG supply | Morpho `0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010` | par (no oracle) | n/a | `250000000000` ($250k ops bound) |

Router-level: `instantCap[ERC20_SPOT] = 100000000000`,
`instantCap[MORPHO_BLUE_SUPPLY] = 250000000000`.

**Which cap actually binds — read before tuning.** All caps bound how much a
single instant exit may take out; none of them affect what a position is
*priced* at. They are asymmetric between the two kinds:

- **Stocks.** The router's per-kind cap is **inert**. It is set to the largest
  per-token cap, so a position always hits its own tighter token bound first
  (TSLA stops at $7.5k, nowhere near the $100k kind cap).
  `PortfolioStrategy.availableLiquidity` reads the adapter's per-token
  `instantCapAssets`. **To change stock exit capacity, change that token's
  `capAssets` — changing `instantCap[ERC20_SPOT]` will do nothing.**
- **Morpho.** The per-kind cap is **load-bearing**. There is no per-token
  registry on the Morpho side, so it is the only depth bound on a Morpho
  unwind (`MorphoSupplyStrategy.availableLiquidity` reads it). Setting it to 0
  removes that bound entirely.

**AAPL is excluded by default.** The analysis found only a Uniswap **v4**
AAPL/USDG pool, and the adapter's divergence gate reads a v3-style `observe()` TWAP —
v4 pools live inside the PoolManager and expose no per-pool contract, so G4
cannot be satisfied for AAPL today. To include AAPL, either source/verify a
v3-style AAPL/USDG pool of adequate depth and pass it as
`AAPL_REFERENCE_POOL`, or extend the adapter to read v4 sqrtPrice (a code
change + review). Do not seed AAPL gate-off.

## 4. Market-hours behavior — expected, not an outage

The equity feeds are 24/5: they hold their last price overnight and across
weekends (heartbeat 24 h, deviation 0.5%) while DEX pools keep trading. Two
gates therefore close Lane A automatically off-hours:

- the **divergence gate** trips as soon as the held mark drifts > 100 bps from
  the reference pool (typically first), and
- the **staleness gate** trips by Saturday evening at the latest (feed ages
  measured 19–22 h on a Saturday afternoon).

When either trips, the router fails closed: `totalAssets()` degrades to
float-only NAV, instant entry/exit close, and the vault runs Lane B (queued)
only. **No operator action is needed** — Lane A reopens by itself on the next
fresh, convergent mark (first market open). Expect this every Friday evening →
Monday open; alert fatigue here is misconfiguration, not incident volume. LPs
should be told: nights/weekends are Lane B by design.

## 5. Rollback

```
setLaneAEnabled(<kind>, false)   # onlyOwner on the router — one call per kind
```

- **Instant**: the very next `valueStrategy` read returns `(0, false)` and
  every consuming vault degrades to Lane B (float-only NAV, queued exits).
- **No stranded state**: positions, adapters, registry entries, caps and the
  fee all stay in place; nothing needs unwinding. Strategies keep operating —
  only instant pricing is withdrawn.
- **Reversible**: re-enabling is the same call with `true` — but re-walk the
  G1–G4 checklist first; the switch is cheap, the preconditions are the point.
- Softer levers, narrowest first: `Erc20SpotAdapter.removeFeed(token)` delists
  one token (its strategies degrade to Lane B); `setFeed` with a smaller cap
  shrinks exposure; `setInstantCap` bounds the whole kind.

## 6. Pre-mainnet TODO

- [ ] **Re-measure DEX depth during market hours** before sending the mainnet
  parameter transaction. The analysis snapshot (block 25,280,017) was a
  **Saturday**; market-hours depth is typically equal or better, so the §3
  caps are conservative — but confirm, and re-derive if pools moved
  (analysis "Known gaps" (2)). Re-verify the recommended unwind routes at the
  same time (the July native-paired route assumption is already dead).
- [ ] Source or build a G4-compliant AAPL reference pool (or ship v4 gate
  support) if AAPL is wanted in the launch basket.
- [ ] Confirm `AAPL/NVDA/TSLA` feed addresses against Chainlink's RDD at
  send time (they are baked into `DeployLaneA` as of the analysis fetch).
- [ ] Governance ownership handoff of the spot adapter after seeding.
