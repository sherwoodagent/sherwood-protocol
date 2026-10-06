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
by `DeployEAS` + `SeedAttestations` in #278) are both live. The v1 factory has no ENS
registrar and takes the IdentityRegistry as `agentRegistry` (identity gating on:
creators and agents need an ERC-8004 identity). EAS is not part of this ceremony.

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
2. **First run.**
   ```bash
   forge script script/robinhood-mainnet/DeployAll.s.sol:DeployAll \
     --rpc-url robinhood --account <key> --broadcast --slow \
     --gas-estimate-multiplier 200
   ```
   It stops at `Checkpoint.AwaitingWoodFeed`: `WoodPoolFeed` is minted, nothing
   of Plan B is, and **no ownership has moved**. **No syndicate can be created**:
   the factory is initialised with a closed agent-registry sentinel
   (`AGENT_REGISTRY_CLOSED`, non-zero and codeless), so every `createSyndicate`
   reverts, sponsored or not, from the factory's own initialisation until run 2's
   last step. A vault minted earlier would get a governor with no exposure ledger
   and no bond escrow.
3. **Prime the feed.** Call `WoodPoolFeed.update()` on a keeper until
   `latestRoundData()` answers — at least one `window`, 24h minimum. The deployer
   key owns every contract for this whole interval; that is the cost of the
   warm-up, and it is why step 2 hands nothing off.
   **Before launch, record who holds the WOOD/WETH liquidity**: the V3 full-range
   position and the V2 LP tokens, and whether each is locked. Below
   `MIN_V3_LIQUIDITY` or `MIN_WETH_RESERVE` the feed reverts, which halts propose,
   approve, execute and `ChallengeGame.file` until it recovers. Recovery is the
   Safe deploying and keeping alive a replacement aggregator, then
   `ExposureLedger.setWoodFeed(replacement, maxDelay)`.
4. **Second run.** The same command. The stage gate passes, Plan B / Plan D /
   TokenCourt deploy, and as its last step before the handoff the run opens
   creation by pointing the factory at the real ERC-8004 registry (refusing if any
   syndicate exists). Creation then costs the invite-only fee (1M WOOD to the Safe).
   The handoff runs and `deployAll` returns `Checkpoint.Complete`. Addresses are
   written to `chains/4663.json` last. If a `WoodPoolFeed` with a different
   `ethUsdMaxAge` was already deployed on the target chain, the run refuses to
   adopt it: deploy a new feed under a new salt and prime it.
5. **The Safe's turn.** `acceptOwnership()` on `ProtocolConfig`, `TierRegistry`,
   `ExposureLedger`, `ChallengeGame` and `TokenCourt` (the one-step contracts —
   beacon, factory, GuardianRegistry, sWOOD, StrategyFactory — are already
   transferred). Then re-point `setProtocolFeeRecipient` and
   `setGuardiansFeeRecipient` off the deployer placeholder, seed the slash-appeal
   reserve (`approve` + `registry.fundSlashAppealReserve`), and configure the
   Zodiac Delay module with the asymmetry the spec requires: raises delayed,
   drops immediate.
   **Deferred handoff (v1 launch).** `chains/4663.json` names the deployer as
   `OWNER_MULTISIG`, so run 2 hands nothing off and this step is skipped: the
   deployer key owns every contract and receives the creation fee. To hand off
   later: set `OWNER_MULTISIG` to the real owner (a contract), call
   `factory.setCreationFee(WOOD, 1_000_000e18, <owner>)` from the deployer, re-run
   `DeployAll` (it sends only the transfers), then do this step.

   `script/robinhood-mainnet/deploy.sh` wraps steps 2 to 6 and verifies the
   sources on Blockscout; run it once per stage.
6. **Verify.** `RPC=<url> ./script/verify-robinhood.sh 4663` — it re-derives every
   address from the book's `CREATE3_FACTORY` and fails on any disagreement, and
   checks that every live governor carries the factory's ledger, escrow and tier
   registry.

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
  stale feed is `NoWoodPrice`: block votes still land, but approve votes,
  `ChallengeGame.file`, and `propose` and `executeProposal` for any proposal
  with non-zero required coverage all revert, and the challenge window keeps
  running (see [coverage.md](coverage.md)).
- **Alert on `woodPriceX8()` reverting**, and on the cap binding (the served
  price sitting at `haircut(woodUsdPriceX8)` rather than tracking market).
  Neither emits an event; both have to be polled.
- **A keeper must open guardian reviews.** An unopened review is not a skipped
  review — the governor settles it inline as not-blocked and the proposal
  executes unreviewed.
- **Adding a stock to a live registry.** A token can enter a Portfolio basket only
  once the registry pairs it with its feed. Add `<SYM>` and
  `CHAINLINK_<SYM>_USD_FEED` to the book and the symbol to
  `RobinhoodParams.launchSetSymbols()`, then run `SeedPriceSources`. Run by
  the owner, it broadcasts only the missing writes. Run by anyone else, it
  prints them as target and calldata for the Safe:
  ```bash
  forge script script/SeedPriceSources.s.sol:SeedPriceSources --rpc-url robinhood
  ```

- **Allowlisting a Morpho market before a strategy uses it.** Before a
  `MorphoSupplyStrategy` or `ConcentratedLiquidityStrategy` clone is
  initialised, the `TierRegistry` owner allowlists that market BY ID:
  `setMorphoMarketAllowed(<marketId>, true)`. The id is Morpho's
  `keccak256(abi.encode(loanToken, collateralToken, oracle, irm, lltv))`, so one
  grant binds all five parameters. Otherwise clone-init reverts
  `MorphoMarketNotAllowed`. Execute (and, for CL, `rerange`) re-checks it;
  settle does not, so de-listing never strands funds. Per-address
  `setCounterpartyAllowed` grants for the oracle and the collateral token are no
  longer what admits a Morpho market (the Morpho singleton itself is still a
  counterparty, seeded by the ceremony).

  Before granting, read the five parameters from Morpho
  (`cast call <MORPHO_BLUE> "idToMarketParams(bytes32)(address,address,address,address,uint256)" <marketId>`)
  and recompute the id from them. Refuse the market if its `irm` is the zero
  address (no interest ever accrues and the supply can be frozen), if its
  oracle does not price its collateral in its loan token, if its collateral
  equals its loan token, or if its `lltv` is not the one the market was vetted
  at. The loan == collateral refusal is for the supply strategy: there the
  vault is the lender, and a market whose borrowers post the loan token itself
  can let them borrow more than they post or freeze the supply. For CL the loan
  token is the vault asset and the code accepts collateral that is the vault
  asset or its ERC-4626 wrapper; allowlist only the wrapper market (spUSDG for
  USDG), the market the vault actually borrows from, and do not grant a
  loan == collateral market for CL either, since one id serves both strategies.

  Allowlisting a CL market also means trusting its collateral wrapper: at
  execute the clone approves the vault asset to that wrapper and deposits into
  it, and the separate per-address grant that used to vet the wrapper no longer
  exists, so vet the wrapper's code before granting the market.

  The known 4663 USDG market needs one Safe call:
  `TierRegistry.setMorphoMarketAllowed(0x0309c02dabf0be02682af1a2bde9a457f4df0f0b6bc889cde3f948e5315e4114, true)`.
  Its parameters, recomputed to that id:
  - loanToken USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`
  - collateral spUSDG `0xde770c84FE66E063336b31737cFE9790f18c4087`
  - oracle `0xe694c531F65c4BaBc88A52d7178476e095e51574` (prices spUSDG in USDG)
  - irm AdaptiveCurve `0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1`
  - lltv `0.915e18`

- **Incident: the ERC-8004 registry breaks.** It is a third-party UUPS proxy
  whose owner is an outside EOA. If `ownerOf` starts reverting, then
  `createSyndicate` and every vault's `registerAgent` revert with it. The Safe
  calls `SyndicateFactory.setAgentRegistry(address(0))`. That turns identity
  gating off for creation and for every existing vault at once. Proposing and
  already-registered agents are unaffected. Point it back with
  `setAgentRegistry(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432)` once the
  registry is healthy, and expect `verify-robinhood.sh` to flag the registry
  check while it is zero.

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
