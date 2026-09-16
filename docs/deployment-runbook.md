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

Each step is a separate broadcast. CREATE3 makes the core addresses
order-independent, but the phases below hand each other addresses through
`chains/{chainId}.json`, so the order is real.

| # | Script | Produces |
|---|--------|----------|
| 1 | `script/robinhood-mainnet/Deploy.s.sol:DeployRobinhoodMainnet` | core: executor lib, vault impl, ProtocolConfig, governor beacon, sWOOD, GuardianRegistry, factory, TierRegistry |
| 2 | `script/robinhood-mainnet/DeployPortfolioStrategy.s.sol` | UniswapSwapAdapter (v3+v4) + Portfolio template |
| 3 | `script/robinhood-mainnet/DeployMorphoStrategy.s.sol` | MorphoSupplyStrategy template |
| 4 | `script/robinhood-mainnet/DeployConcentratedLiquidityStrategy.s.sol` | ConcentratedLiquidity template |
| 5 | `script/DeployStrategyFactory.s.sol` | keyless-clone StrategyFactory + template approvals |
| 6 | `script/DeployWoodPoolFeed.s.sol` | `WOOD_USD_FEED` — Plan B pre-flight 8 refuses a ledger with no live WOOD price source |
| 7 | `script/DeployPlanB.s.sol` | ExposureLedger + ProposerBondEscrow, seeded and wired |
| 8 | `script/DeployPlanD.s.sol` | ChallengeGame + its four role wirings |
| 9 | `script/DeployTokenCourt.s.sol`, then `WireTokenCourt` | TokenCourt, then its authority over the game |

Step 9 is specific to this branch. `post-audit-v2` deletes `TokenCourt` in
favour of resolving challenges by guardian vote (SHE-269), and the phase goes
with it — drop the row when that line becomes the deploy base.

Between 6 and 7, run `WoodPoolFeed.update()` until `latestRoundData()` answers:
each pool only snapshots once `window` (24h minimum) has elapsed, and Plan B's
pre-flight reads a price, not a deployment.

`DeployWood` is skipped on 4663 and on the fork: WOOD is already live at
`0xf8bc08092c06db6148114dcf82af881f1085f92b`.

**Fork differences.** `ROBINHOOD_FORK_CHAIN_ID=9994663` and
`SKIP_MULTISIG_HANDOFF=true`; the deployer is impersonated (`--unlocked
--sender`), and step 6 needs a fixture feed instead, because a vnet cannot
accumulate a 24h TWAP. `SKIP_MULTISIG_HANDOFF` is never used on 4663, and
`OWNER_MULTISIG` must be a Safe, not an EOA.

The spec's fork section still names `script/fork/DeployForkWoodUsdFeed.s.sol` and
a `DeployWoodTwapOracle` phase; neither is in tree on `v1-deploy` — the WOOD
price source is `src/pricing/WoodPoolFeed.sol`, wired with `setWoodFeed`. Re-read
the spec against the scripts before a fork run.

**Ownership.** ProtocolConfig and TierRegistry are `Ownable2Step`: the ceremony
asserts `pendingOwner == multisig`, and the multisig still has to call
`acceptOwnership()`. Until it does, those two contracts have no live owner.

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
  only control: size it tightly enough that a plausible outage pushes reads past
  staleness, while still covering a full vote + review + execute lifecycle.
