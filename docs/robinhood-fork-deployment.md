# Robinhood-mainnet fork deployment (Tenderly vnet, chain 9994663)

A **mainnet-faithful** Sherwood deployment on a Tenderly Virtual TestNet that forks
Robinhood Chain **mainnet** — USDG stablecoin, official Uniswap v3+v4, Chainlink
push feeds, real tokenized-stock liquidity. Purpose: end-to-end validation and
**guardian-network simulations** as close to a real mainnet environment as
possible (real WOOD, mainnet timing floors, real DEX), with the admin cheats a
fork gives us for setup.

> **Ephemeral.** Tenderly vnets expire. When the RPC 404s, mint a new vnet and
> re-run §4 + §5 against it. The chain id (9994663) and all externals stay the
> same; only the RPC URL and the Sherwood core addresses change.

---

## 1. Fork facts

| | |
|---|---|
| Chain id | **9994663** |
| Admin RPC (cheats) | the Tenderly **admin** RPC for the vnet — set as `TENDERLY_ROBINHOOD_RPC_URL` in `contracts/.env` (foundry `robinhood_fork` alias). **Secret — never commit it.** |
| Public RPC (reads/writes) | the vnet's public RPC (no cheats) — baked into the CLI/app as the `robinhood-fork` default; override via `ROBINHOOD_FORK_RPC_URL` / `NEXT_PUBLIC_RPC_URL_ROBINHOOD_FORK` |
| WOOD (live) | `0xf8bc08092c06db6148114dcf82af881f1085f92b` (18-dec, 1B supply, ownership renounced) |
| USDG (asset) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` — **6 decimals** |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| Uniswap SwapRouter02 / QuoterV2 | `0xcaf681…5cb2` / `0x33e885…a9e7` |
| Uniswap v4 PoolManager / V4Quoter | `0x8366a3…0951` / `0x8dc178…98f94` |
| Stock tokens + Chainlink push feeds | see `chains/9994663.json` (AAPL/TSLA/NVDA/AMZN/AMD/… + `CHAINLINK_*_USD_FEED`) |

All externals are pre-committed in `chains/9994663.json` and survive re-deploys
(`ScriptBase._writeAddresses` patches only the core keys in place).

---

## 2. Deployed core (regenerated each vnet)

Source of truth: **`chains/9994663.json`** (deploy-written). Last fresh deploy:

| Contract | Address |
|---|---|
| SyndicateFactory | `0xD9E2F732cc30bC87303E2b9E9fD2f19966D9eDc2` |
| GovernorBeacon | `0xfb5d298e13D79aa5960F4c6233348b86b3B23e99` |
| ProtocolConfig | `0xC6744E4941f4810fDadB72c795aD3EE7cb55D925` |
| GuardianRegistry | `0x8Cc7E69708B551221B831e1C2BAc473860DffA1A` |
| StakedWood (sWOOD) | `0xfaEde5DE0572f0Bc84eD0AD11fC79de40c3730eF` |
| PriceRouter (zero adapters → Lane B) | `0x4F7d9cD3f9f96fF4EBE991A628344c05041dd65b` |
| UniswapSwapAdapter (v3+v4) | `0x9176C63C8269add92690aE02A45f75B72863cE2B` |
| PortfolioStrategy template | `0xe1e6D7DE0BED412664eEf07074898Cfa19829f40` |
| StrategyFactory | `0x8599ECDdEC4C969ec9E1f3AEE894afd70365AaC2` |

`SYNDICATE_GOVERNOR` is intentionally `0x0` — governors are per-vault
`BeaconProxy`es, resolved via `factory.governorOf(vault)`.

---

## 3. Deployer & auth

- Deployer: `0x5A00afAecE9CF61A768E2AE2713084C8d354DF94` (the `DEPLOYER` key in the
  chains JSON). On a fork we **impersonate** it — no private key needed — because
  the Tenderly admin RPC accepts `eth_sendTransaction` from any sender.
- Forge broadcast flag: **`--unlocked --sender 0x5A00…`** (matches
  `script/deploy-vnet.sh`'s vnet-funded pattern).
- Fund the deployer with gas first (see §5).

---

## 4. Deploy ceremony

WOOD is **already live** on the fork, so `DeployWood` is **skipped** — set
`WOOD_TOKEN` in the chains JSON and pass it to the core deploy. Broadcast each
against `--rpc-url robinhood_fork --unlocked --sender <deployer> --broadcast
--slow --gas-estimate-multiplier 200`:

```bash
# 0. one-time: chains/9994663.json has WOOD_TOKEN + externals; deployer funded (§5)

# 1. core + zero-adapter PriceRouter (no ENS/ERC-8004, no multisig handoff)
WOOD_TOKEN=0xf8bc08092c06db6148114dcf82af881f1085f92b \
SKIP_MULTISIG_HANDOFF=true ROBINHOOD_FORK_CHAIN_ID=9994663 \
forge script script/robinhood-mainnet/Deploy.s.sol:DeployRobinhoodMainnet \
  --rpc-url robinhood_fork --unlocked --sender 0x5A00afAecE9CF61A768E2AE2713084C8d354DF94 \
  --broadcast --slow --gas-estimate-multiplier 200

# 2. UniswapSwapAdapter (v3+v4) + PortfolioStrategy template
ROBINHOOD_FORK_CHAIN_ID=9994663 \
forge script script/robinhood-mainnet/DeployPortfolioStrategy.s.sol:DeployPortfolioStrategy \
  --rpc-url robinhood_fork --unlocked --sender 0x5A00afAecE9CF61A768E2AE2713084C8d354DF94 \
  --broadcast --slow --gas-estimate-multiplier 200

# 3. keyless-clone StrategyFactory + template approvals
SKIP_MULTISIG_HANDOFF=true \
forge script script/DeployStrategyFactory.s.sol:DeployStrategyFactory \
  --rpc-url robinhood_fork --unlocked --sender 0x5A00afAecE9CF61A768E2AE2713084C8d354DF94 \
  --broadcast --slow --gas-estimate-multiplier 200
```

CREATE3 makes the core addresses order-independent. The deploy uses
`SKIP_MULTISIG_HANDOFF=true`, so the deployer retains ownership of the beacon /
factory / registry / sWOOD / ProtocolConfig / PriceRouter (needed for fork admin).

**Validate:** `factory.beacon/priceRouter/protocolConfig`, `swood.wood==WOOD`,
`swood.registry==registry`, `registry.reviewPeriod==86400`,
`registry.blockQuorumBps==3000`, `strategyFactory.approvedTemplate(PORTFOLIO)==true`,
`governorImpl.MIN_VOTING_PERIOD()==86400`.

---

## 5. Funding wallets via Tenderly cheats

Only two RPC cheats are exposed on this vnet: `tenderly_setBalance` (native ETH)
and `tenderly_setStorageAt` (any storage slot). **The ERC-20 cheat
`tenderly_setErc20Balance` is NOT available** — fund tokens by writing the
`_balances` mapping slot directly.

> **`cast rpc` gotcha:** pass each JSON-RPC param as a **separate positional arg**,
> not one JSON array. `cast rpc tenderly_setStorageAt <tok> <slot> <val>` ✓ ;
> `cast rpc tenderly_setStorageAt '["<tok>","<slot>","<val>"]'` → `-32602`.

```bash
ADMIN="$TENDERLY_ROBINHOOD_RPC_URL"   # admin RPC (cheats) — from contracts/.env, never committed
# native ETH (array of wallets, single amount)
cast rpc tenderly_setBalance '["0xWallet"]' 0x56BC75E2D63100000 --rpc-url $ADMIN   # 100 ETH

# ERC-20 balance = write keccak256(abi.encode(holder, balancesSlot))
#   WOOD balances slot = 0   (plain OZ ERC20)
#   USDG balances slot = 1   (slot 0 is other proxy state)
KEY=$(cast index address 0xWallet 0)                        # WOOD; use 1 for USDG
cast rpc tenderly_setStorageAt 0xToken $KEY $(cast to-uint256 <amount_wei>) --rpc-url $ADMIN
```

**Discovering a token's balances slot** (for a token not listed above): brute-force
`for S in 0..40`, write `keccak(holder,S)` to a sentinel and read `balanceOf(holder)`;
the slot where the read changes is the mapping base. If nothing in 0..40, try the
OZ v5 namespaced ERC-7201 location.

**Time travel** for governance/strategy windows: `cast rpc evm_increaseTime <secs>`
then `cast rpc evm_mine`.

---

## 6. Mainnet-faithful parameters (do NOT accelerate for guardian sims)

Baked in by the deploy (constructor immutables + init args) — matching mainnet:

| Param | Value | Where |
|---|---|---|
| `MIN_VOTING_PERIOD` | **24h** | governor impl constructor |
| `MIN_COOLDOWN_PERIOD` | 1h | governor impl constructor |
| `reviewPeriod` | **24h** | registry init |
| `blockQuorumBps` | **30%** | registry init |
| `MIN_COHORT_STAKE_AT_OPEN` | **50,000 WOOD** | registry constant (cold-start floor) |
| `minGuardianStake` / `minOwnerStake` | 10,000 WOOD each | sWOOD init |
| `coolDownPeriod` | 7 days | sWOOD init |
| `minSlashBps` / `maxSlashBps` | 10% / 100% | sWOOD init |
| protocol fee / mgmt fee | 1% / 0.5% | ProtocolConfig / factory |

Unlike the 46630 testnet (which upgrades the governor to 600s floors), the fork
keeps the **real 24h floors** — advance time with `evm_increaseTime` instead of
waiting. This is deliberate: guardian sims should exercise the true mainnet
windows.

---

## 7. One-fund lifecycle (validated)

Driven by the published-shape CLI via the first-class `--chain robinhood-fork`
network (§8). Operator wallet is **separate from the deployer**. Env per command:
`HOME=<isolated>` `PRIVATE_KEY=<operator>` (no `SIM_*` — the static registry
carries the fork addresses).

```bash
sw() { node <repo>/cli/dist/index.js --chain robinhood-fork "$@"; }

sw guardian prepare-owner-stake 10000                    # 10k WOOD owner bond
sw fund create --asset USDG --amount ... --name "…" --subdomain … --open-deposits -y
sw vault deposit --amount 50000                          # USDG (6-dec handled)
sw strategy propose portfolio --vault <vault> --asset USDG --amount 40000 \
   --tokens <NVDA_addr>,<TSLA_addr> --weights 5000,5000 \
   --swap-adapter 0x9176C6…cE2B --swap-routes v4:3000:60,v4:3000:60 \
   --feed-ids <NVDA_feed>,<TSLA_feed> --price-decimals 8,8 \
   --max-price-ages 2592000,2592000 --max-slippage 500 --duration 7d --name "…"
sw proposal vote --id 1 --vault <vault> --support for
#   evm_increaseTime 172800 + evm_mine   (past 24h vote + 24h review)
sw proposal execute --id 1 --vault <vault>               # buys NVDA/TSLA on Uniswap v4
#   evm_increaseTime 7200 + evm_mine     (past 1h self-settle floor)
sw proposal settle --id 1 --vault <vault>                # sells back → realized PnL
```

**Route discipline (critical):** quote candidate pools on the fork with the
V4Quoter before proposing — do not guess. NVDA/TSLA have **direct USDG v4 pools at
fee 3000 / tickSpacing 60 (0.3%)**; the 5%-fee direct pools quote garbage and would
breach the 5% slippage floor. Pass verified routes as explicit `--swap-routes`.

**Warp/staleness caveat:** advancing 48h for governance ages the Chainlink push
feeds past the 26h default → pass a large `--max-price-ages` (e.g. `2592000` = 30d,
the bound) so `execute`/`settle` don't trip `StalePrice`. For higher fidelity,
refresh the feed's `updatedAt` via `setStorageAt` after each warp instead.

Validated result: 50,000 USDG deposited → 40k deployed into 93.08 NVDA + 54.69
TSLA → settled at **49,760.78 USDG (−0.48% = round-trip fee, no market move)**.

---

## 8. CLI / app wiring (in the `sherwood` repo)

- **CLI** (`cli/src/lib/network.ts` + `addresses.ts`): first-class
  `robinhood-fork` network (chain 9994663, public RPC, `ROBINHOOD_FORK_RPC_URL`
  override). `CHAINLINK().VERIFIER_PROXY = 0` → PortfolioStrategy **push-feed
  mode**. `USDG` token key added so `--asset USDG` resolves at 6 decimals.
- **App** (`app/src/lib/contracts.ts`): the fork chain + address block, gated by
  **`NEXT_PUBLIC_CHAIN_ID=9994663`** (+ `NEXT_PUBLIC_RPC_URL_ROBINHOOD_FORK`). The
  `robinhoodfork.sherwood.sh` deployment sets those env vars; the default 46630
  build is unchanged.

---

## 9. Guardian-network simulation

The point of the mainnet-faithful posture. To make guardian **blocking** actually
possible (not the cold-start bypass), total staked guardian weight at review-open
must exceed **`MIN_COHORT_STAKE_AT_OPEN` = 50,000 WOOD**.

1. **Stand up a guardian cohort** — ≥6 wallets, each funded with ETH + ≥10,000
   WOOD via §5 cheats, then:
   ```bash
   PRIVATE_KEY=<guardian_i> sw guardian stake 10000   # swood.stakeAsGuardian(amount, agentId=0)
   ```
   6 × 10k = 60k > 50k clears the cold-start floor. `agentId` = 0 is fine
   (agentRegistry is `address(0)` on the fork). Guardians become active at
   `block.timestamp` — `evm_increaseTime 1` before opening a review (checkpoints
   read at `t-1`).
2. **Open a review** — propose a strategy (§7). When it enters `GuardianReview`,
   the registry snapshots the cohort stake + `blockQuorumBps`.
3. **Vote to block** — during the 24h review window, guardians call
   `registry.voteOnProposal(governor, proposalId, Block)` (CLI review-vote). Reach
   **30% of cohort stake** voting Block → proposal `Rejected`, approvers slashed
   (WOOD **burned**), blockers attributed for off-chain Merkl rewards.
   - Vote-change is allowed until the final 10% of the window (late-vote lockout).
   - Approvers capped at 100/proposal; blockers uncapped.
4. **Slash severity** = stake-weighted median of blockers' proposed `slashBps`,
   clamped to sWOOD's `[minSlashBps, maxSlashBps]` (10–100% own stake; DPoS
   delegation removed/postponed 2026-07-26 — the own bond is the only leg).
5. **Owner bond** — `emergencySettleWithCalls` re-checks
   `requiredOwnerBond = max(minOwnerStake, TVL·ownerStakeTvlBps/1e4)` at call time
   (`ownerStakeTvlBps = 0` in V1 → flat 10k floor).
6. **Appeals** — slashed parties petition the multisig; `refundSlash` draws from
   the Slash Appeal Reserve (seed it post-deploy: deployer holds WOOD, `approve` +
   `registry.fundSlashAppealReserve(amount)`; the mainnet `Deploy` override does
   **not** auto-seed it).

Emergency-settle lane (`unstick` / `emergencySettleWithCalls` /
`finalizeEmergencySettle` / `cancelEmergencySettle`) exercises the same review
machinery and is worth including in a full sim.

---

## 10. Accepted v1 oracle risks (read before wiring feeds)

Two oracle exposures are **accepted for v1**: known, deliberate, and not open
defects. The oracle hardening in `ExposureLedger` (stale or reverting feeds fall
back instead of bricking approvals, `woodHaircutBps` applied on the feed path
*and* every degraded path, `woodPriceDetail()` for observability) makes the
remaining exposure easy to mistake for zero. It is not zero, and neither of the
two is detectable on-chain — both are the operator's problem.

### 10.1 Chainlink aggregators clamp at `minAnswer` / `maxAnswer`

Every Chainlink aggregator answers inside a fixed band. If the market leaves the
band, `latestRoundData()` keeps returning the bound, with a fresh `updatedAt` and
a positive answer. Nothing in `ExposureLedger` can see that: its checks are
`answer <= 0` and `age > maxDelay`, and a clamped price passes both.

The dangerous direction is **downward, and it is anti-conservative**:

- **`coverageUsd(asset, amount)`** returns *less* than the position is worth when
  the asset feed is pinned at `minAnswer`. `requireApproveQuorum` then demands
  **less** guardian collateral than the risk warrants — during exactly the
  collapse that pinned the feed, i.e. when the valuation matters most.
  Downstream, `proposerBondWood` (sized off `coverageUsd`) is under-sized the
  same way.
- **`woodPriceX8()`** carries the same exposure on the WOOD feed, and it prices
  the *other* side of the check (`slashableBondUsd` = guardian stake × this
  price). A WOOD feed clamped at `maxAnswer` over-values every guardian bond, so
  quorums clear on collateral that is not there. `woodHaircutBps` helps but does
  **not bound a clamp**: it is a fixed discount (floor `MIN_WOOD_HAIRCUT_BPS` =
  5000 bps, so at most a 50% shave), not an error bound.

Affected read paths: `coverageUsd` (asset side) and `woodPriceX8` →
`slashableBondUsd` / `proposerBondWood` (WOOD side).

Operator handling, since the contract cannot detect it:

1. **Before wiring**, read each aggregator's `minAnswer` / `maxAnswer` (on the
   underlying aggregator, not the proxy) and confirm the band leaves real
   headroom around plausible crash and spike prices for that asset.
2. **Monitor off-chain**: alert when an on-chain feed answer sits at either
   bound, or diverges from an independent reference beyond a threshold. That
   alert is the only signal you get.
3. **Response is manual and owner-only.** WOOD side: `setWoodFeed(address(0), 0)`
   clears the feed and returns pricing to the governance fallback, then walk
   `setWoodUsdPrice` to a conservative number (downward moves are deliberately
   unbounded; upward is capped at 2x per `MIN_PRICE_UPDATE_INTERVAL` = 1 day, as
   is `setWoodHaircutBps`). Asset side: `setAssetFeed` **rejects the zero
   address**, so there is no unwire — recovery means pointing the asset at a
   replacement aggregator, or accepting that the asset stays mispriced.

### 10.2 No sequencer-uptime feed on Robinhood 4663

The standard L2 pattern is to gate every price read on a sequencer-uptime feed
plus a grace period, so reads are rejected while the sequencer is down and for a
window after it restarts. **Robinhood Chain 4663 publishes no sequencer-uptime
feed**, so that gate cannot be built here: there is no address to pass. The repo
does carry the fail-closed reader (`src/libraries/ChainlinkReader.sol`, with
`SequencerDown` / `GracePeriodNotOver`), but it requires a `sequencerUptimeFeed`
argument and is therefore unused on this chain; `ExposureLedger` reads the
aggregator directly.

Consequence: a read that looks fresh may predate an outage. `updatedAt` bounds
how old the *answer* is, not whether the chain was accepting transactions in
between — so a proposal can be coverage-checked, approved and executed on prices
from before a downtime window, at a valuation the staleness check accepted.

Operator handling: size `ASSET_FEED_MAX_DELAY` (and the WOOD feed's `maxDelay`)
tightly enough that a plausible outage pushes reads past staleness rather than
through it — while staying long enough to cover the full vote + review + execute
lifecycle, since a `maxDelay` shorter than that lifecycle kills fully covered
proposals at execution with `StalePrice`. Treat post-outage restarts as a manual
hold: do not execute or settle across a known downtime window until feeds have
visibly re-published.

Revisit both of the above when 4663 gets a sequencer-uptime feed.

### 10.3 `woodUsdPriceX8` stays load-bearing after a WOOD feed is wired

Wiring a Chainlink WOOD feed with `setWoodFeed(feed, maxDelay)` does **not**
retire the governance price. `_woodPrice()` falls back to
`_haircut(woodUsdPriceX8)` on all four degraded shapes — feed unset, non-positive
answer, `age > maxDelay`, and a reverting aggregator — because failing closed
here would value every bond at $0 and halt approvals protocol-wide on a Chainlink
hiccup.

So an abandoned manual number does not fail loudly; it silently values every
bond. `woodUsdPriceX8` carries no `updatedAt` of its own, which means "feed
healthy" and "feed dead for three months, running on a manual number nobody has
touched" are indistinguishable from the outside unless you look.

Operator duties after wiring a feed:

- **Keep maintaining `woodUsdPriceX8`** on the same cadence as before, as a
  conservative floor. It is a live fallback, not a deploy-time leftover.
- **Poll `woodPriceDetail()`** — it returns `(price, usingFallback)`. Alert on
  `usingFallback == true` persisting beyond a short blip, and on a fallback price
  that has not been refreshed recently. This is the only observable for the
  degraded path: there is no event.

---

## 11. Regenerating after a vnet expires

1. Mint a new Tenderly vnet (same fork target). Update `TENDERLY_ROBINHOOD_RPC_URL`
   (admin) in `contracts/.env` and the public-RPC constants in the CLI/app if the
   base URL changed.
2. Re-run §4 (deploy) → fresh `chains/9994663.json`.
3. Sync the new core addresses into `cli/src/lib/addresses.ts`
   (`ROBINHOOD_FORK_*`) + `app/src/lib/contracts.ts` (`ROBINHOOD_FORK_ADDRESSES`)
   + the `STRATEGY_TEMPLATE_LABELS` portfolio entry.
4. Re-fund wallets (§5) and re-run the lifecycle (§7) / guardian sim (§9).
