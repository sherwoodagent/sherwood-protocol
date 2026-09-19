# Deployment runbook — Robinhood mainnet (4663) and its fork

The operator's spine for a full deployment: what runs, in what order, and what
has to happen *after* the last broadcast before the protocol is safe to use.

This is the index, not the detail. The normative source is
`openspec/specs/deployment-docs/spec.md` — every phase below has a requirement
there with its pre-flights and scenarios. Parameter values live in
`docs/pre-deployment-parameter-review.md`. Where the two disagree, the spec wins
and this file is stale.

Chain constraints: 4663 is an Arbitrum Orbit L2 with `MaxCodeSize` 98,304 bytes,
no ENS/Durin registrar, and no sequencer-uptime feed. The canonical ERC-8004
IdentityRegistry (`0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`, same address as
Base) and EAS v1.4.0 (`chains/4663.json` → `EAS`, `EAS_SCHEMA_REGISTRY`, deployed
by `DeployEAS` + `SeedAttestations` in #278) are both live. The v1 factory still
takes `address(0)` for `ensRegistrar` and `agentRegistry` — a deploy decision
(identity gating off), not a chain limit. EAS is not part of this ceremony.

---

## 1. Ceremony order

One script, one broadcast: `script/robinhood-mainnet/DeployAll.s.sol:DeployAll`.
Its phases run in a fixed order inside that broadcast — Create3Factory bootstrap,
core (executor lib, vault impl, ProtocolConfig, governor beacon, sWOOD,
GuardianRegistry, factory, TierRegistry + the launch set), UniswapSwapAdapter and
the three strategy templates, StrategyFactory, the WOOD price source
(`WoodPoolFeed`, reading the WOOD/WETH V2 pair and the V3 pool booked beside it),
Plan B, Plan D, TokenCourt, handoff. Every address is `f(DEPLOYER, salt)` under CREATE3,
so a re-run adopts what is already there instead of minting a second copy.

Nothing is read from the environment. Every number comes from
`script/robinhood-mainnet/RobinhoodParams.sol`; every address comes from
`chains/{chainId}.json`.

**Mainnet (4663) — two runs.**

1. **Check the inputs.** Every econ constant in `RobinhoodParams.sol` is confirmed and
   no `PLACEHOLDER` remains: the WOOD price cap is derived from live spot at run time,
   so there is nothing to re-measure on the day. `chains/4663.json` carries every key
   the run requires, the launch set included — `USDC`, `BTC` and `LINK` are feed-only
   by decision (`_hasNoTokenOnRobinhood`), not gaps. `CREATE3_FACTORY` and
   `WOOD_USD_FEED` are written BY the run, not read.
2. **Grow the V3 observation ring — before anything is deployed.** The feed's second
   leg is a Uniswap V3 pool (SHE-291), and `DeployWoodPoolFeed` refuses a pool whose
   ring cannot span `TWAP_WINDOW`. The call is permissionless, monotonic and safe to
   repeat, so it can run well ahead of the ceremony:
   ```bash
   V3_CARDINALITY=<N> forge script script/GrowV3Cardinality.s.sol:GrowV3Cardinality \
     --rpc-url robinhood --account <key> --broadcast --slow
   ```
   Size `N` from the `required for a <window> s window` line the feed phase prints;
   above 1,400 the ring is grown in repeated steps, because every new slot is
   initialised inside the call at ~22.4k gas paid by the CALLER. **The growth is not
   instant.** The call raises a TARGET (`observationCardinalityNext`); the ring
   reaches it one observation at a time, as the pool is traded. Wait for
   `observationCardinality` itself — the `next` value is not what `observe` serves.
3. **First run.**
   ```bash
   forge script script/robinhood-mainnet/DeployAll.s.sol:DeployAll \
     --rpc-url robinhood --account <key> --broadcast --slow \
     --gas-estimate-multiplier 200
   ```
   It stops at `Checkpoint.AwaitingWoodFeed`: `WoodPoolFeed` is minted, nothing
   of Plan B is, and **no ownership has moved**.
4. **Prime the feed.** Call `WoodPoolFeed.update()` on a keeper until
   `latestRoundData()` answers — at least one `window`, 24h minimum. The deployer
   key owns every contract for this whole interval; that is the cost of the
   warm-up, and it is why step 3 hands nothing off.
5. **Second run.** The same command. The stage gate passes, Plan B / Plan D /
   TokenCourt deploy, the handoff runs, and `deployAll` returns
   `Checkpoint.Complete`. Addresses are written to `chains/4663.json` last.
6. **The Safe's turn.** `acceptOwnership()` on `ProtocolConfig`, `TierRegistry`,
   `ExposureLedger`, `ChallengeGame` and `TokenCourt` (the one-step contracts —
   beacon, factory, GuardianRegistry, sWOOD, StrategyFactory — are already
   transferred). Then re-point `setProtocolFeeRecipient` and
   `setGuardiansFeeRecipient` off the deployer placeholder, seed the slash-appeal
   reserve (`approve` + `registry.fundSlashAppealReserve`), and configure the
   Zodiac Delay module with the asymmetry the spec requires: raises delayed,
   drops immediate.
7. **Verify.** `RPC=<url> ./script/verify-robinhood.sh 4663` — it re-derives every
   address from the book's `CREATE3_FACTORY` and fails on any disagreement.

**Fork — one run.** Chain 9994663, `chains/9994663.json` committed. Same command
with `--unlocked --sender 0x5A00afAecE9CF61A768E2AE2713084C8d354DF94` instead of
`--account`. Posture is derived from the chain id, so there is no flag: the fork
mints `ForkWoodFeedFixture` (priced off the fork's own pair reserves x the live
ETH/USD answer) instead of `WoodPoolFeed`, and completes in one run. A fork owns
itself: the handoff still runs, with the deployer as its own target, so it changes
nothing. A fork book may name `OWNER_MULTISIG` only when it equals `DEPLOYER`,
which keeps a mainnet Safe from being handed a fork by a copied book.
Verify with `./script/verify-robinhood.sh 9994663`.

`DeployWood` is skipped on both: WOOD is already live at
`0xf8bc08092c06db6148114dcf82af881f1085f92b`, and `DeployWood` now refuses chain
4663 outright.

**TokenCourt is branch-specific.** The `_deployCourt` / `_wireCourt` phases exist
on the branch that ships `src/TokenCourt.sol`. `post-audit-v2` resolves disputed
challenges by guardian vote (SHE-269) and drops both together — but as of
2026-09-16 `origin/post-audit-v2` (188941b6) has `TokenCourt` RESTORED by
721d8775, so re-fetch and read the branch before assuming either shape.

**A comment moves every address.** The Create3Factory initcode hash is pinned in
`script/DeploySalts.sol`. solc's CBOR metadata hashes the source and
`foundry.toml` pins no `bytecode_hash`, so editing `script/utils/Create3.sol` or
`Create3Factory.sol` — comments included — changes the hash, moves the whole
address table, and trips the `Create3Factory initcode hash drift` pre-flight.
Re-record the constant deliberately; never to get a build green.

---

## 2. Per-syndicate seeding — required, and not part of any script

Three risk parameters ship inert, and no deploy script can seed them: they live
on the governor and vault that `SyndicateFactory.createSyndicate` mints, after
every script has finished, and their setters are vault-owner-gated.

For each syndicate, in the same session as `createSyndicate` and before the first
`propose` (both governor setters are `whenNoActiveProposal`):

1. `governor.setTier2CallCapBps(200)` — **P0.** Its inert default is `10_000`
   (100% of TVL), which is the one configuration in which permissionless tier-2
   is strictly worse than the status quo.
2. `governor.setMaxCapitalBps(8000)`
3. `vault.setMinBufferBps(500)`
4. `GOVERNOR=… VAULT=… forge script script/CheckSyndicateParams.s.sol:CheckSyndicateParams --rpc-url robinhood`
   — must exit 0. It reverts on any parameter still at its inert default
   (`ALLOW_INERT_TIER2_CALL_CAP=true` is the deliberate escape hatch, and using
   it is a decision to record in the ceremony, not a way past the gate).

The recommended values above are argued in `docs/pre-deployment-parameter-review.md`
— read it before seeding, because two of the three are judgement calls with no
code-derived number behind them.

---

## 3. Publication — the step that happens after the tx confirms

The `skill` and `mintlify-docs` repos publish from their own `main`, not from
the `sherwood` superproject's submodule pointer: `sherwood.sh/skill.md` and
`/skill-guardian.md` proxy `skill@main` (5 min / 1 h cache) and
`docs.sherwood.sh` builds from `mintlify-docs@main`. So merging a skill or docs
PR *is* the publish, and it reaches agents within the hour regardless of any
pointer bump.

Order, per `sherwood/CLAUDE.md` → "Release sequencing (contracts ↔ skill/docs)":

1. Land the contract change on chain and confirm the tx.
2. Merge the `skill` / `mintlify-docs` PRs that describe it.
3. Bump the submodule pointers in `sherwood`, in the same release.

Merging step 2 first tells agents to call an address or ABI that is not live, and
the failure is silent: `skill` #56 pointed the guardian address table at a
parallel 46630 stack, so an agent staking by the book became an active guardian
on a network nobody proposes to.

Also publish the new addresses (handbook item 94): `sherwood/cli/src/lib/addresses.ts`,
`sherwood/sdk/src/addresses.ts`, `sherwood-guardian/chains/*.json`, `skill/ADDRESSES.md`.

---

## 4. Standing operations

Not one-time steps. Nothing below is enforced on-chain.

- **Keep `woodUsdPriceX8` above market.** It is a manipulation cap, never a
  price — seeded at or below market it binds permanently and pins every bond.
  Review monthly; lowering it is the emergency brake and is not rate-limited
  on-chain (rate limiting lives in a Zodiac module on the owner Safe).
- **Call `WoodPoolFeed.update()` on a schedule** shorter than the `maxDelay`
  passed to `setWoodFeed`. It is permissionless and a no-op when a pool is early
  or below its depth floor, so a failing keeper looks like nothing at all — and a
  stale feed is `NoWoodPrice`, which by design lets approve votes land while
  nothing new can be proposed or executed.
- **Alert on `woodPriceX8()` reverting**, and on the cap binding (the served
  price sitting at `haircut(woodUsdPriceX8)` rather than tracking market).
  Neither emits an event; both have to be polled.
- **A keeper must open guardian reviews.** An unopened review is not a skipped
  review — the governor settles it inline as not-blocked and the proposal
  executes unreviewed.

## 5. Accepted oracle risks (v1)

Stated here because an operator has to see them, not only the source natspec.

- **Chainlink aggregators clamp at `minAnswer`/`maxAnswer`.** A clamped price is
  anti-conservative: it understates `coverageUsd` and over-values guardian bonds.
  The WOOD side is bounded by `min(market, woodUsdPriceX8)`; the asset side has
  no such ceiling.
- **Chain 4663 publishes no sequencer-uptime feed**, so the usual
  staleness-plus-grace-period gate cannot be built. `ASSET_FEED_MAX_DELAY` is the
  only control, and it bounds the AGGREGATOR's own `updatedAt` age on every
  `ExposureLedger.coverageUsd` read — not the proposal lifecycle. Size it above the
  feed's 24h heartbeat (else every covered read reverts `StalePrice`) and tightly
  enough that a plausible outage still pushes reads past staleness.
