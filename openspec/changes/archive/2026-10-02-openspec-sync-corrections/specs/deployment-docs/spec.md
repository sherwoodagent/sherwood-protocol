## MODIFIED Requirements

### Requirement: Deploy ceremony order and skip rules
The ceremony SHALL be ONE script, `script/robinhood-mainnet/DeployAll.s.sol:DeployAll`, whose phases run in a fixed order inside ONE broadcast: Create3Factory bootstrap → core (`deployCore` + `_seatOwnerWrites`, including the TierRegistry launch set) → UniswapSwapAdapter and the Portfolio / MorphoSupply / ConcentratedLiquidity templates → StrategyFactory → the WOOD price source → Plan B → Plan D → open syndicate creation (`setAgentRegistry`, Mainnet run 2 only) → handoff.

The Fork posture completes in ONE run. The Mainnet posture completes in TWO runs separated by the WOOD feed's warm-up: the first run mints `WoodPoolFeed`, returns `Checkpoint.AwaitingWoodFeed` and performs NO handoff; the operator then calls `WoodPoolFeed.update()` on a keeper until `latestRoundData()` answers (at least one `window`, 24h minimum); the second run finds the feed answering, deploys the coverage stack and hands off. Between the two runs the deployer key still owns every contract — that window is the price of the warm-up and SHALL be stated in the runbook, not discovered.

The broadcaster SHALL equal the book's `DEPLOYER`, and the script reverts "broadcaster != DEPLOYER in the address book" otherwise. There is no skip flag: WHO ends up owning the protocol is a property of the posture. On Mainnet `OWNER_MULTISIG` is REQUIRED from the book and MUST be a contract (Safe), not an EOA. On Fork the owner is the deployer itself, so the handoff still runs and is a no-op; a Fork book MAY carry `OWNER_MULTISIG` only when it equals `DEPLOYER`, and anything else is REFUSED ("Fork posture hands off to the deployer: OWNER_MULTISIG must be absent or equal DEPLOYER") so a mainnet Safe copied into a fork book cannot become the target. `_handoffAll` SHALL refuse an unset target, which would be unrecoverable.

`DeployWood` SHALL be skipped — WOOD is already live on 4663 and on the fork, and `DeployWood` now refuses chain 4663 outright. Every protocol contract is minted through CREATE3, so the address table is order-independent.

Addresses flow IN MEMORY between phases (the `Stack` struct); no phase reads another phase's address out of a file, and no ceremony script reads the process environment. Persistence to `chains/{chainId}.json` is nonetheless REQUIRED — `cli`, `sdk`, the guardian daemon and the app all sync from it — and happens ONCE at the end of `run()`, after validation. The script never CREATES a book: a chain with no book is already refused at pre-flight.

#### Scenario: TierRegistry reaches the address book
- **WHEN** the ceremony completes
- **THEN** `chains/{chainId}.json` carries `TIER_REGISTRY`, and it equals `factory.tierRegistry()`

#### Scenario: Guardian-econ phases hand each other their addresses
- **WHEN** `deployAll` returns `Checkpoint.Complete`
- **THEN** `chains/{chainId}.json` carries `EXPOSURE_LEDGER`, `PROPOSER_BOND_ESCROW` and `CHALLENGE_GAME`, written by `_persist` from the in-memory `Stack` rather than recovered from a broadcast log

#### Scenario: Mainnet stops at the feed gate
- **WHEN** the first Mainnet run reaches the WOOD price source and `latestRoundData()` does not yet answer
- **THEN** `deployAll` returns `Checkpoint.AwaitingWoodFeed`, no Plan B contract is minted and no ownership is transferred

### Requirement: The strategy template allowlist names only live templates

`StrategyFactory`'s approval map starts empty and nothing else populates it, so a template the ceremony does not approve can never be cloned by a proposal. The StrategyFactory phase SHALL approve EXACTLY the three templates carried on the ceremony's `Stack` and SHALL assert all three read back approved. There is no skip path and no `approved > 0` threshold: a template with no code refuses the run ("template holds no code: run the template phases first"). `DeployStrategyFactory._templateKeys()` names the three address-book keys `_persist` writes, and is pinned as an exact set.

The list SHALL name `PORTFOLIO_TEMPLATE`, `MORPHO_SUPPLY_TEMPLATE` and `CONCENTRATED_LIQUIDITY_TEMPLATE`, and nothing else — every key on it has a live contract in `src/strategies/` and a script that deploys it. `MOONWELL_SUPPLY_TEMPLATE`, `AERODROME_LP_TEMPLATE`, `WSTETH_MOONWELL_TEMPLATE` and `MAMO_YIELD_TEMPLATE` were REMOVED (deprecated, 2026-08-04): none has a contract remaining in `src/strategies/`, none resolves in a committed address book, and removal affects only a NEW `StrategyFactory` — already-deployed factories keep the approvals they were given.

`MorphoSupplyStrategy` requires NO Morpho address and NO market params at deploy time. It is an ERC-1167 template: the Morpho singleton, the `MarketParams` tuple and the supply amount all arrive per clone via `_initialize(bytes)`, so they are proposal inputs. The template is deliberately left uninitialized, which is the correct resting state for a clone source.

#### Scenario: Morpho template reaches the allowlist
- **WHEN** the ceremony completes
- **THEN** `chains/{chainId}.json` carries `MORPHO_SUPPLY_TEMPLATE`, `_templateKeys()` names it, and `StrategyFactory.approvedTemplate` is true for it

#### Scenario: Deprecated template keys refused entry
- **WHEN** a deprecated key is re-added to `_templateKeys()`
- **THEN** the exact-set assertion in `test/deploy/DeployMorphoStrategy.t.sol` FAILS, because a key with no backing contract overstates what the protocol can propose

### Requirement: The Uniswap V3 factory is counterparty-allowlisted before the CL template ships

`ConcentratedLiquidityStrategy._initialize` binds its proposer-supplied `uniswapFactory` through `vault() -> governor() -> tierRegistry() -> isCounterpartyAllowed` and reverts `CounterpartyNotAllowed` otherwise. That binding is load-bearing rather than defensive: the pool's provenance is settled by asking that factory `getPool(token0, token1, fee)`, so a factory the proposer chose is no authority at all (pashov 2026-08 finding #4).

An unlisted factory therefore does not degrade the template, it makes it INERT — the ceremony completes, the StrategyFactory phase allowlists the template, agents write proposals, and every one reverts at clone-init. `TierRegistry.setCounterpartyAllowed(UNISWAP_V3_FACTORY, true)` SHALL therefore be part of the launch set the core phase seeds, before the CL template phase runs.

This SHALL be enforced as a deploy-time assertion, not as prose in a runbook. Inside the one ceremony the deployer still owns `TierRegistry` when the CL phase runs, so the grant is MADE by `_seedTierRegistry` and then VERIFIED here — a phase-ordering constraint, not a circular one. The assertion SHALL fail when the named registry cannot answer the selector: a registry that cannot be asked has not vouched. There is no skip branch, because there is no longer a run in which the core phase did not happen.

#### Scenario: CL phase run before the grant
- **WHEN** the CL template phase runs and `isCounterpartyAllowed(UNISWAP_V3_FACTORY)` is false
- **THEN** the run reverts naming the exact call the registry owner must make, before the template is deployed or persisted

#### Scenario: Registry named but unanswerable
- **WHEN** the ceremony's tier registry (on the in-memory `Stack`) holds no code, or answers `isCounterpartyAllowed` with anything other than a 32-byte word
- **THEN** the script reverts rather than treating the silence as a grant

### Requirement: Each CL pool's volatile leg is counterparty-allowlisted before its proposal

Pool provenance establishes where a pool came from; it says nothing about what the pool TRADES. A proposer can deploy a worthless ERC-20, create a genuine `(vaultAsset, junk)` pool through the real factory, initialise it at a price of their choosing, and pass every provenance check on the merits — after which `_rebalanceToTarget` buys that token with vault asset, priced by the only venue that quotes the pair.

`ConcentratedLiquidityStrategy._initialize` therefore binds the pool's non-asset token (`otherToken`) through `isCounterpartyAllowed` alongside `swapAdapter`, `positionManager`, `morpho` and `uniswapFactory` (the market itself is admitted by its allowlisted id), and re-checks it at `execute()` and `rerange()`.

This is a PER-PROPOSAL obligation, not a ceremony step: the volatile leg is chosen per clone, so no deploy script can assert it. The registry owner SHALL call `setCounterpartyAllowed(<volatile leg>, true)` for each token a CL proposal is expected to trade, before that proposal is executed. Exits are deliberately NOT gated on it — `settle()` stays open under the existing capital-hostage rule, so a demotion cannot strand the funds it is meant to protect.

#### Scenario: Proposal naming an unvouched volatile leg
- **WHEN** a CL proposal names a pool whose non-asset token is not counterparty-allowlisted
- **THEN** clone-init reverts `CounterpartyNotAllowed(otherToken, registry)`, failing the proposal rather than the batch

#### Scenario: Volatile leg demoted after init
- **WHEN** the leg is demoted between clone-init and `execute()`, or before a permissionless `rerange()`
- **THEN** both entry paths revert, while `settle()` still completes

### Requirement: Core wiring order inside deployCore
The canonical `DeploySherwood.deployCore` SHALL wire in this order: executor lib and vault impl; ProtocolConfig (`Ownable2Step`; its constructor takes only the owner and seeds the fee splits); governor impl wrapped in a `GovernorBeacon` (per-vault governors are `BeaconProxy`s minted at `createSyndicate` — no singleton governor proxy is deployed); **sWOOD proxy before the registry proxy** (the registry's `initialize` takes the sWOOD address; the registry↔sWOOD cycle resolves via the set-once `StakedWood.setRegistry` call after the registry exists); `TierRegistry` (owner = deployer); then the factory proxy (address predicted by CREATE3 and asserted), initialised with that tier registry in its `InitParams`. The `SYNDICATE_GOVERNOR` address-book slot SHALL be persisted as zero — governors are per-vault, resolved via `factory.governorOf(vault)`.

`ProtocolConfig`, the `GovernorBeacon`, `TierRegistry` and every other protocol contract are minted through CREATE3 under the `DeploySalts` namespace `sherwood.robinhood.v1.*`. The `Create3Factory` itself is minted through the canonical CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` at salt `sherwood.robinhood.v1.create3-factory` with a PINNED initcode hash, so every protocol address is a function of `(DEPLOYER, salt)` ONLY. A change to the compiled bytecode of `script/utils/Create3.sol` or `Create3Factory.sol`, or a toolchain change, moves that hash and with it the whole address table; metadata is off (`bytecode_hash = "none"`, `cbor_metadata = false`), so a comment-only edit does not.

Validation SHALL therefore read every protocol key back as `chains/{chainId}.json value == Create3.addressOf(CREATE3_FACTORY, salt)`; `script/verify-robinhood.sh <chainId>` is that check, re-deriving the `Create3Factory` from its compiled initcode and the book's `DEPLOYER`, then every key from it, and failing on any book value that disagrees.

The handoff SHALL transfer, all inside the Mainnet run: one-step — `GovernorBeacon`, `SyndicateFactory`, `GuardianRegistry`, `StakedWood`, `StrategyFactory`; two-step (`Ownable2Step`, so the Safe owes `acceptOwnership()`) — `ProtocolConfig`, `TierRegistry`, `ExposureLedger` and `ChallengeGame`. Each leg is skipped when it is already done, so a resumed run is a no-op rather than a revert.

#### Scenario: Beacon validated non-empty
- **WHEN** post-deploy validation runs
- **THEN** `GovernorBeacon.implementation() != address(0)` and `beacon.owner` is the effective owner (multisig post-handoff, deployer when skipped)

#### Scenario: Two-step handoffs asserted as pending
- **WHEN** the multisig handoff runs (ProtocolConfig and TierRegistry are `Ownable2Step`)
- **THEN** validation asserts `pendingOwner == multisig` and the runbook requires the multisig to call `acceptOwnership()` — a handoff that never armed the two-step transfer is caught at deploy time; acceptance is the Safe's post-deploy step

### Requirement: Mainnet-faithful parameters are not accelerated
The fork deploy SHALL bake the real mainnet parameters and the operator SHALL NOT accelerate them for guardian sims (advance time with `evm_increaseTime` instead): `MIN_VOTING_PERIOD` 1h and `MIN_COOLDOWN_PERIOD` 1h (governor impl constructor immutables, held at the per-vault floor so they can never bind tighter than the setters; the 24h operating value is the factory's per-vault default), `reviewPeriod` 24h and `blockQuorumBps` 30% (registry init), `minGuardianStake`/`minOwnerStake` 10,000 WOOD each, `coolDownPeriod` 7 days, `minSlashBps`/`maxSlashBps` 10%/100% (sWOOD init), and the 200 bps management fee stamped per vault. Every one of these is a committed constant in `script/robinhood-mainnet/RobinhoodParams.sol` — the same values on Mainnet and Fork posture, with no runtime override. (The 46630 testnet's 600s-floor governor upgrade is explicitly NOT applied to the fork.)

#### Scenario: Governance window traversal
- **WHEN** a proposal must pass the 24h vote + 24h review windows
- **THEN** the operator advances `evm_increaseTime 172800` + `evm_mine` rather than deploying shortened floors

### Requirement: Lifecycle validation with route and staleness discipline
A full one-fund lifecycle (owner stake → fund create → deposit → strategy propose → vote → execute → settle) SHALL be run through the CLI's first-class `robinhood-fork` network with an operator wallet separate from the deployer. Swap routes SHALL be quoted on the fork with the V4Quoter before proposing — never guessed (NVDA/TSLA have direct USDG v4 pools at fee 3000 / tickSpacing 60; the 5%-fee direct pools quote garbage and breach the 5% slippage floor). Because governance warps age the Chainlink push feeds past `PortfolioStrategy`'s flat 26h `MAX_PUSH_PRICE_AGE`, the operator SHALL refresh each feed's `updatedAt` via `setStorageAt` after each warp; there is no per-proposal price-age input.

#### Scenario: Round-trip sanity result
- **WHEN** the validated lifecycle runs (50,000 USDG deposited, 40k deployed into NVDA/TSLA, settled with no market move)
- **THEN** settlement returns approximately the deposit minus round-trip fees (validated: 49,760.78 USDG, −0.48%)

#### Scenario: Stale feed after warp
- **WHEN** execute/settle runs after a 48h warp with default max price age
- **THEN** it trips `StalePrice`; refreshing each feed's `updatedAt` clears it

### Requirement: The WOOD price source is minted by the ceremony, per posture
On Mainnet posture the ceremony SHALL mint `src/pricing/WoodPoolFeed.sol` at the `sherwood.robinhood.v1.wood-pool-feed` salt and wire it as the ledger's market source. The feed reads two independent `WOOD/WETH` venues — a Uniswap-V2-style pair's own cumulative-price accumulators and a Uniswap V3 pool's tick accumulator, averaged from a stored snapshot to the live `observe([0])` — and the chain's Chainlink **ETH/USD** feed, composed as `WOOD/USD = TWAP(WOOD per ETH) × ETH/USD`; it needs no Chainlink WOOD/USD aggregator, which is the point of it. The V3 leg is specified in full below.

Pre-flights, all PRE-broadcast:
- The two named venues SHALL be DISTINCT and each SHALL hold exactly `{WOOD, WETH}`. The V2 pair's WETH reserve SHALL be at or above `MIN_WETH_RESERVE`; the V3 pool's floor is its in-range `liquidity()`, below.
- WOOD and WETH SHALL share a decimals count. The composition multiplies a raw UQ112x112 ratio by ETH/USD with no decimals normalisation, so a mismatch prices WOOD off by orders of magnitude while every other check passes.
- The V2 pair SHALL have traded within `MAX_PAIR_IDLE` (5 minutes). A pair with no trade in that span has no live market behind it; `update()` syncs the pair and would still snapshot, so this guard refuses a dead market, not a dead keeper. On 4663 the pair trades continuously (measured 2026-08-04: 10s idle), so the guard is near-free in production and impossible to satisfy on a fork.
- The ETH/USD feed answers positive and is no staler than `ETH_USD_MAX_AGE`.

#### Scenario: Deploy lays a baseline but leaves the oracle unpriced
- **WHEN** the script completes
- **THEN** `latestObservation` is set, `latestRoundData()` still reverts `PriceUnavailable`, and `DeployAll` returns `Checkpoint.AwaitingWoodFeed` — an operator cannot mistake the deploy for a primed oracle

#### Scenario: Idle pool refused before deploying
- **GIVEN** the `WOOD/WETH` pair has not traded within `MAX_PAIR_IDLE` (5 minutes)
- **THEN** the script refuses PRE-broadcast, naming that no live market stands behind the pair

#### Scenario: Fork cannot prime the oracle
- **GIVEN** a Tenderly vnet, where the pool stops trading at the fork point and `idle` grows without bound
- **THEN** the idle pre-flight refuses the vnet pair, so the Fork posture mints `ForkWoodFeedFixture` instead of `WoodPoolFeed` — on mainnet the pair trades continuously (measured 2026-08-04: 10s idle), so the guard is near-free in production

### Requirement: The WOOD feed's second leg is a Uniswap V3 pool, averaged from a stored snapshot of its tick accumulator to the live one

Chain 4663 carries ONE Uniswap-V2-style WOOD/WETH pair, so the second leg of the two-leg WOOD/USD feed SHALL be a Uniswap **V3** WOOD/WETH pool rather than a second V2 pair. `chains/{chainId}.json` SHALL carry it under `WOOD_WETH_UNISWAP_V3_POOL` together with the factory that created it under `WOOD_WETH_UNISWAP_V3_FACTORY` — chain 4663 carries TWO Uniswap V3 deployments and the canonical `UNISWAP_V3_FACTORY`'s WOOD/WETH pools are empty — and `DeployAll._readInputs` SHALL require both keys from the address book (no environment override), with NO `WOOD_WETH_SUSHI_V2_PAIR` reference remaining. `update()` SHALL store accumulator readings for BOTH legs — the pair's cumulative price and the pool's `observe([0])` tick cumulative. The V2 leg SHALL be averaged between its two stored readings. The V3 leg SHALL be averaged from a stored reading (the latest one once it is at least `window` old, else the previous one) to the pool's LIVE `observe([0])` accumulator, over a span of at least `window`, so a crash in the pool is tracked between rolls rather than hidden until the next one. The V3 leg SHALL NOT read the pool's observation ring backwards: that ring is written by any swapper, one slot per SECOND in which the pool is touched, and `observationCardinality` is a `uint16`, so no ring anyone can pay for spans a 24h window against a per-second writer and a backward read is an availability lever held by the market. Its depth floor is the pool's in-range `liquidity()` (`MIN_V3_LIQUIDITY`), the V3 equivalent of the V2 leg's WETH reserve floor.

Pre-flights on the pool, all PRE-broadcast: it has code, it holds exactly `{WOOD, WETH}`, `fee()` answers, `liquidity() >= MIN_V3_LIQUIDITY`, the booked factory's `getPool(token0, token1, fee())` resolves back to the booked pool and the pool names that same factory, and `observe([0])` answers — the read the leg actually makes, which any initialised pool serves whatever its ring holds. `MIN_V3_LIQUIDITY` SHALL be refused rather than truncated above the `uint128` width a pool reports liquidity in — a silent truncation there REMOVES the floor instead of raising it.

There SHALL be no cardinality-growing ceremony step and no ring-sizing derivation: with the leg snapshotting the accumulator forward, the ring's length is irrelevant to the feed.

#### Scenario: The lower of the two legs is served, the V3 leg's near end live
- **WHEN** `latestRoundData()` answers after the window has been spanned
- **THEN** the V3 leg is the arithmetic-mean tick from a stored tick cumulative at least `window` old to the live `observe([0])` cumulative, converted into the V2 leg's orientation and scale, the LOWER of the two legs is served, and `updatedAt` is the V2 leg's latest snapshot

#### Scenario: A V3 crash is tracked between rolls
- **GIVEN** the V3 pool falls and stays down after the keeper's last roll
- **WHEN** `latestRoundData()` is read before the next roll, while its `updatedAt` is still within the ledger's `WOOD_FEED_MAX_DELAY`
- **THEN** the V3 leg already carries the fall, weighted by its share of the averaged span

#### Scenario: A market that evicts the pool's observation ring cannot halt the feed
- **GIVEN** dust swaps have written every slot of the V3 pool's observation ring, so `observe([window, 0])` reverts `OLD`
- **WHEN** `latestRoundData()` is read and `update()` is called
- **THEN** both answer, because the far end is a stored reading and the near end is `observe([0])`, which the pool synthesises from its newest observation whatever the ring holds, and no WOOD-priced path — `propose`, `voteOnProposal`, `requireApproveQuorum`, `ChallengeGame.file` — halts

#### Scenario: A pool that will not serve the live accumulator is refused pre-broadcast
- **GIVEN** the V3 pool's `observe([0])` reverts or answers malformed
- **WHEN** `DeployWoodPoolFeed` runs
- **THEN** it reverts `PRE-FLIGHT: V3 pool does not serve observe([0])` before broadcasting, because a pool that will not serve that read deploys a feed whose `update()` can never snapshot the second leg

#### Scenario: A pool from the other V3 deployment is refused pre-broadcast
- **GIVEN** `WOOD_WETH_UNISWAP_V3_POOL` names a pool the booked `WOOD_WETH_UNISWAP_V3_FACTORY` did not create
- **WHEN** `DeployWoodPoolFeed` runs
- **THEN** it reverts `PRE-FLIGHT: WOOD_WETH_UNISWAP_V3_POOL is not the factory's pool for (WOOD, WETH, fee)` before broadcasting, because booking the wrong venue silently removes the two-leg `min` that is the feed's manipulation control

### Requirement: The fork supplies its WOOD price through a fixture feed
On Fork posture the ceremony SHALL mint `script/robinhood-mainnet/ForkWoodFeedFixture.sol` instead, at its own distinct salt, priced from the fork's OWN state — the WOOD/WETH pair reserves times the live ETH/USD answer — so bond valuations on the fork track mainnet rather than an invented number. The fixture reports `updatedAt` as `block.timestamp`, so it stays fresh across the `evm_increaseTime` warps a governance traversal needs; that makes staleness untestable through it, which is the correct trade for a fixture whose only job is keeping the price path alive across time travel. **The fixture SHALL refuse to be constructed on chain 4663.** A fixture feed on mainnet would price every guardian bond off an owner-writable number.

#### Scenario: Fixture feed refused on mainnet
- **WHEN** `ForkWoodFeedFixture` is constructed on chain 4663
- **THEN** the constructor reverts "ForkWoodFeedFixture: refused on 4663" before the ceremony can adopt it

#### Scenario: Idle pool refused before deploying
- **GIVEN** a WOOD/WETH pair that has not traded within `MAX_PAIR_IDLE`
- **THEN** the Mainnet feed phase refuses PRE-broadcast, naming that no live market stands behind the pair

#### Scenario: Fork price survives a governance warp
- **GIVEN** the fixture feed is wired as the ledger's market source
- **WHEN** the operator advances 48h with `evm_increaseTime` to traverse the vote + review windows
- **THEN** `woodPriceX8()` still resolves — the fixture reports itself fresh at the new `block.timestamp`, so no post-warp refresh step is owed

### Requirement: DeployPlanB asserts delegation is off
`DeployPlanB`'s post-broadcast pre-flights SHALL fail the run if `delegationEnabled` reads true on the target chain, naming the delegator-walkout hole: delegated stake is credited to a ~35-day coverage window while `requestUnstakeDelegation` checks only the delegator, and the unbonding pool is slashable for only `coolDownPeriod`.

#### Scenario: Delegation accidentally on
- **GIVEN** `delegationEnabled` reads true on the target chain
- **WHEN** the post-broadcast pre-flights run
- **THEN** the run FAILS with a message naming the delegator-walkout hole

#### Scenario: Preflight tests cover both invariants
- **THEN** `test/deploy/DeployPlanBPreflight.t.sol` covers: the duration ceiling seated; delegation-on fails the named assert and delegation-off passes; a code-less feed refused; a zero `maxDelay` refused; a foreign `StakedWood.exposureLedger` slot refused (the `GuardianRegistry` slot is covered in `test/deploy/DeployAll.t.sol`); and the two post-broadcast price checks (unset cap, cap with nothing priced beneath it)

### Requirement: Plan D deployment pre-flights and wiring order
The Plan D phase (ChallengeGame, against the Plan B contracts minted earlier in the same ceremony) SHALL run pre-flights before deploying anything, then wire the game's four roles in this order: `swood.setAuthorizedSlasher(game)` → `game.setStakedWood(swood)` → `tierRegistry.setAuthorizedDemoter(game)` → `ledger.setCoverageFreezer(game)`. The order is load-bearing at both ends: `setStakedWood` rejects a sWOOD that has not already granted the slasher role, so the GRANT precedes the POINTER; and `setCoverageFreezer` reverts `CoverageFrozen` once coverage is frozen, so the freeze role is granted LAST. Checks:
- PRE-FLIGHT 1: each of the three roles (`coverageFreezer`, `authorizedDemoter`, `authorizedSlasher`) MUST be UNSET **or already the game this run will mint** — the setters overwrite silently, so a role held by a FOREIGN address is refused rather than clobbered, while a resumed run adopts its own game instead of dying. Rotations require clearing by governance first.
- PRE-FLIGHT 4 (ownership): the broadcaster SHALL own `EXPOSURE_LEDGER`, `TIER_REGISTRY` and `STAKED_WOOD`; all three grant setters are `onlyOwner`, so all three get a named refusal ("PRE-FLIGHT: broadcaster does not own …") rather than an opaque `OwnableUnauthorizedAccount` mid-run.
- PRE-FLIGHT 2: `swood.exposureLedger()` SHALL equal `EXPOSURE_LEDGER`.
- PRE-FLIGHT 3: the COMPOSED `ledger.woodPriceX8() != 0` (not the raw scalar) — a zero composed price means `file()` reverts `WoodPriceUnset` and nothing can be challenged. Read by low-level PROBE rather than a typed call: that view reverts `NoWoodPrice` instead of returning zero when no source can price WOOD, and a typed call would let the revert propagate as an opaque script failure. Both shapes (reverts, or answers zero) fold into the same refusal, since to the game they are the same problem.
- Drift guard: `game.challengeWindow() == ledger.challengeWindow()`.
- Post-conditions: all four roles verified to land on THIS game, plus the game's `exposureLedger`/`tierRegistry` constructor pointers.

The broadcaster MUST already own the ledger, tier registry, and sWOOD. `game.setStakedWood(swood)` is doubly load-bearing: without it `file` itself reverts `ZeroAddress`, because the game reads the challenge electorate off sWOOD. Manual follow-ups are load-bearing too: the OFF-CHAIN bug-bounty program (on-chain a successful challenger gets its bond back less the settle burn, plus the prosecutor fee from the convicted proposer's bond), review of `voteWindow` and `challengeQuorumBps` against the real guardian cohort's size and response capability, and Ownable2Step handoff of game ownership.

#### Scenario: Role theft refused
- **WHEN** the Plan D phase runs against a chain where a DIFFERENT ChallengeGame already holds `coverageFreezer`
- **THEN** the run reverts its PRE-FLIGHT before deploying a new game

#### Scenario: Resumed run adopts its own game
- **GIVEN** a previous run already granted all three roles to the game at this ceremony's CREATE3 address
- **THEN** the pre-flight passes, nothing is minted twice and no setter is re-issued

#### Scenario: Composed-price check catches the right failure mode
- **WHEN** the raw `woodUsdPriceX8` scalar is set but the composed `woodPriceX8()` is zero (or vice versa)
- **THEN** the pre-flight follows the composed value — the figure `file()` actually divides by

### Requirement: The challenge vote's launch parameters are an operator decision
`voteWindow` (7 d, floored at `MIN_VOTE_WINDOW` = 2 d) and `challengeQuorumBps` (3,000 bps of `totalStakeAtFiling`, bounded to [1,000, 10,000]) SHALL be reviewed against the live guardian cohort before the game is handed off, because together they decide whether an honest filing can be carried at all: the quorum's denominator, `totalStakeAtFiling`, is the votable stake (total staked WOOD at `filedAt - 1` less the accused cohort's stake then) plus the accused cohort's capped stake at execution, and a filing whose votable stake cannot reach the quorum is refused (`NoVotableStake`), so a network whose stake concentrates in a few large guardians can leave the bar unreachable by everyone else the moment one of them is accused. The deploy phase SHALL verify `game.stakedWood() == STAKED_WOOD`, or the electorate that votes is not the cohort that gets slashed, and SHALL verify the Plan D roles are intact (`ledger.coverageFreezer()`, `tiers.authorizedDemoter()`, `swood.authorizedSlasher()` all equal to the game) — or a conviction dead-ends at `_settle`. These values await an economics run; the launch set is a decision, not a default to inherit.

Manual follow-ups: an sWOOD upgrade touching `slashVerdict`'s ABI and any ChallengeGame redeploy that calls it MUST ship as ONE atomic governance batch (a selector mismatch makes every `resolve()` revert with coverage frozen); monitor the rate of filings that reach quorum against those that lapse in silence, since a cohort that never votes turns the whole accountability tail into a time delay.

#### Scenario: Mismatched sWOOD identity refused
- **WHEN** `game.stakedWood()` is unset or differs from `STAKED_WOOD`
- **THEN** the phase refuses before handoff — an unwired game cannot even accept a filing, and a mismatched one measures its electorate against the wrong book of stake

#### Scenario: Broken Plan D wiring refused
- **WHEN** any of the three Plan D roles no longer points at the challenge game
- **THEN** the phase refuses — a challenge that reaches its convict quorum must be able to execute the verdict

### Requirement: Chain-specific factory identity configuration
On Robinhood Chain the factory's `agentRegistry` SHALL end the ceremony as the canonical ERC-8004 IdentityRegistry (`0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`, `RobinhoodParams.AGENT_REGISTRY`) — set at initialisation on the Fork posture, and on Mainnet set in run 2 after the closed sentinel `AGENT_REGISTRY_CLOSED` held creation shut — so `createSyndicate` requires the creator to own `creatorAgentId` and `registerAgent` requires the agent NFT to be owned by the agent or the vault owner. Validation SHALL assert `AGENT_REGISTRY_CLOSED` at `Checkpoint.AwaitingWoodFeed` and `AGENT_REGISTRY` at `Checkpoint.Complete`. Because the registry is a third-party upgradeable contract, it is a liveness dependency: if it breaks, the owner Safe SHALL call `setAgentRegistry(address(0))`, which turns identity gating off for creation and for every existing vault's `registerAgent` without a redeploy. The factory carries no ENS registrar (there is no ENS/Durin registrar on 4663).

#### Scenario: Identity enabled on Robinhood
- **WHEN** post-deploy validation runs at `Checkpoint.Complete` on 4663 or its fork
- **THEN** `factory.agentRegistry() == 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`

### Requirement: Accepted oracle risks are stated in the deploy runbook
Two oracle exposures are accepted for v1, not open defects, and SHALL be documented in the operator's line of sight rather than only in source natspec: (1) Chainlink aggregators clamp at `minAnswer`/`maxAnswer` — a clamped price is anti-conservative, understating `coverageUsd` (asset side) and over-valuing guardian bonds via `woodPriceX8` (WOOD side), with `woodHaircutBps` a fixed discount rather than a clamp bound; and (2) Robinhood Chain 4663 publishes no sequencer-uptime feed, so the standard staleness-plus-grace-period sequencer gate cannot be built — `ExposureLedger` reads aggregators directly, and `ASSET_FEED_MAX_DELAY` SHALL be sized tightly enough that a plausible outage pushes reads past staleness while still clearing the aggregator's own publication heartbeat.

The WOOD half of exposure (1) is now BOUNDED rather than merely disclosed: every market source, Chainlink included, is admitted only under `min(source, woodUsdPriceX8)`, so a clamped-high aggregator can over-value bonds by at most the cap. The asset half is unchanged — `coverageUsd` has no such ceiling.

#### Scenario: Reviewer reads the runbook
- **WHEN** a reviewer or deploy operator reads the runbook end to end
- **THEN** they encounter the aggregator clamping risk with its anti-conservative direction and the affected read paths (`coverageUsd`, `woodPriceX8`), the fact that the WOOD path is capped and the asset path is not, and the absence of a sequencer-uptime feed on Robinhood 4663 with why the usual staleness gate cannot exist, all stated as accepted-for-v1

### Requirement: The WOOD price carries two accepted overstatements, and `woodHaircutBps` is the control
Two exposures are ACCEPTED rather than eliminated (owner decision 2026-08-02). The runbook SHALL state both, together with the parameter that covers them.

**(a) The two legs are not contemporaneous.** `WoodPoolFeed` multiplies a near-real-time WOOD/ETH average by a single Chainlink ETH/USD answer that may be up to one heartbeat old — the live 4663 feed was measured **10.7 hours old while perfectly healthy**, so this is the normal case, not a degraded one. During an ETH drawdown inside that heartbeat the pair ratio rises while the stale, pre-drawdown ETH price is still the multiplier, so WOOD/USD reads high by roughly the size of the ETH move and every bond is over-valued until the feed ticks. **No attacker capital is required** — ordinary market movement against a slow feed, which makes it likelier than any manipulation scenario.

It is accepted because the remedy is worse: tying the ETH answer's age to the averaging `window` would couple two independent bounds to remove an overstatement that is already bounded in magnitude. `ethUsdMaxAge` is therefore deliberately INDEPENDENT of `window` (whose own floor is `MIN_WINDOW`, 24 hours).

**(b) Residual crash lag** of up to `window + maxDelay`, inherent to averaging and the price paid for manipulation resistance.

Both OVERSTATE bond value — the dangerous direction — and both are bounded by the same two controls: `woodUsdPriceX8` truncates anything above the cap, and `woodHaircutBps` pre-funds an allowance below it. **`woodHaircutBps` is therefore LOAD-BEARING.**

**The shipped value is 5,000 — a 50% allowance — and the Plan B phase SHALL seat it** inside the broadcast from `RobinhoodParams.WOOD_HAIRCUT_BPS`, with no runtime override. The ledger's own default is 10,000, which is no haircut and therefore no allowance at all, and its setter ACCEPTS 10,000 as a legal value — so nothing else in the stack refuses that configuration and it would ship silently. Pre-flight 9 refuses it. 5,000 is also the ledger's `MIN_WOOD_HAIRCUT_BPS`, so the deploy default and the floor coincide by design and any raise of the floor must move the deploy constant in the same change. Precisely: 5,000 values every source at 50%, so an overstatement of up to 100% still leaves bonds valued at or below their true worth.

5,000 was once rejected as too costly to guardian return on equity, but that was under full-coverage reservation. With declared locks the haircut is the ONLY buffer between the WOOD price at approval and at verdict 4–6 weeks later: at 7,000 the cohort's burn equals the loot after a 30% WOOD drop, at 5,000 after a 50% drop, and guardian ROE stays at 1.6–4.2%/yr. 5,000 was adopted as the launch configuration on that basis.

**The shipped value sits ON the floor, so there is no downward travel left.** Lowering the haircut would be the safe direction (more allowance, bonds valued lower, quorums harder), but the setter refuses anything below `MIN_WOOD_HAIRCUT_BPS`, and the removal of the once-per-day interval therefore buys nothing here. The crisis brake is the other lever this section names: lowering `woodUsdPriceX8` truncates every bond, takes one owner transaction, and is likewise un-rate-limited on-chain. Raising the floor is not a parameter change at all — `MIN_WOOD_HAIRCUT_BPS` is a constant, so it needs a ledger redeploy.

The feed's own window-vs-staleness invariant is unaffected and remains enforced by `WoodPoolFeed` itself — a different problem (structural unavailability) with a different fix.

#### Scenario: Operator sizes the haircut
- **WHEN** the operator seats `woodHaircutBps` before launch
- **THEN** the runbook states that the value is an allowance against the ETH-staleness overstatement and the crash lag, that the shipped value is 5,000 (a 50% allowance, equal to the ledger floor), that 10,000 leaves none at all and is refused by pre-flight 9, and that the earlier guardian-ROE objection to 5,000 was reconsidered under declared locks

#### Scenario: Deploy would leave the haircut at the ledger default
- **WHEN** `DeployPlanB` would complete with `woodHaircutBps == 10_000`
- **THEN** pre-flight 9 FAILS, naming what the allowance is FOR rather than only that the value is out of range

#### Scenario: Bond valuation needs tightening during a crash
- **GIVEN** the deploy seated the haircut at the floor minutes earlier
- **THEN** `setWoodUsdPrice` succeeds at once — the on-chain interval that would have refused it is gone, and any delay now comes from the owner Safe's module configuration — while `setWoodHaircutBps` below `MIN_WOOD_HAIRCUT_BPS` is refused by value, not by time
