# Deployment Specification

## Purpose

Requirements on the Sherwood deployment process: the mainnet-faithful Robinhood fork environment (Tenderly vnet, chain 9994663), the core deploy ceremony and its wiring order, the guardian-econ layered deployments (Plan B ledger, Plan D challenge game, TokenCourt) with their pre-flight checks, and chain-specific constraints. Scenarios are the verification steps an operator runs to prove each requirement held.

## Requirements

### Requirement: Chain targeting and fork identity
The Robinhood mainnet deploy script SHALL refuse to run unless `block.chainid` is 4663 (Robinhood mainnet) or equals the value of `ROBINHOOD_FORK_CHAIN_ID` (e.g. 9994663 for the Tenderly vnet fork). The fork is mainnet-faithful: USDG stablecoin, official Uniswap v3+v4, Chainlink push feeds, real tokenized-stock liquidity, and the live WOOD token (`0xf8bc08092c06db6148114dcf82af881f1085f92b`, 18-dec, 1B supply, ownership renounced).

#### Scenario: Wrong chain refused
- **WHEN** `DeployRobinhoodMainnet` runs against a chain that is neither 4663 nor the configured fork chain id
- **THEN** the script reverts "wrong chain" before broadcasting anything

#### Scenario: Fork writes its own address book
- **WHEN** the ceremony runs with `ROBINHOOD_FORK_CHAIN_ID=9994663`
- **THEN** deployed addresses persist to `chains/9994663.json`, not `chains/4663.json`

### Requirement: Robinhood contract-size constraint
Every deployable contract's runtime bytecode SHALL fit Robinhood Chain's `MaxCodeSize` of **98,304 bytes** (0x18000, 4× the EIP-170 24,576 limit — ArbOS/Arbitrum Orbit). CI SHALL enforce this limit itself (via `forge build --sizes --json` plus a 98,304-byte gate) because forge's built-in size check enforces the wrong limit (24,576) and its non-zero exit on the 24,576 warning is not the gate.

#### Scenario: Oversized contract fails CI
- **WHEN** any contract's `runtime_size` exceeds 98,304 bytes
- **THEN** the CI size job fails, naming the offender and its size

#### Scenario: 24,576-byte warning alone does not fail
- **WHEN** a contract exceeds 24,576 bytes but is under 98,304
- **THEN** the size gate passes — the EIP-170 warning is suppressed (`|| true`) and only the Robinhood limit is enforced

### Requirement: Ephemeral vnet and pre-committed externals
Tenderly vnets expire. When the RPC 404s, the operator SHALL mint a new vnet against the same fork target and re-run the deploy ceremony and funding: the chain id (9994663) and all external addresses (USDG, WETH, Uniswap SwapRouter02/QuoterV2, v4 PoolManager/V4Quoter, stock tokens, Chainlink feeds) stay the same; only the RPC URL and the Sherwood core addresses change. Externals are pre-committed in `chains/9994663.json` and SHALL survive re-deploys — `ScriptBase._writeAddresses` patches only the core keys in place. The Tenderly admin RPC (cheats) is a secret held as `TENDERLY_ROBINHOOD_RPC_URL` in `contracts/.env` and SHALL never be committed.

#### Scenario: Regeneration after expiry
- **WHEN** the vnet RPC 404s
- **THEN** the operator mints a new vnet, updates `TENDERLY_ROBINHOOD_RPC_URL` (and public-RPC constants if the base URL changed), re-runs the deploy ceremony, syncs the new core addresses into `cli/src/lib/addresses.ts` and `app/src/lib/contracts.ts` (plus the `STRATEGY_TEMPLATE_LABELS` portfolio entry), re-funds wallets, and re-runs the lifecycle/guardian sim

#### Scenario: Externals survive redeploy
- **WHEN** the core deploy re-runs against a fresh vnet
- **THEN** the WETH / USDG / Uniswap / Chainlink entries in `chains/9994663.json` are unchanged and only core keys are patched

### Requirement: Deployer authentication on the fork
On the fork the deployer (`0x5A00afAecE9CF61A768E2AE2713084C8d354DF94`) SHALL be impersonated — no private key — because the Tenderly admin RPC accepts `eth_sendTransaction` from any sender. Forge broadcasts SHALL use `--unlocked --sender 0x5A00…` (plus `--broadcast --slow --gas-estimate-multiplier 200`), and the deployer SHALL be funded with native gas via `tenderly_setBalance` before the first broadcast.

#### Scenario: Unfunded deployer
- **WHEN** the ceremony runs before funding the deployer
- **THEN** the first broadcast fails for gas; funding via `tenderly_setBalance` then re-running succeeds

### Requirement: Deploy ceremony order and skip rules
The fork ceremony SHALL run three scripts in order, each broadcast with the flags above:
1. `script/robinhood-mainnet/Deploy.s.sol:DeployRobinhoodMainnet` with `WOOD_TOKEN=<live WOOD>`, `SKIP_MULTISIG_HANDOFF=true`, `ROBINHOOD_FORK_CHAIN_ID=9994663` — core + zero-adapter PriceRouter; no ENS/ERC-8004 (both registrar addresses are `address(0)` on Robinhood).
2. `script/robinhood-mainnet/DeployPortfolioStrategy.s.sol` — UniswapSwapAdapter (v3+v4) + PortfolioStrategy template.
3. `script/DeployStrategyFactory.s.sol` with `SKIP_MULTISIG_HANDOFF=true` — keyless-clone StrategyFactory + template approvals.

`DeployWood` SHALL be skipped — WOOD is already live on the fork. CREATE3 makes the core addresses order-independent. With handoff skipped, the deployer retains ownership of beacon / factory / registry / sWOOD / ProtocolConfig / PriceRouter (needed for fork admin); on the real mainnet ceremony `SKIP_MULTISIG_HANDOFF` SHALL NOT be used and `OWNER_MULTISIG` MUST be a contract (Safe), not an EOA.

#### Scenario: Post-deploy validation reads
- **WHEN** the three scripts complete
- **THEN** the operator verifies `factory.beacon/priceRouter/protocolConfig`, `swood.wood == WOOD`, `swood.registry == registry`, `registry.reviewPeriod == 86400`, `registry.blockQuorumBps == 3000`, `strategyFactory.approvedTemplate(PORTFOLIO) == true`, and `governorImpl.MIN_VOTING_PERIOD() == 86400`

#### Scenario: Mainnet ceremony with EOA multisig refused
- **WHEN** `OWNER_MULTISIG` is an EOA and handoff is not skipped
- **THEN** the deploy reverts "OWNER_MULTISIG must be a contract (Safe), not an EOA"

### Requirement: Core wiring order inside deployCore
The canonical `DeploySherwood.deployCore` SHALL wire in this order: executor lib and vault impl; ProtocolConfig (plain Ownable, fee params seeded when non-zero); governor impl wrapped in a `GovernorBeacon` (per-vault governors are `BeaconProxy`s minted at `createSyndicate` — no singleton governor proxy is deployed); **sWOOD proxy before the registry proxy** (the registry's `initialize` takes the sWOOD address; the registry↔sWOOD cycle resolves via the set-once `StakedWood.setRegistry` call after the registry exists); factory proxy (address predicted by CREATE3 and asserted); then `TierRegistry` deployed owner-as-deployer and wired via the factory-only `setTierRegistry` BEFORE the multisig handoff. The `SYNDICATE_GOVERNOR` address-book slot SHALL be persisted as zero — governors are per-vault, resolved via `factory.governorOf(vault)`.

#### Scenario: Beacon validated non-empty
- **WHEN** post-deploy validation runs
- **THEN** `GovernorBeacon.implementation() != address(0)` and `beacon.owner` is the effective owner (multisig post-handoff, deployer when skipped)

#### Scenario: Two-step handoffs asserted as pending
- **WHEN** the multisig handoff runs (ProtocolConfig and TierRegistry are `Ownable2Step`)
- **THEN** validation asserts `pendingOwner == multisig` and the runbook requires the multisig to call `acceptOwnership()` — a deployer that forgot the acceptance step is caught at deploy time

### Requirement: Fork funding via Tenderly cheats only
Only two cheats exist on the vnet: `tenderly_setBalance` (native) and `tenderly_setStorageAt` (any slot); `tenderly_setErc20Balance` is NOT available. ERC-20 funding SHALL write the `_balances` mapping slot directly: `keccak256(abi.encode(holder, balancesSlot))` with WOOD at slot 0 (plain OZ ERC20) and USDG at slot 1 (slot 0 holds other proxy state). `cast rpc` params SHALL be passed as separate positional args, not one JSON array (the array form returns `-32602`). For an unlisted token, the balances slot SHALL be discovered by brute-forcing slots 0..40 (write a sentinel to `keccak(holder, S)`, read `balanceOf`), falling back to the OZ v5 ERC-7201 namespaced location. Time travel uses `evm_increaseTime` + `evm_mine`.

#### Scenario: Funding WOOD to a wallet
- **WHEN** the operator computes `KEY=$(cast index address <wallet> 0)` and writes it on the WOOD token via `tenderly_setStorageAt` over the admin RPC
- **THEN** `balanceOf(wallet)` returns the written amount

#### Scenario: Array-form RPC params rejected
- **WHEN** `cast rpc tenderly_setStorageAt '["<tok>","<slot>","<val>"]'` is issued
- **THEN** the RPC returns `-32602`; the positional form succeeds

### Requirement: Mainnet-faithful parameters are not accelerated
The fork deploy SHALL bake the real mainnet parameters and the operator SHALL NOT accelerate them for guardian sims (advance time with `evm_increaseTime` instead): `MIN_VOTING_PERIOD` 24h and `MIN_COOLDOWN_PERIOD` 1h (governor impl constructor immutables), `reviewPeriod` 24h and `blockQuorumBps` 30% (registry init), `MIN_COHORT_STAKE_AT_OPEN` 50,000 WOOD (registry constant), `minGuardianStake`/`minOwnerStake` 10,000 WOOD each, `coolDownPeriod` 7 days, `minSlashBps`/`maxSlashBps` 10%/100% (sWOOD init), protocol fee 1% / management fee 0.5%. (The 46630 testnet's 600s-floor governor upgrade is explicitly NOT applied to the fork.)

#### Scenario: Governance window traversal
- **WHEN** a proposal must pass the 24h vote + 24h review windows
- **THEN** the operator advances `evm_increaseTime 172800` + `evm_mine` rather than deploying shortened floors

### Requirement: Lifecycle validation with route and staleness discipline
A full one-fund lifecycle (owner stake → fund create → deposit → strategy propose → vote → execute → settle) SHALL be run through the CLI's first-class `robinhood-fork` network with an operator wallet separate from the deployer. Swap routes SHALL be quoted on the fork with the V4Quoter before proposing — never guessed (NVDA/TSLA have direct USDG v4 pools at fee 3000 / tickSpacing 60; the 5%-fee direct pools quote garbage and breach the 5% slippage floor). Because governance warps age the Chainlink push feeds past their 26h default staleness, proposals SHALL either pass a large `--max-price-ages` (up to the 2,592,000s = 30d bound) or refresh the feed's `updatedAt` via `setStorageAt` after each warp.

#### Scenario: Round-trip sanity result
- **WHEN** the validated lifecycle runs (50,000 USDG deposited, 40k deployed into NVDA/TSLA, settled with no market move)
- **THEN** settlement returns approximately the deposit minus round-trip fees (validated: 49,760.78 USDG, −0.48%)

#### Scenario: Stale feed after warp
- **WHEN** execute/settle runs after a 48h warp with default max price age
- **THEN** it trips `StalePrice`; passing `--max-price-ages 2592000` (or refreshing `updatedAt`) clears it

### Requirement: Guardian-network simulation preconditions
To make guardian blocking real (not the cold-start bypass), total staked guardian weight at review-open SHALL exceed `MIN_COHORT_STAKE_AT_OPEN` = 50,000 WOOD — e.g. ≥6 wallets staking 10,000 WOOD each. `agentId = 0` is acceptable (no agentRegistry on the fork). Guardians become active at `block.timestamp`, and checkpoints are read at `t−1`, so the operator SHALL advance time by ≥1s (`evm_increaseTime 1`) between staking and opening a review. Reviews snapshot cohort stake + `blockQuorumBps` at entry; 30% of cohort stake voting Block rejects the proposal, slashes approvers (WOOD burned), and attributes blockers for off-chain Merkl rewards. Vote-change is allowed until the final 10% of the window; approvers are capped at 100/proposal, blockers uncapped. Slash severity is the stake-weighted median of blockers' proposed `slashBps` clamped to sWOOD's `[minSlashBps, maxSlashBps]`; the own bond is the only slash leg (DPoS delegation removed/postponed 2026-07-26). `emergencySettleWithCalls` re-checks `requiredOwnerBond = max(minOwnerStake, TVL·ownerStakeTvlBps/1e4)` at call time (`ownerStakeTvlBps = 0` in V1 → flat 10k floor). The Slash Appeal Reserve is NOT auto-seeded by the mainnet deploy override — the operator SHALL seed it post-deploy (`approve` + `registry.fundSlashAppealReserve`).

#### Scenario: Cold-start floor cleared
- **WHEN** six guardians each stake 10,000 WOOD and time advances 1s before a review opens
- **THEN** cohort stake 60,000 > 50,000 makes blocking possible, and 30% of the snapshot voting Block rejects the proposal

#### Scenario: Appeal without a seeded reserve
- **WHEN** `refundSlash` is attempted before the Slash Appeal Reserve is funded
- **THEN** the refund cannot be paid — seeding the reserve is a required post-deploy step

### Requirement: Plan B deployment pre-flights and wiring
`DeployPlanB` (ExposureLedger + ProposerBondEscrow against an existing Plan A deployment) SHALL fail its pre-flights BEFORE anything is deployed, and SHALL wire in the order: deploy ledger (epoch length 28d, immutable) → deploy escrow → seed ledger params (`setWoodUsdPrice`, `setWoodTwapOracle`, `setAssetFeed`, `setGuardianRegistry`, `setCoveredTvlCapUsd`) → `registry.setExposureLedger` → `factory.setExposureLedger` / `setBondEscrow`. Checks:
- PRE-FLIGHT (pre-broadcast): `swood.maxSlashBps() == 10_000` — the ledger books liability at 100% of allocation, so a lower ceiling makes recovery a strict shortfall by construction; and `COVERED_TVL_CAP_USD18 != 0` — a zero cap is fail-closed and would brick all proposing.
- Drift guard: the deployed ledger's `challengeWindow` SHALL equal the script's expected 14d constant.
- POST-wiring: `swood.exposureLedger() != address(0)` — `claimUnstakeGuardian` fails OPEN when unset, so an unwired pointer silently lets guardians walk out from under pending challenges; and `ledger.quorumTierThreshold() == 0` — coverage enforcement runs at every tier (ADR 2026-07-27 decision 2; the paired `maxEnvelopeTier <= 1` ceiling was dropped 2026-07-31, so there is no ceiling to assert).
- `ASSET_FEED_MAX_DELAY` SHALL be sized against the governor's actual `votingPeriod + reviewPeriod + executionWindow` lifecycle (the approve quorum re-reads the feed at execute time), not a habitual `1 days`.
- The obsolete cooldown pre-flight (`coolDownPeriod >= epochLength + challengeWindow`) is REMOVED — unsatisfiable (cooldown caps at 30d) and superseded by the exact exit gate on `claimUnstakeGuardian`.
- PRE-FLIGHT 8 (POST-broadcast, design revision 2): `ledger.woodUsdPriceX8() != 0` AND the composed `ledger.woodPriceX8()` SHALL resolve to a non-zero price. These are two independent failures with different remedies. The first is the price CAP being unset, which under the cap-only model is a revert (`NoWoodPrice`) rather than "uncapped" — reading zero as "no ceiling" would make the likeliest misconfiguration the one state in which a ~$438k pool prices every guardian bond without bound. The second is a CAP configured with nothing priced beneath it, which a cap-only check misses entirely. `woodPriceX8()` SHALL be read by low-level probe rather than a typed call, because it now reverts instead of returning zero when unpriceable, and a bare revert would surface as an opaque script failure with no instruction attached.
- The env key is `WOOD_PRICE_CAP_X8`, RENAMED from `WOOD_PRICE_HAIRCUT_X8` because the number's meaning inverted: it is a ceiling on manipulation, never served as a price, and SHALL be seeded **ABOVE** market — 1.25–2× is the intended band, reviewed monthly. The old "≤ 30-day low" instruction is now exactly backwards: a cap below market binds permanently, pins every bond at the cap and makes the market source inert.
- `WOOD_TWAP_ORACLE` SHALL name a `WoodTwapOracle` that ALREADY HAS A COMPLETED AVERAGING WINDOW. The oracle needs at least `twapWindow` of keeper activity before `consult()` answers, so the ceremony ordering is: deploy the oracle → run the keeper → run Plan B. Pre-flight 8 enforces this rather than merely documenting it.

#### Scenario: Unset price cap refused post-broadcast
- **WHEN** `DeployPlanB` completes its broadcast with `woodUsdPriceX8` still zero
- **THEN** the run FAILS naming the cap, because a zero cap reverts every price read and nothing can be proposed, executed or challenged

#### Scenario: Cap set but nothing priced under it
- **GIVEN** `WOOD_PRICE_CAP_X8` is non-zero but no TWAP oracle is wired (and chain 4663 has no Chainlink WOOD/USD feed)
- **WHEN** the post-broadcast pre-flights run
- **THEN** the run FAILS on the composed price — proving the cap-only assert would have passed a dead deployment

#### Scenario: Oracle wired but not yet primed
- **GIVEN** the TWAP oracle is wired but has no completed averaging window
- **THEN** pre-flight 8 FAILS, directing the operator to run the keeper for at least `twapWindow` before re-running

#### Scenario: Wrong slash ceiling refused pre-deploy
- **WHEN** `DeployPlanB` runs against an sWOOD with `maxSlashBps < 10_000`
- **THEN** the script reverts its PRE-FLIGHT before deploying the ledger

#### Scenario: Unwired unstake gate refused post-wiring
- **WHEN** the broadcast completes but sWOOD's `exposureLedger` pointer is still zero
- **THEN** the script reverts, directing the operator to call `setExposureLedger(ledger)` by governance and re-run

### Requirement: DeployPlanB seats the strategy-duration ceiling
`DeployPlanB` SHALL seat `ProtocolConfig.maxStrategyDuration` inside the broadcast: to the documented default when `MAX_STRATEGY_DURATION` is unset in the environment, or to the operator-supplied value when set. A zero override SHALL be rejected before broadcast — an explicit "no ceiling" MUST NOT be expressible through this script. The post-broadcast assert SHALL confirm `maxStrategyDuration` is non-zero.

#### Scenario: Default run
- **WHEN** DeployPlanB runs without `MAX_STRATEGY_DURATION` set
- **THEN** `ProtocolConfig.maxStrategyDuration` is seated to the documented default inside the broadcast, and the post-broadcast assert confirms it is non-zero

#### Scenario: Operator override
- **WHEN** `MAX_STRATEGY_DURATION` is set in the environment
- **THEN** that value is seated instead; zero is REJECTED before broadcast

### Requirement: DeployPlanB asserts delegation is off
`DeployPlanB`'s post-broadcast pre-flights SHALL fail the run if `delegationEnabled` reads true on the target chain, naming the delegator-walkout hole: delegated stake is credited to a ~35-day coverage window while `requestUnstakeDelegation` checks only the delegator, and the unbonding pool is slashable for only `coolDownPeriod`.

#### Scenario: Delegation accidentally on
- **GIVEN** `delegationEnabled` reads true on the target chain
- **WHEN** the post-broadcast pre-flights run
- **THEN** the run FAILS with a message naming the delegator-walkout hole

#### Scenario: Preflight tests cover both invariants
- **THEN** `test/deploy/DeployPlanBPreflight.t.sol` covers: default duration seating lands; zero override rejected; delegation-on fails the named assert; delegation-off passes

### Requirement: Plan D deployment pre-flights and wiring order
`DeployPlanD` (ChallengeGame against an existing Plan B + Plan C deployment) SHALL run pre-flights before deploying anything, then wire the game's four roles in this order: `ledger.setCoverageFreezer(game)` → `tierRegistry.setAuthorizedDemoter(game)` → `swood.setAuthorizedSlasher(game)` → `game.setStakedWood(swood)` (the reciprocal pointer, owner-set rather than a constructor arg because the role is granted on sWOOD's side; the slasher grant and the reciprocal pointer can be wired in either order). Checks:
- PRE-FLIGHT 1: all three roles (`coverageFreezer`, `authorizedDemoter`, `authorizedSlasher`) MUST currently be UNSET — the setters overwrite silently, so re-running would quietly steal a role from a live holder. Refuse rather than clobber; rotations require clearing by governance first.
- PRE-FLIGHT 2: Plan C's wiring holds in BOTH directions — `escrow.authorizedFunder() == swood` AND `swood.compensationEscrow() == escrow` — or every settled challenge reverts at its last step.
- PRE-FLIGHT 3: the COMPOSED `ledger.woodPriceX8() != 0` (not the raw scalar) — a zero composed price means `file()` reverts `WoodPriceUnset` and nothing can be challenged. Read by low-level PROBE rather than a typed call: under design revision 2 that view reverts `NoWoodPrice` instead of returning zero when no source can price WOOD, and a typed call would let the revert propagate as an opaque script failure. Both shapes (reverts, or answers zero) fold into the same refusal, since to the game they are the same problem.
- Drift guard: `game.challengeWindow() == ledger.challengeWindow()`.
- Post-conditions: all four roles verified to land on THIS game, plus the game's `exposureLedger`/`tierRegistry` constructor pointers.

The broadcaster MUST already own the ledger, tier registry, and sWOOD. Manual follow-ups are load-bearing: the OFF-CHAIN bug-bounty program (on-chain a successful challenger only gets its bond back), `autoSlashDelay` review against real guardian response capability, and Ownable2Step handoff of game ownership.

#### Scenario: Role theft refused
- **WHEN** `DeployPlanD` runs against a chain where a previous ChallengeGame already holds `coverageFreezer`
- **THEN** the script reverts its PRE-FLIGHT before deploying a new game

#### Scenario: Composed-price check catches the right failure mode
- **WHEN** the raw `woodUsdPriceX8` scalar is set but the composed `woodPriceX8()` is zero (or vice versa)
- **THEN** the pre-flight follows the composed value — the figure `file()` actually divides by

### Requirement: TokenCourt deploy/wire split and its five pre-flights
The token court SHALL ship as two transactions: `DeployTokenCourt` (deploy + `setChallengeGame` + `setStakedWood` + start the Ownable2Step handoff to `PROTOCOL_OWNER`) and, separately, `WireTokenCourt` (`game.setCourt(court)`), so every pre-flight runs against the finished pair before the game's `court` slot is touched. The fail-safe if wiring refuses is benign: an unwired game times disputed challenges out in favour of the accused. `WireTokenCourt` SHALL check:
1. PRE-FLIGHT 1: `court.challengeGame() == CHALLENGE_GAME` and `court.stakedWood() == STAKED_WOOD`.
2. PRE-FLIGHT 2: `game.stakedWood() == STAKED_WOOD` — sWOOD identity must match on BOTH contracts, or the electorate that votes is not the cohort that gets slashed.
3. PRE-FLIGHT 3 (cross-contract window invariant): `game.autoSlashDelay() + court.voteWindow() + court.FINALIZE_BUFFER() <= game.disputeTimeout()`, or the referral window is negative and every disputed challenge free-wins for the accused. Both contracts enforce this against each other's live state on later reconfiguration, but the very FIRST wiring of a fresh pair has nothing to validate against — this script is that external check. Defaults: 7d + 5d + 1d = 13d ≤ 30d.
4. PRE-FLIGHT 4 (launch math): `court.participationFloorBps() < swood.ageFloorBps()` — turnout is AGED weight while the floor's base is RAW stake, so with all stake young a floor at or above the age-floor fraction is unclearable. Defaults: 1,000 < 2,500 (implying 40% of raw stake must vote at launch).
5. PRE-FLIGHT 5 (Plan D wiring intact): `ledger.coverageFreezer() == CHALLENGE_GAME`, `tiers.authorizedDemoter() == CHALLENGE_GAME`, `swood.authorizedSlasher() == CHALLENGE_GAME` — or a Guilty verdict dead-ends at `_settle`.

Manual follow-ups: an sWOOD upgrade touching `slashToEscrow`'s ABI and any ChallengeGame redeploy that calls it MUST ship as ONE atomic governance batch (a selector mismatch makes every `resolve()` revert with coverage frozen); monitor `AutoReferFailed` (referral is automatic but best-effort — permissionless `TokenCourt.refer` is the fallback); off-chain voter incentives are an operational commitment without which the participation floor may never clear.

#### Scenario: Negative referral window refused
- **WHEN** `autoSlashDelay + voteWindow + FINALIZE_BUFFER > disputeTimeout` on the pair being wired
- **THEN** `WireTokenCourt` reverts PRE-FLIGHT 3 before calling `setCourt`

#### Scenario: Broken Plan D wiring refused
- **WHEN** any of the three Plan D roles no longer points at the challenge game
- **THEN** `WireTokenCourt` reverts PRE-FLIGHT 5 — the court must not be granted ruling authority over a game whose verdicts cannot execute

### Requirement: Chain-specific factory identity configuration
On Robinhood Chain (no ENS/Durin registrar, no ERC-8004 identity registry) the factory SHALL be deployed with `address(0)` for both `ensRegistrar` and `agentRegistry` (identity + subname registration disabled), and validation SHALL assert both read back as zero. The PriceRouter SHALL deploy with zero adapters — PortfolioStrategy is Lane-B-only, and the router fails closed to Lane B until governance registers an adapter post-audit.

#### Scenario: Identity disabled on Robinhood
- **WHEN** post-deploy validation runs on 4663 or its fork
- **THEN** `factory.ensRegistrar() == address(0)` and `factory.agentRegistry() == address(0)`

#### Scenario: Zero-adapter router fails closed
- **WHEN** a price is requested before any adapter is registered
- **THEN** the router falls through to Lane B rather than serving an adapter price

### Requirement: Accepted oracle risks are stated in the deploy runbook
Two oracle exposures are accepted for v1, not open defects, and SHALL be documented in the operator's line of sight rather than only in source natspec: (1) Chainlink aggregators clamp at `minAnswer`/`maxAnswer` — a clamped price is anti-conservative, understating `coverageUsd` (asset side) and over-valuing guardian bonds via `woodPriceX8` (WOOD side), with `woodHaircutBps` a fixed discount rather than a clamp bound; and (2) Robinhood Chain 4663 publishes no sequencer-uptime feed, so the standard staleness-plus-grace-period gate (`src/libraries/ChainlinkReader.sol`'s `SequencerDown`/`GracePeriodNotOver`) cannot be built — `ExposureLedger` reads aggregators directly, and `ASSET_FEED_MAX_DELAY` SHALL be sized tightly enough that a plausible outage pushes reads past staleness while still covering the full vote + review + execute lifecycle.

The WOOD half of exposure (1) is now BOUNDED rather than merely disclosed: every market source, Chainlink included, is admitted only under `min(source, woodUsdPriceX8)`, so a clamped-high aggregator can over-value bonds by at most the cap. The asset half is unchanged — `coverageUsd` has no such ceiling.

#### Scenario: Reviewer reads the runbook
- **WHEN** a reviewer or deploy operator reads the runbook end to end
- **THEN** they encounter the aggregator clamping risk with its anti-conservative direction and the affected read paths (`coverageUsd`, `woodPriceX8`), the fact that the WOOD path is capped and the asset path is not, and the absence of a sequencer-uptime feed on Robinhood 4663 with why the usual staleness gate cannot exist, all stated as accepted-for-v1

### Requirement: The WOOD price is market-sourced and governance-capped
`ExposureLedger` SHALL resolve the WOOD price as `haircut(min(market, woodUsdPriceX8))`, floored at 1, where `market` is a Chainlink WOOD/USD feed when one is wired and fresh, otherwise the `WoodTwapOracle` TWAP. `woodUsdPriceX8` SHALL NEVER be served as a price. With no market source available the ledger SHALL revert `NoWoodPrice` rather than fall back to the governance scalar (design revision 2, 2026-08-02).

The runbook SHALL state the operational consequences:
- **Seed and maintain the cap ABOVE market.** It bounds upward manipulation and nothing else; a cap at `M×` market caps manipulation at `M×`. It does not need accuracy, because it is never the valuation — a monthly review is sufficient, since a drifted cap simply stops binding. It does need MAINTENANCE: it is the only thing bounding upward manipulation of a ~$438k pool, where moving spot 2× costs ~$91k.
- **Lowering the cap is the emergency brake** — safe direction, unbounded, immediate, subject to the ledger's one-move-per-day interval (see issue #89, which asks whether that interval should gate downward moves at all).
- **A keeper SHALL call `WoodTwapOracle.update()`**, permissionlessly and on a schedule shorter than `maxTwapAge`. A failing keeper is how the oracle goes stale, and a stale oracle with no Chainlink WOOD feed is `NoWoodPrice`.
- **`NoWoodPrice` is fail-safe, not a halt, and the asymmetry is deliberate.** `recordApproval` CATCHES it and books nothing, so approve votes still land and reviews never become block-only. `requireApproveQuorum` (execute), `proposerBondWood` (propose) and `ChallengeGame.file` all let it revert. `slashBpsFor` reads no price at all (PR #102), so convictions still compute through a total outage. Net effect: votes work, nothing new can be proposed, nothing can execute, live challenges resolve.
- **Monitoring SHALL poll `woodPriceDetail()`**, which returns `(price, fromFeed, capBinding)`. Alert on `capBinding == true` persisting beyond a short excursion: it means the cap has drifted BELOW market and is pinning every bond while the market source sits inert. Alert on `woodPriceX8()` reverting at all. There is no event for either state.

#### Scenario: Operator wires a Chainlink WOOD feed
- **WHEN** the operator wires `setWoodFeed(feed, maxDelay)`
- **THEN** the runbook states that the feed becomes the PREFERRED market source but is still capped by `woodUsdPriceX8`, that the TWAP oracle remains the source on all four degraded shapes (feed unset, non-positive answer, stale, reverting), and that unwiring the feed is safe only while the TWAP oracle is live

#### Scenario: Operator considers the cap a conservative price
- **WHEN** an operator seeds `woodUsdPriceX8` at or below market, as the retired "≤ 30-day low" instruction said to
- **THEN** the cap binds permanently, every bond is valued at the cap, and the market source can no longer track a crash — the runbook names this as the misconfiguration to avoid, not a conservative choice

#### Scenario: TWAP goes stale with no Chainlink WOOD feed
- **WHEN** the keeper stops and the newest snapshot ages past `maxTwapAge`
- **THEN** approve and block votes both continue to land, new proposals are refused at `propose`, tier-gated proposals cannot execute, and convictions on already-filed challenges still compute

### Requirement: The WOOD price carries two accepted overstatements, and `woodHaircutBps` is the control
Two exposures are ACCEPTED rather than eliminated (owner decision 2026-08-02). The runbook SHALL state both, together with the parameter that covers them.

**(a) The two legs are not contemporaneous.** `WoodTwapOracle` multiplies a near-real-time WOOD/ETH average by a single Chainlink ETH/USD answer that may be up to one heartbeat old — the live 4663 feed was measured **10.7 hours old while perfectly healthy**, so this is the normal case, not a degraded one. During an ETH drawdown inside that heartbeat the pair ratio rises while the stale, pre-drawdown ETH price is still the multiplier, so WOOD/USD reads high by roughly the size of the ETH move and every bond is over-valued until the feed ticks. **No attacker capital is required** — ordinary market movement against a slow feed, which makes it likelier than any manipulation scenario.

It is accepted because the remedy is worse. Requiring the ETH answer to be no older than `twapWindow` forces `twapWindow >= ~12h`, and a 12-hour averaging window means half a day of blindness to a WOOD crash — unbounded in magnitude and fixed in duration, traded against an overstatement that is bounded in magnitude. Tracking a drawdown without waiting on a human is the whole purpose of the oracle. `ethUsdMaxDelay` is therefore bounded ONLY by `MAX_ETH_USD_DELAY_LIMIT` (24h, itself sized to clear the measured heartbeat with margin) and is deliberately INDEPENDENT of `twapWindow`, so the window can be short.

**(b) Residual crash lag** of up to `twapWindow + maxTwapAge`, inherent to averaging and the price paid for manipulation resistance.

Both OVERSTATE bond value — the dangerous direction — and both are bounded by the same two controls: `woodUsdPriceX8` truncates anything above the cap, and `woodHaircutBps` pre-funds an allowance below it. **`woodHaircutBps` is therefore LOAD-BEARING.**

**The shipped value is 7,000 — a 30% allowance — and `DeployPlanB` SHALL seat it** inside its broadcast (constant `DEFAULT_WOOD_HAIRCUT_BPS`, overridable via `WOOD_HAIRCUT_BPS`). The ledger's own default is 10,000, which is no haircut and therefore no allowance at all, and its setter ACCEPTS 10,000 as a legal value — so nothing else in the stack refuses that configuration and it would ship silently. Pre-flight 9 refuses it. 5,000 (the ledger floor) was REJECTED as too costly to guardian return on equity, a recurring concern in review. Precisely: 7,000 values every source at 70%, so an overstatement of up to ~42.9% still leaves bonds valued at or below their true worth — the 30% sizing case with margin to spare.

**Lowering the haircut is the safe direction** (more allowance, bonds valued lower, quorums harder) and takes one owner transaction. But it is subject to the SAME once-per-day `MIN_PRICE_UPDATE_INTERVAL` as the cap, and `DeployPlanB`'s own seating call stamps that clock — so the haircut cannot be adjusted again for 24 hours after deploy, and **cannot be tightened in the middle of a crash**. That is the concrete argument for resolving **issue #89** (the brake's once-per-day gate) BEFORE launch rather than after: the gate applies to both of the controls this design leans on, and both are wanted precisely during the events that make them matter.

Finding 5's `twapWindow <= maxTwapAge` invariant is unaffected and remains enforced — a different problem (structural unavailability) with a different fix.

#### Scenario: Operator sizes the haircut
- **WHEN** the operator seats `woodHaircutBps` before launch
- **THEN** the runbook states that the value is an allowance against the ETH-staleness overstatement and the crash lag, that the shipped value is 7,000 (a 30% allowance), that 10,000 leaves none at all and is refused by pre-flight 9, and that 5,000 was rejected on guardian-ROE grounds

#### Scenario: Deploy would leave the haircut at the ledger default
- **WHEN** `DeployPlanB` would complete with `woodHaircutBps == 10_000`
- **THEN** pre-flight 9 FAILS, naming what the allowance is FOR rather than only that the value is out of range

#### Scenario: Haircut needs tightening during a crash
- **GIVEN** the haircut was seated by the deploy less than a day earlier
- **THEN** `setWoodHaircutBps` reverts on `MIN_PRICE_UPDATE_INTERVAL` — recorded as a live limitation and as the reason issue #89 is a launch-blocking concern rather than a refinement

#### Scenario: ETH drawdown inside the feed heartbeat
- **GIVEN** ETH falls sharply while the ETH/USD answer is several hours old
- **THEN** WOOD/USD reads high by roughly the ETH move until the feed ticks, bonds are over-valued for that period, and the exposure is bounded above by the cap and below by the haircut — an accepted risk, documented, not a defect to file

#### Scenario: Short averaging window with a slow USD feed
- **WHEN** the operator configures `twapWindow = 1 hour` alongside `ethUsdMaxDelay = 24 hours`
- **THEN** the configuration is ACCEPTED — the two are independent by design, and coupling them would force a ~12-hour window and surrender the crash tracking the oracle exists to provide
