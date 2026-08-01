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
`DeployPlanB` (ExposureLedger + ProposerBondEscrow against an existing Plan A deployment) SHALL fail its pre-flights BEFORE anything is deployed, and SHALL wire in the order: deploy ledger (epoch length 28d, immutable) → deploy escrow → seed ledger params (`setWoodUsdPrice`, `setAssetFeed`, `setGuardianRegistry`, `setCoveredTvlCapUsd`) → `registry.setExposureLedger` → `factory.setExposureLedger` / `setBondEscrow`. Checks:
- PRE-FLIGHT (pre-broadcast): `swood.maxSlashBps() == 10_000` — the ledger books liability at 100% of allocation, so a lower ceiling makes recovery a strict shortfall by construction; and `COVERED_TVL_CAP_USD18 != 0` — a zero cap is fail-closed and would brick all proposing.
- Drift guard: the deployed ledger's `challengeWindow` SHALL equal the script's expected 14d constant.
- POST-wiring: `swood.exposureLedger() != address(0)` — `claimUnstakeGuardian` fails OPEN when unset, so an unwired pointer silently lets guardians walk out from under pending challenges; and `ledger.quorumTierThreshold() == 0` — coverage enforcement runs at every tier (ADR 2026-07-27 decision 2; the paired `maxEnvelopeTier <= 1` ceiling was dropped 2026-07-31, so there is no ceiling to assert).
- `ASSET_FEED_MAX_DELAY` SHALL be sized against the governor's actual `votingPeriod + reviewPeriod + executionWindow` lifecycle (the approve quorum re-reads the feed at execute time), not a habitual `1 days`.
- The obsolete cooldown pre-flight (`coolDownPeriod >= epochLength + challengeWindow`) is REMOVED — unsatisfiable (cooldown caps at 30d) and superseded by the exact exit gate on `claimUnstakeGuardian`.

#### Scenario: Wrong slash ceiling refused pre-deploy
- **WHEN** `DeployPlanB` runs against an sWOOD with `maxSlashBps < 10_000`
- **THEN** the script reverts its PRE-FLIGHT before deploying the ledger

#### Scenario: Unwired unstake gate refused post-wiring
- **WHEN** the broadcast completes but sWOOD's `exposureLedger` pointer is still zero
- **THEN** the script reverts, directing the operator to call `setExposureLedger(ledger)` by governance and re-run

### Requirement: Plan D deployment pre-flights and wiring order
`DeployPlanD` (ChallengeGame against an existing Plan B + Plan C deployment) SHALL run pre-flights before deploying anything, then wire the game's four roles in this order: `ledger.setCoverageFreezer(game)` → `tierRegistry.setAuthorizedDemoter(game)` → `swood.setAuthorizedSlasher(game)` → `game.setStakedWood(swood)` (the reciprocal pointer, owner-set rather than a constructor arg because the role is granted on sWOOD's side; the slasher grant and the reciprocal pointer can be wired in either order). Checks:
- PRE-FLIGHT 1: all three roles (`coverageFreezer`, `authorizedDemoter`, `authorizedSlasher`) MUST currently be UNSET — the setters overwrite silently, so re-running would quietly steal a role from a live holder. Refuse rather than clobber; rotations require clearing by governance first.
- PRE-FLIGHT 2: Plan C's wiring holds in BOTH directions — `escrow.authorizedFunder() == swood` AND `swood.compensationEscrow() == escrow` — or every settled challenge reverts at its last step.
- PRE-FLIGHT 3: the COMPOSED `ledger.woodPriceX8() != 0` (not the raw scalar) — a zero composed price means `file()` reverts `WoodPriceUnset` and nothing can be challenged.
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
