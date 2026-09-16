# Deployment Specification

## Purpose

Requirements on the Sherwood deployment process: the mainnet-faithful Robinhood fork environment (Tenderly vnet, chain 9994663), the core deploy ceremony and its wiring order, the guardian-econ layered deployments (Plan B ledger, Plan D challenge game, TokenCourt) with their pre-flight checks, and chain-specific constraints. Scenarios are the verification steps an operator runs to prove each requirement held.
## Requirements
### Requirement: Chain targeting and fork identity
Posture SHALL be derived from `block.chainid` alone: 4663 is Mainnet posture; any other chain carrying a committed `chains/{chainid}.json` with a `DEPLOYER` key is Fork posture; a chain with no such book is refused before anything is broadcast. `ROBINHOOD_FORK_CHAIN_ID` is RETIRED — `chains/9994663.json` is committed, so the fork chain id is a fact about the repo, not an operator input. The fork is mainnet-faithful: USDG stablecoin, official Uniswap v3+v4, Chainlink push feeds, real tokenized-stock liquidity, and the live WOOD token (`0xf8bc08092c06db6148114dcf82af881f1085f92b`, 18-dec, 1B supply, ownership renounced).

#### Scenario: Wrong chain refused
- **WHEN** `DeployAll` runs against a chain with no committed address book, or with a book that carries no `DEPLOYER`
- **THEN** the script reverts "wrong chain: no chains/<chainid>.json for this chain" (or "wrong chain: chains/<chainid>.json carries no DEPLOYER") before broadcasting anything

#### Scenario: Fork writes its own address book
- **WHEN** the ceremony runs on chain 9994663
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
Tenderly vnets expire. When the RPC 404s, the operator SHALL mint a new vnet against the same fork target and re-run the deploy ceremony and funding: the chain id (9994663) and all external addresses (USDG, WETH, Uniswap SwapRouter02/QuoterV2, v4 PoolManager/V4Quoter, stock tokens, Chainlink feeds) stay the same; only the RPC URL and the Sherwood core addresses change. Externals are pre-committed in `chains/9994663.json` and SHALL survive re-deploys — `DeployAll._persist` patches only the keys the ceremony mints, in place. The Tenderly admin RPC (cheats) is a secret held as `TENDERLY_ROBINHOOD_RPC_URL` in `contracts/.env` and SHALL never be committed.

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
The ceremony SHALL be ONE script, `script/robinhood-mainnet/DeployAll.s.sol:DeployAll`, whose phases run in a fixed order inside ONE broadcast: Create3Factory bootstrap → core (`deployCore` + `_seatOwnerWrites`, including the TierRegistry launch set) → UniswapSwapAdapter and the Portfolio / MorphoSupply / ConcentratedLiquidity templates → StrategyFactory → the WOOD price source → Plan B → Plan D → TokenCourt → handoff.

The Fork posture completes in ONE run. The Mainnet posture completes in TWO runs separated by the WOOD feed's warm-up: the first run mints `WoodPoolFeed`, returns `Checkpoint.AwaitingWoodFeed` and performs NO handoff; the operator then calls `WoodPoolFeed.update()` on a keeper until `latestRoundData()` answers (at least one `window`, 24h minimum); the second run finds the feed answering, deploys the coverage stack and hands off. Between the two runs the deployer key still owns every contract — that window is the price of the warm-up and SHALL be stated in the runbook, not discovered.

The broadcaster SHALL equal the book's `DEPLOYER`, and the script reverts "broadcaster != DEPLOYER in the address book" otherwise. There is no skip flag: WHO ends up owning the protocol is a property of the posture. On Mainnet `OWNER_MULTISIG` is REQUIRED from the book and MUST be a contract (Safe), not an EOA. On Fork the owner is the deployer itself, so the handoff still runs and is a no-op; a Fork book MAY carry `OWNER_MULTISIG` only when it equals `DEPLOYER`, and anything else is REFUSED ("Fork posture hands off to the deployer: OWNER_MULTISIG must be absent or equal DEPLOYER") so a mainnet Safe copied into a fork book cannot become the target. `_handoffAll` SHALL refuse an unset target, which would be unrecoverable.

`DeployWood` SHALL be skipped — WOOD is already live on 4663 and on the fork, and `DeployWood` now refuses chain 4663 outright. Every protocol contract is minted through CREATE3, so the address table is order-independent.

Addresses flow IN MEMORY between phases (the `Stack` struct); no phase reads another phase's address out of a file, and no ceremony script reads the process environment. Persistence to `chains/{chainId}.json` is nonetheless REQUIRED — `cli`, `sdk`, the guardian daemon and the app all sync from it — and happens ONCE at the end of `run()`, after validation. The script never CREATES a book: a chain with no book is already refused at pre-flight.

#### Scenario: TierRegistry reaches the address book
- **WHEN** the ceremony completes
- **THEN** `chains/{chainId}.json` carries `TIER_REGISTRY`, and it equals `factory.tierRegistry()`

#### Scenario: Guardian-econ phases hand each other their addresses
- **WHEN** `deployAll` returns `Checkpoint.Complete`
- **THEN** `chains/{chainId}.json` carries `EXPOSURE_LEDGER`, `PROPOSER_BOND_ESCROW`, `CHALLENGE_GAME` and `TOKEN_COURT`, written by `_persist` from the in-memory `Stack` rather than recovered from a broadcast log

#### Scenario: Mainnet stops at the feed gate
- **WHEN** the first Mainnet run reaches the WOOD price source and `latestRoundData()` does not yet answer
- **THEN** `deployAll` returns `Checkpoint.AwaitingWoodFeed`, no Plan B contract is minted and no ownership is transferred

### Requirement: The Robinhood ceremony seats every owner-gated write before handoff
`DeployRobinhoodMainnet` is an ABSTRACT phase mixin and `DeployAll` owns `run()`, so every write the canonical run makes between `deployCore` and the multisig handoff SHALL be restated in it. Those writes SHALL be collected in ONE internal method (`_seatOwnerWrites`) rather than scattered inline, so the set can be asserted as a set: each is an `onlyOwner` call on a contract the handoff then transfers, so each has exactly one window in which it is cheap and an eternity afterwards in which it is a multisig chore.

The set is: `setProtocolFeeRecipient`, `setGuardiansFeeRecipient`, and **the TierRegistry launch set** (`_seedTierRegistry`). The two fee recipients are seated ONLY when still zero, so a resumed run never re-points a recipient the Safe has already moved. The launch set was MISSING for the entire life of the script. `deployCore` mints the TierRegistry empty and wires it into the factory; the attestations are separate `onlyOwner` writes. `isCounterpartyAllowed` GATES CLONE-INIT, so an empty registry makes every ConcentratedLiquidity clone revert `CounterpartyNotAllowed` and makes `DeployConcentratedLiquidityStrategy` refuse to run at all.

#### Scenario: Launch set lands before the handoff
- **WHEN** the Robinhood ceremony completes
- **THEN** the TierRegistry attests `UNISWAP_V3_FACTORY`, `UNISWAP_V3_POSITION_MANAGER` and `MORPHO_BLUE` as counterparties, and `MORPHO_BLUE` on the adapter axis as well

The launch set is STRICT. Every symbol in `RobinhoodParams.launchSetSymbols()` requires its `CHAINLINK_<SYM>_USD_FEED` key in the address book, and a missing one REVERTS ("launch set: <KEY> is zero in the address book") rather than narrowing the attested set in silence. The paired `<SYM>` token key drives `setPriceSourceForToken`; on 4663 today USDC, BTC and LINK have a feed but no token entry, so those three are allowlisted as counterparties with NO token pairing and the run says so. Closing that gap is a book change (add the three token addresses) or a list change (drop the three symbols), not a code change.

#### Scenario: Seeding after the handoff is refused
- **GIVEN** a refactor that moves the seed call after the Safe has accepted ownership
- **THEN** `_seedTierRegistry` REVERTS ("PRE-FLIGHT: TIER_REGISTRY owner is not the deployer - seed the launch set before the Safe accepts") rather than skipping, which `test/deploy/DeployTierRegistrySeed.t.sol::test_seed_revertsOnceOwnershipHasMoved` pins. Inside the one script the seeding always precedes the handoff, so the refusal is a guard against a re-ordering, not an operational state

The ceremony SHALL seat BOTH `protocolFeeRecipient` AND `guardiansFeeRecipient` on `ProtocolConfig` inside the broadcast, and validation SHALL assert both. `ProtocolConfig`'s constructor seeds only the splits, and a zero recipient does NOT strand its leg — the governor zeroes that slice and hands it to the agent as remainder, in both `_chargeManagementFee` and `_chargePerformanceFee`. An unseated recipient is therefore a SILENT RE-ROUTING to the proposer, not a missing payment. The guardian leg is the load-bearing one: `MANAGEMENT_FEE_BPS = 200` is sized so 20% of management and 25% of performance fund the guardian pool, so leaving it unset charges depositors at a rate justified by a pool that receives nothing.

Both are seeded to the DEPLOYER as a placeholder, never as the destination. The runbook SHALL direct the multisig to call `setProtocolFeeRecipient` and `setGuardiansFeeRecipient` after `acceptOwnership()`; until it does, both fee legs accrue to a single EOA.

#### Scenario: Unseated guardian fee recipient refused
- **WHEN** the core ceremony completes with `guardiansFeeRecipient` still zero
- **THEN** validation FAILS naming that leg, because the guardian budget would otherwise pay the proposer with nothing on-chain to notice

#### Scenario: Post-deploy validation reads
- **WHEN** `deployAll` returns `Checkpoint.Complete`
- **THEN** the operator verifies `factory.beacon/protocolConfig`, `swood.wood == WOOD`, `swood.registry == registry`, `registry.reviewPeriod == 86400`, `registry.blockQuorumBps == 3000`, `strategyFactory.approvedTemplate(PORTFOLIO) == true`, and `governorImpl.MIN_VOTING_PERIOD() == 86400`

#### Scenario: Mainnet ceremony with EOA multisig refused
- **WHEN** `OWNER_MULTISIG` is an EOA on Mainnet posture
- **THEN** the deploy reverts "OWNER_MULTISIG must be a contract (Safe), not an EOA"

### Requirement: The strategy template allowlist names only live templates

`StrategyFactory`'s approval map starts empty and nothing else populates it, so a template the ceremony does not approve can never be cloned by a proposal. The StrategyFactory phase SHALL approve EXACTLY the three templates carried on the ceremony's `Stack` and SHALL assert all three read back approved. There is no skip path and no `approved > 0` threshold: a zero template address refuses the run ("zero template"). `DeployStrategyFactory._templateKeys()` names the three address-book keys `_persist` writes, and is pinned as an exact set.

The list SHALL name `PORTFOLIO_TEMPLATE`, `MORPHO_SUPPLY_TEMPLATE` and `CONCENTRATED_LIQUIDITY_TEMPLATE`, and nothing else — every key on it has a live contract in `src/strategies/` and a script that deploys it. `MOONWELL_SUPPLY_TEMPLATE`, `AERODROME_LP_TEMPLATE`, `WSTETH_MOONWELL_TEMPLATE` and `MAMO_YIELD_TEMPLATE` were REMOVED (deprecated, 2026-08-04): none has a contract remaining in `src/strategies/`, they resolve only in the legacy Base books (`chains/8453.json`, `chains/84532.json`), and removal affects only a NEW `StrategyFactory` — already-deployed factories keep the approvals they were given.

`MorphoSupplyStrategy` requires NO Morpho address and NO market params at deploy time. It is an ERC-1167 template: the Morpho singleton, the `MarketParams` tuple and the supply amount all arrive per clone via `_initialize(bytes)`, so they are proposal inputs. The template is deliberately left uninitialized, which is the correct resting state for a clone source.

#### Scenario: Morpho template reaches the allowlist
- **WHEN** the ceremony completes
- **THEN** `chains/{chainId}.json` carries `MORPHO_SUPPLY_TEMPLATE`, `_templateKeys()` names it, and `StrategyFactory.templateApproved` is true for it

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
- **WHEN** the address book's `TIER_REGISTRY` holds no code, or answers `isCounterpartyAllowed` with anything other than a 32-byte word
- **THEN** the script reverts rather than treating the silence as a grant

### Requirement: Each CL pool's volatile leg is counterparty-allowlisted before its proposal

Pool provenance establishes where a pool came from; it says nothing about what the pool TRADES. A proposer can deploy a worthless ERC-20, create a genuine `(vaultAsset, junk)` pool through the real factory, initialise it at a price of their choosing, and pass every provenance check on the merits — after which `_rebalanceToTarget` buys that token with vault asset, priced by the only venue that quotes the pair.

`ConcentratedLiquidityStrategy._initialize` therefore binds the pool's non-asset token (`otherToken`) through `isCounterpartyAllowed` alongside `swapAdapter`, `positionManager`, `morpho`, `collateralToken` and `uniswapFactory`, and re-checks it at `execute()` and `rerange()`.

This is a PER-PROPOSAL obligation, not a ceremony step: the volatile leg is chosen per clone, so no deploy script can assert it. The registry owner SHALL call `setCounterpartyAllowed(<volatile leg>, true)` for each token a CL proposal is expected to trade, before that proposal is executed. Exits are deliberately NOT gated on it — `settle`, `sweep` and `releaseUnconvertible` stay open under the existing capital-hostage rule, so a demotion cannot strand the funds it is meant to protect.

#### Scenario: Proposal naming an unvouched volatile leg
- **WHEN** a CL proposal names a pool whose non-asset token is not counterparty-allowlisted
- **THEN** clone-init reverts `CounterpartyNotAllowed(otherToken, registry)`, failing the proposal rather than the batch

#### Scenario: Volatile leg demoted after init
- **WHEN** the leg is demoted between clone-init and `execute()`, or before a permissionless `rerange()`
- **THEN** both entry paths revert, while `settle()` still completes

### Requirement: Core wiring order inside deployCore
The canonical `DeploySherwood.deployCore` SHALL wire in this order: executor lib and vault impl; ProtocolConfig (plain Ownable, fee params seeded when non-zero); governor impl wrapped in a `GovernorBeacon` (per-vault governors are `BeaconProxy`s minted at `createSyndicate` — no singleton governor proxy is deployed); **sWOOD proxy before the registry proxy** (the registry's `initialize` takes the sWOOD address; the registry↔sWOOD cycle resolves via the set-once `StakedWood.setRegistry` call after the registry exists); factory proxy (address predicted by CREATE3 and asserted); then `TierRegistry` deployed owner-as-deployer and wired via the factory-only `setTierRegistry` BEFORE the multisig handoff. The `SYNDICATE_GOVERNOR` address-book slot SHALL be persisted as zero — governors are per-vault, resolved via `factory.governorOf(vault)`.

`ProtocolConfig`, the `GovernorBeacon`, `TierRegistry` and every other protocol contract are minted through CREATE3 under the `DeploySalts` namespace `sherwood.robinhood.v1.*`. The `Create3Factory` itself is minted through the canonical CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` at salt `sherwood.robinhood.v1.create3-factory` with a PINNED initcode hash, so every protocol address is a function of `(DEPLOYER, salt)` ONLY. An edit to `script/utils/Create3.sol` or `Create3Factory.sol` — comments included — moves that hash and with it the whole address table, because solc's CBOR metadata hashes the source and `foundry.toml` pins no `bytecode_hash`.

Validation SHALL therefore read every protocol key back as `chains/{chainId}.json value == Create3.addressOf(CREATE3_FACTORY, salt)`; `script/verify-robinhood.sh <chainId>` is that check, re-deriving the table from the book's `CREATE3_FACTORY` rather than trusting the recorded values.

The handoff SHALL transfer, all inside the Mainnet run: one-step — `GovernorBeacon`, `SyndicateFactory`, `GuardianRegistry`, `StakedWood`, `StrategyFactory`; two-step (`Ownable2Step`, so the Safe owes `acceptOwnership()`) — `ProtocolConfig`, `TierRegistry`, `ExposureLedger`, `ChallengeGame` and, on this branch, `TokenCourt`. Each leg is skipped when it is already done, so a resumed run is a no-op rather than a revert.

#### Scenario: Beacon validated non-empty
- **WHEN** post-deploy validation runs
- **THEN** `GovernorBeacon.implementation() != address(0)` and `beacon.owner` is the effective owner (multisig post-handoff, deployer when skipped)

#### Scenario: Two-step handoffs asserted as pending
- **WHEN** the multisig handoff runs (ProtocolConfig and TierRegistry are `Ownable2Step`)
- **THEN** validation asserts `pendingOwner == multisig` and the runbook requires the multisig to call `acceptOwnership()` — a deployer that forgot the acceptance step is caught at deploy time

### Requirement: Fork funding via Tenderly cheats only
Three cheats are available: `tenderly_setBalance` (native), `tenderly_setErc20Balance`, and `tenderly_setStorageAt` (any slot). Time travel uses `evm_increaseTime` + `evm_mine`, and `evm_snapshot` / `evm_revert` are available for baseline resets.

**`tenderly_setErc20Balance` IS available and is the preferred ERC-20 path.** Verified 2026-08-20 on the `a3fb16` vnet against both WOOD (a plain OZ ERC20) and USDG (a proxy) — the balance lands and `balanceOf` reads it back. This spec previously asserted the method did NOT exist, which was measured on the older `dbe358` vnet; the claim did not survive re-measurement and SHALL NOT be restored without one. It matters beyond convenience: `cli/src/e2e` funds every scenario through that method, so "unavailable" implied the e2e harness could never run against the fork.

The direct-storage route remains the DOCUMENTED FALLBACK for a vnet or token where the cheat does not work: write the `_balances` mapping slot as `keccak256(abi.encode(holder, balancesSlot))`, with WOOD at slot 0 and USDG at slot 1 (slot 0 holds other proxy state). `cast rpc` params SHALL be passed as separate positional args, not one JSON array (the array form returns `-32602`). For an unlisted token, the balances slot SHALL be discovered by brute-forcing slots 0..40 (write a sentinel to `keccak(holder, S)`, read `balanceOf`), falling back to the OZ v5 ERC-7201 namespaced location.

#### Scenario: Funding an ERC-20 to a wallet
- **WHEN** the operator calls `tenderly_setErc20Balance` with the token, holder and amount over the admin RPC
- **THEN** `balanceOf(wallet)` returns the written amount, for both plain and proxied tokens

#### Scenario: Funding WOOD by direct storage write
- **GIVEN** a vnet or token where the ERC-20 cheat does not take
- **WHEN** the operator computes `KEY=$(cast index address <wallet> 0)` and writes it on the WOOD token via `tenderly_setStorageAt`
- **THEN** `balanceOf(wallet)` returns the written amount

#### Scenario: Array-form RPC params rejected
- **WHEN** `cast rpc tenderly_setStorageAt '["<tok>","<slot>","<val>"]'` is issued
- **THEN** the RPC returns `-32602`; the positional form succeeds

### Requirement: Mainnet-faithful parameters are not accelerated
The fork deploy SHALL bake the real mainnet parameters and the operator SHALL NOT accelerate them for guardian sims (advance time with `evm_increaseTime` instead): `MIN_VOTING_PERIOD` 24h and `MIN_COOLDOWN_PERIOD` 1h (governor impl constructor immutables), `reviewPeriod` 24h and `blockQuorumBps` 30% (registry init), `MIN_COHORT_STAKE_AT_OPEN` 50,000 WOOD (registry constant), `minGuardianStake`/`minOwnerStake` 10,000 WOOD each, `coolDownPeriod` 7 days, `minSlashBps`/`maxSlashBps` 10%/100% (sWOOD init), and the 200 bps management fee stamped per vault. Every one of these is a committed constant in `script/robinhood-mainnet/RobinhoodParams.sol` — the same values on Mainnet and Fork posture, with no runtime override. (The 46630 testnet's 600s-floor governor upgrade is explicitly NOT applied to the fork.)

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
To make guardian blocking real (not the cold-start bypass), total staked guardian weight at review-open SHALL exceed `MIN_COHORT_STAKE_AT_OPEN` = 50,000 WOOD — e.g. ≥6 wallets staking 10,000 WOOD each. `agentId = 0` is acceptable (identity gating is off at v1). Guardians become active at `block.timestamp`, and checkpoints are read at `t−1`, so the operator SHALL advance time by ≥1s (`evm_increaseTime 1`) between staking and opening a review.

Clearing the cohort floor is necessary but NOT sufficient, because the two sides of the block-quorum comparison are measured differently: `cohortTooSmall` and the quorum denominator read `getPastTotalVotes`, which is RAW staked WOOD ("totals stay raw"), while a blocker's contribution reads `getPastVotes`, which applies `_ageFactorBps` on top. Fresh stake therefore counts in full against the bar it must clear and at only `ageFloorBps` (25%) toward clearing it. A cohort whose stake is all fresh cannot reach a 30% block quorum even at 100% participation — 0.25 × 60,000 = 15,000 against the 18,000 required. This asymmetry is deliberate: it denies an attacker a veto bought with stake parked seconds before the review. The operator SHALL therefore age the cohort before opening a review that is meant to be blocked, advancing time by at least `maturationPeriod × (blockQuorumBps − ageFloorBps) / (10 000 − ageFloorBps)` — 2 days at the fork's defaults (30 d, 30%, 25%) — and proportionally more when participation is partial.

Reviews snapshot cohort stake + `blockQuorumBps` at entry; 30% of cohort stake voting Block rejects the proposal, slashes approvers (WOOD burned), and attributes blockers for off-chain Merkl rewards. Vote-change is allowed until the final 10% of the window; approvers are capped at 100/proposal, blockers uncapped. Slash severity is NOT voted: `voteOnProposal(address,uint256,GuardianVoteType)` carries no severity argument, and `_severityBps(Review storage)` derives it deterministically from the review — a quadratic ramp from `minSlashBps` to `maxSlashBps` that saturates at a 66.67% block supermajority, with the bounds snapshotted at `openReview` (stored plus one, so a genuine snapshot can never read as the unset sentinel) to deny an owner any mid-review re-rating. The own bond is the only slash leg (DPoS delegation removed/postponed 2026-07-26). `emergencySettleWithCalls` re-checks `requiredOwnerBond = max(minOwnerStake, MIN_OWNER_BOND_FLOOR = 1,000 WOOD)` at call time (TVL scaling is not implemented in V1 → flat 10k floor at the deployed `minOwnerStake`), and additionally requires the posted bond to be strictly positive. The Slash Appeal Reserve is NOT auto-seeded by the mainnet deploy override — the operator SHALL seed it post-deploy (`approve` + `registry.fundSlashAppealReserve`).

#### Scenario: Cold-start floor cleared
- **WHEN** six guardians each stake 10,000 WOOD and time advances 1s before a review opens
- **THEN** cohort stake 60,000 > 50,000 clears `cohortTooSmall`, so the review is votable rather than auto-cleared

#### Scenario: Fresh cohort cannot reach the block quorum
- **WHEN** all six guardians vote Block on a review opened 1s after staking
- **THEN** their combined age-weighted weight is 15,000 against an 18,000 bar and the proposal is NOT rejected — the sim MUST advance time ≥2 days after staking for a block to be achievable

#### Scenario: Aged cohort blocks
- **WHEN** the operator advances `evm_increaseTime 172800` after staking and then opens the review
- **THEN** `_ageFactorBps` has reached 30%, and 30% of the snapshot voting Block rejects the proposal and slashes approvers

#### Scenario: Appeal without a seeded reserve
- **WHEN** `refundSlash` is attempted before the Slash Appeal Reserve is funded
- **THEN** the refund cannot be paid — seeding the reserve is a required post-deploy step

### Requirement: Plan B deployment pre-flights and wiring
The Plan B phase (ExposureLedger + ProposerBondEscrow) SHALL fail its pre-flights BEFORE anything is minted, and SHALL wire in the order: deploy ledger (epoch length 28d, immutable) → deploy escrow → seed ledger params (`setWoodUsdPrice`, `setWoodFeed`, `setAssetFeed`, `setGuardianRegistry`, `setCoveredTvlCapUsd`, `setWoodHaircutBps`) → `registry.setExposureLedger` → `factory.setExposureLedger` / `setBondEscrow`. Its numeric inputs are `RobinhoodParams` constants — `EPOCH_LENGTH`, `EXPECTED_CHALLENGE_WINDOW`, `WOOD_HAIRCUT_BPS`, `MAX_STRATEGY_DURATION`, `ASSET_FEED_MAX_DELAY`, `COVERED_TVL_CAP_USD18`, `WOOD_PRICE_CAP_X8` — committed and reviewed in the PR, never read from the environment. Checks:
- PRE-FLIGHT (pre-broadcast): `swood.maxSlashBps() == 10_000` — the ledger books liability at 100% of allocation, so a lower ceiling makes recovery a strict shortfall by construction; and `COVERED_TVL_CAP_USD18 != 0` — a zero cap is fail-closed and would brick all proposing.
- Drift guard: the deployed ledger's `challengeWindow` SHALL equal the expected 14d constant.
- POST-wiring: `swood.exposureLedger() != address(0)` — `claimUnstakeGuardian` fails OPEN when unset, so an unwired pointer silently lets guardians walk out from under pending challenges.
- WIRING refusal: each pointer slot this phase writes (`StakedWood.exposureLedger`, `GuardianRegistry.exposureLedger`, `SyndicateFactory.exposureLedger`, `SyndicateFactory.bondEscrow`, `ExposureLedger.guardianRegistry`) SHALL be free or already hold the address this run will mint. A slot naming a FOREIGN address is refused — the ceremony never repoints a live slot — and because CREATE3 makes the addresses knowable before the mint, the refusal lands before anything is deployed.
- `ASSET_FEED_MAX_DELAY` SHALL be sized above the aggregator's publication heartbeat (24h on 4663), because it bounds that aggregator's own `updatedAt` age on every `coverageUsd` read; a bound at or below the heartbeat makes every covered proposal revert `StalePrice`.
- The obsolete cooldown pre-flight (`coolDownPeriod >= epochLength + challengeWindow`) is REMOVED — unsatisfiable (cooldown caps at 30d) and superseded by the exact exit gate on `claimUnstakeGuardian`.
- PRE-FLIGHT 8 (STAGE GATE): the WOOD feed SHALL answer `latestRoundData()` with a positive price BEFORE any Plan B contract is minted. On Mainnet a feed that does not yet answer is not a failure but a CHECKPOINT: `deployAll` returns `Checkpoint.AwaitingWoodFeed` and the operator re-runs after the keeper has primed it. Post-broadcast the phase additionally requires `ledger.woodUsdPriceX8() != 0` AND the composed `ledger.woodPriceX8()` to resolve non-zero. These are two independent failures with different remedies. The first is the price CAP being unset, which under the cap-only model is a revert (`NoWoodPrice`) rather than "uncapped" — reading zero as "no ceiling" would make the likeliest misconfiguration the one state in which a ~$438k pool prices every guardian bond without bound. The second is a CAP configured with nothing priced beneath it, which a cap-only check misses entirely. `woodPriceX8()` SHALL be read by low-level probe rather than a typed call, because it reverts instead of returning zero when unpriceable, and a bare revert would surface as an opaque script failure with no instruction attached.
- The cap constant is `WOOD_PRICE_CAP_X8`, RENAMED from `WOOD_PRICE_HAIRCUT_X8` because the number's meaning inverted: it is a ceiling on manipulation, never served as a price, and SHALL be seeded **ABOVE** market. The ceremony BOUNDS it at deploy time to `[1.25x, 2x]` the pool spot it derives from the live WOOD/WETH pair — below 1.25x the cap binds permanently and pins every bond, above 2x it stops bounding manipulation — and refuses the run outside that band. The old "≤ 30-day low" instruction is now exactly backwards. A FORK run SHALL NOT take the constant: it derives its cap from its own pool spot (1.5x) and clears the same band, so the only end-to-end rehearsal cannot pass with a cap Mainnet would refuse.
- The market source is `src/pricing/WoodPoolFeed.sol`, minted by the ceremony itself and wired through `ledger.setWoodFeed(feed, maxDelay)` with `maxDelay = window + 2h + 1` (`RobinhoodParams.WOOD_FEED_MAX_DELAY`): `updatedAt` rolls at most once per window, so the bound must clear a window plus the keeper cadence. There is no separate TWAP-oracle contract and no unwired-market-source configuration — a ledger with no live WOOD price source never gets minted, because the stage gate runs first.
- PRE-FLIGHT 12 (pre-broadcast): the feed address SHALL hold code and its `maxDelay` SHALL be non-zero. `setWoodFeed` already enforces the pairing, but from inside the broadcast after the ledger and escrow exist and four setters have run; checking pre-broadcast turns a half-applied run into a free refusal.

#### Scenario: Unset price cap refused post-broadcast
- **WHEN** the Plan B phase completes its writes with `woodUsdPriceX8` still zero
- **THEN** the run FAILS naming the cap, because a zero cap reverts every price read and nothing can be proposed, executed or challenged

#### Scenario: Cap outside the band refused pre-broadcast
- **WHEN** `RobinhoodParams.WOOD_PRICE_CAP_X8` sits below 1.25x or above 2x the spot derived from the live WOOD/WETH pair and the ETH/USD feed
- **THEN** the Mainnet run refuses before broadcasting, naming which side of the band was breached

#### Scenario: Fork posture seats a cap in the same band
- **WHEN** a Fork-posture ceremony mints its WOOD feed fixture
- **THEN** the cap it seeds in the ledger is derived from that fork's own spot and satisfies the same `[1.25x, 2x]` bound, never `RobinhoodParams.WOOD_PRICE_CAP_X8`

#### Scenario: Feed deployed but not yet primed
- **GIVEN** `WoodPoolFeed` is minted but has not completed a `window` of keeper updates
- **THEN** the run returns `Checkpoint.AwaitingWoodFeed`: no ledger, no escrow, no handoff, and the operator's instruction is to run `update()` and re-run the same command

#### Scenario: Foreign pointer slot refused before the mint
- **WHEN** `StakedWood.exposureLedger` already names a ledger other than the one this run would mint
- **THEN** the run reverts "WIRING: StakedWood.exposureLedger already names a foreign address …", having deployed nothing

#### Scenario: Wrong slash ceiling refused pre-deploy
- **WHEN** the Plan B phase runs against an sWOOD with `maxSlashBps < 10_000`
- **THEN** the script reverts its PRE-FLIGHT before deploying the ledger

#### Scenario: Unwired unstake gate refused post-wiring
- **WHEN** the writes complete but sWOOD's `exposureLedger` pointer is still zero
- **THEN** the script reverts, directing the operator to call `setExposureLedger(ledger)` by governance and re-run

### Requirement: The WOOD price source is minted by the ceremony, per posture
On Mainnet posture the ceremony SHALL mint `src/pricing/WoodPoolFeed.sol` at the `sherwood.robinhood.v1.wood-pool-feed` salt and wire it as the ledger's market source. The feed reads two independent Uniswap-V2 `WOOD/WETH` pairs' own cumulative-price accumulators and the chain's Chainlink **ETH/USD** feed, composed as `WOOD/USD = TWAP(WOOD per ETH) × ETH/USD`; it needs no Chainlink WOOD/USD aggregator, which is the point of it.

Pre-flights, all PRE-broadcast:
- The two named pairs SHALL be DISTINCT and each SHALL hold exactly `{WOOD, WETH}` with a WETH reserve at or above `MIN_WETH_RESERVE`.
- WOOD and WETH SHALL share a decimals count. The composition multiplies a raw UQ112x112 ratio by ETH/USD with no decimals normalisation, so a mismatch prices WOOD off by orders of magnitude while every other check passes.
- Each pair SHALL have traded within `MAX_PAIR_IDLE` (5 minutes). A pair that stopped trading accepts the deploy and then no-ops forever, because the cumulative read refuses to extrapolate across a long idle span. On 4663 the pair trades continuously (measured 2026-08-04: 10s idle), so the guard is near-free in production and impossible to satisfy on a fork.
- The ETH/USD feed answers positive and is no staler than `ETH_USD_MAX_AGE`.

On Fork posture the ceremony SHALL mint `script/robinhood-mainnet/ForkWoodFeedFixture.sol` instead, at its own distinct salt, priced from the fork's OWN state — the WOOD/WETH pair reserves times the live ETH/USD answer — so bond valuations on the fork track mainnet rather than an invented number. The fixture reports `updatedAt` as `block.timestamp`, so it stays fresh across the `evm_increaseTime` warps a governance traversal needs; that makes staleness untestable through it, which is the correct trade for a fixture whose only job is keeping the price path alive across time travel. **The fixture SHALL refuse to be constructed on chain 4663.** A fixture feed on mainnet would price every guardian bond off an owner-writable number.

#### Scenario: Fixture feed refused on mainnet
- **WHEN** `ForkWoodFeedFixture` is constructed on chain 4663
- **THEN** the constructor reverts "ForkWoodFeedFixture: refused on 4663" before the ceremony can adopt it

#### Scenario: Idle pool refused before deploying
- **GIVEN** a WOOD/WETH pair that has not traded within `MAX_PAIR_IDLE`
- **THEN** the Mainnet feed phase refuses PRE-broadcast, naming that `update()` would never snapshot

#### Scenario: Fork price survives a governance warp
- **GIVEN** the fixture feed is wired as the ledger's market source
- **WHEN** the operator advances 48h with `evm_increaseTime` to traverse the vote + review windows
- **THEN** `woodPriceX8()` still resolves — the fixture reports itself fresh at the new `block.timestamp`, so no post-warp refresh step is owed

### Requirement: The ceremony seats the strategy-duration ceiling
The Plan B phase SHALL seat `ProtocolConfig.maxStrategyDuration` to `RobinhoodParams.MAX_STRATEGY_DURATION` inside the broadcast, and ONLY when the current value is zero — a Safe that has since raised the ceiling is not stomped by a re-run. There is no environment override and no way to express "no ceiling": the constant is non-zero and committed, and the post-broadcast assert confirms the live value is non-zero.

#### Scenario: Ceiling seated once
- **WHEN** the Plan B phase runs against a `ProtocolConfig` whose `maxStrategyDuration` is zero
- **THEN** it is seated to `RobinhoodParams.MAX_STRATEGY_DURATION` inside the broadcast, and the post-broadcast assert confirms it is non-zero

#### Scenario: Resumed run leaves an operator-raised ceiling alone
- **GIVEN** `maxStrategyDuration` is already non-zero
- **THEN** the phase writes nothing and the assert still passes

### Requirement: DeployPlanB asserts delegation is off
`DeployPlanB`'s post-broadcast pre-flights SHALL fail the run if `delegationEnabled` reads true on the target chain, naming the delegator-walkout hole: delegated stake is credited to a ~35-day coverage window while `requestUnstakeDelegation` checks only the delegator, and the unbonding pool is slashable for only `coolDownPeriod`.

#### Scenario: Delegation accidentally on
- **GIVEN** `delegationEnabled` reads true on the target chain
- **WHEN** the post-broadcast pre-flights run
- **THEN** the run FAILS with a message naming the delegator-walkout hole

#### Scenario: Preflight tests cover both invariants
- **THEN** `test/deploy/DeployPlanBPreflight.t.sol` covers: the duration ceiling seated once and left alone on a resumed run; delegation-on fails the named assert and delegation-off passes; a code-less feed refused; a zero `maxDelay` refused; each of the five pointer slots refused when it names a foreign address; and the two post-broadcast price checks (unset cap, cap with nothing priced beneath it)

### Requirement: Plan D deployment pre-flights and wiring order
The Plan D phase (ChallengeGame, against the Plan B contracts minted earlier in the same ceremony) SHALL run pre-flights before deploying anything, then wire the game's four roles in this order: `swood.setAuthorizedSlasher(game)` → `game.setStakedWood(swood)` → `tierRegistry.setAuthorizedDemoter(game)` → `ledger.setCoverageFreezer(game)`. The order is load-bearing at both ends: `setStakedWood` rejects a sWOOD that has not already granted the slasher role, so the GRANT precedes the POINTER; and `setCoverageFreezer` reverts `CoverageFrozen` once coverage is frozen, so the freeze role is granted LAST. Checks:
- PRE-FLIGHT 1: each of the three roles (`coverageFreezer`, `authorizedDemoter`, `authorizedSlasher`) MUST be UNSET **or already the game this run will mint** — the setters overwrite silently, so a role held by a FOREIGN address is refused rather than clobbered, while a resumed run adopts its own game instead of dying. Rotations require clearing by governance first.
- PRE-FLIGHT 0 (ownership): the broadcaster SHALL own `EXPOSURE_LEDGER`, `TIER_REGISTRY` and `STAKED_WOOD`; all three grant setters are `onlyOwner`, so all three get a named refusal ("PRE-FLIGHT: broadcaster does not own …") rather than an opaque `OwnableUnauthorizedAccount` mid-run.
- PRE-FLIGHT 2: the COMPOSED `ledger.woodPriceX8() != 0` (not the raw scalar) — a zero composed price means `file()` reverts `WoodPriceUnset` and nothing can be challenged. Read by low-level PROBE rather than a typed call: under design revision 2 that view reverts `NoWoodPrice` instead of returning zero when no source can price WOOD, and a typed call would let the revert propagate as an opaque script failure. Both shapes (reverts, or answers zero) fold into the same refusal, since to the game they are the same problem.
- Drift guard: `game.challengeWindow() == ledger.challengeWindow()`.
- Post-conditions: all four roles verified to land on THIS game, plus the game's `exposureLedger`/`tierRegistry` constructor pointers.

Manual follow-ups are load-bearing: the OFF-CHAIN bug-bounty program (on-chain a successful challenger only gets its bond back), `autoSlashDelay` review against real guardian response capability, and Ownable2Step handoff of game ownership.

#### Scenario: Role theft refused
- **WHEN** the Plan D phase runs against a chain where a DIFFERENT ChallengeGame already holds `coverageFreezer`
- **THEN** the run reverts its PRE-FLIGHT before deploying a new game

#### Scenario: Resumed run adopts its own game
- **GIVEN** a previous run already granted all three roles to the game at this ceremony's CREATE3 address
- **THEN** the pre-flight passes, nothing is minted twice and no setter is re-issued

#### Scenario: Composed-price check catches the right failure mode
- **WHEN** the raw `woodUsdPriceX8` scalar is set but the composed `woodPriceX8()` is zero (or vice versa)
- **THEN** the pre-flight follows the composed value — the figure `file()` actually divides by

### Requirement: TokenCourt deploy/wire split and its five pre-flights
The token court SHALL ship as two phases inside the single broadcast — `_deployCourt` (mint + `setChallengeGame` + `setStakedWood`, each written only when the slot is unset) and then `_wireCourt` (`game.setCourt(court)`) — so every pre-flight runs against the FINISHED pair before the game's `court` slot is touched. Court ownership is transferred by `_handoffAll` with every other Ownable2Step contract, not by this phase. The fail-safe if wiring refuses is benign: an unwired game times disputed challenges out in favour of the accused. `game.setCourt` SHALL further refuse a slot naming a FOREIGN court ("WIRING: ChallengeGame.court already names a foreign court …") — this ceremony never repoints a live slot. `_wireCourt` SHALL check:
1. PRE-FLIGHT 1: `court.challengeGame() == CHALLENGE_GAME` and `court.stakedWood() == STAKED_WOOD`.
2. PRE-FLIGHT 2: `game.stakedWood() == STAKED_WOOD` — sWOOD identity must match on BOTH contracts, or the electorate that votes is not the cohort that gets slashed.
3. PRE-FLIGHT 3 (cross-contract window invariant): `game.autoSlashDelay() + court.voteWindow() + court.FINALIZE_BUFFER() <= game.disputeTimeout()`, or the referral window is negative and every disputed challenge free-wins for the accused. Both contracts enforce this against each other's live state on later reconfiguration, but the very FIRST wiring of a fresh pair has nothing to validate against — this script is that external check. Defaults: 7d + 5d + 1d = 13d ≤ 30d.
4. PRE-FLIGHT 4 (launch math): `court.participationFloorBps() < swood.ageFloorBps()` — turnout is AGED weight while the floor's base is RAW stake, so with all stake young a floor at or above the age-floor fraction is unclearable. Defaults: 1,000 < 2,500 (implying 40% of raw stake must vote at launch).
5. PRE-FLIGHT 5 (Plan D wiring intact): `ledger.coverageFreezer() == CHALLENGE_GAME`, `tiers.authorizedDemoter() == CHALLENGE_GAME`, `swood.authorizedSlasher() == CHALLENGE_GAME` — or a Guilty verdict dead-ends at `_settle`.

Manual follow-ups: an sWOOD upgrade touching `slashVerdict`'s ABI and any ChallengeGame redeploy that calls it MUST ship as ONE atomic governance batch (a selector mismatch makes every `resolve()` revert with coverage frozen); monitor `AutoReferFailed` (referral is automatic but best-effort — permissionless `TokenCourt.refer` is the fallback); off-chain voter incentives are an operational commitment without which the participation floor may never clear.

This requirement and `script/DeployTokenCourt.s.sol` are removed TOGETHER with SHE-269, which resolves disputed challenges by guardian vote instead; the court is a branch-specific phase, not a permanent one.

#### Scenario: Negative referral window refused
- **WHEN** `autoSlashDelay + voteWindow + FINALIZE_BUFFER > disputeTimeout` on the pair being wired
- **THEN** `_wireCourt` reverts PRE-FLIGHT 3 before calling `setCourt`

#### Scenario: Broken Plan D wiring refused
- **WHEN** any of the three Plan D roles no longer points at the challenge game
- **THEN** `_wireCourt` reverts PRE-FLIGHT 5 — the court must not be granted ruling authority over a game whose verdicts cannot execute

### Requirement: Chain-specific factory identity configuration
On Robinhood Chain the factory SHALL be deployed with `address(0)` for both `ensRegistrar` and `agentRegistry` (identity + subname registration disabled), and validation SHALL assert both read back as zero. There is no ENS/Durin registrar on 4663; the canonical ERC-8004 IdentityRegistry (`0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`) IS live there, so the zero `agentRegistry` is a v1 product decision, not a chain constraint, and wiring it later is a factory-config change with no redeploy.

#### Scenario: Identity disabled on Robinhood
- **WHEN** post-deploy validation runs on 4663 or its fork
- **THEN** `factory.ensRegistrar() == address(0)` and `factory.agentRegistry() == address(0)`

### Requirement: Accepted oracle risks are stated in the deploy runbook
Two oracle exposures are accepted for v1, not open defects, and SHALL be documented in the operator's line of sight rather than only in source natspec: (1) Chainlink aggregators clamp at `minAnswer`/`maxAnswer` — a clamped price is anti-conservative, understating `coverageUsd` (asset side) and over-valuing guardian bonds via `woodPriceX8` (WOOD side), with `woodHaircutBps` a fixed discount rather than a clamp bound; and (2) Robinhood Chain 4663 publishes no sequencer-uptime feed, so the standard staleness-plus-grace-period gate (`src/libraries/ChainlinkReader.sol`'s `SequencerDown`/`GracePeriodNotOver`) cannot be built — `ExposureLedger` reads aggregators directly, and `ASSET_FEED_MAX_DELAY` SHALL be sized tightly enough that a plausible outage pushes reads past staleness while still clearing the aggregator's own publication heartbeat.

The WOOD half of exposure (1) is now BOUNDED rather than merely disclosed: every market source, Chainlink included, is admitted only under `min(source, woodUsdPriceX8)`, so a clamped-high aggregator can over-value bonds by at most the cap. The asset half is unchanged — `coverageUsd` has no such ceiling.

#### Scenario: Reviewer reads the runbook
- **WHEN** a reviewer or deploy operator reads the runbook end to end
- **THEN** they encounter the aggregator clamping risk with its anti-conservative direction and the affected read paths (`coverageUsd`, `woodPriceX8`), the fact that the WOOD path is capped and the asset path is not, and the absence of a sequencer-uptime feed on Robinhood 4663 with why the usual staleness gate cannot exist, all stated as accepted-for-v1

### Requirement: The WOOD price is market-sourced and governance-capped
`ExposureLedger` SHALL resolve the WOOD price as `haircut(min(market, woodUsdPriceX8))`, floored at 1, where `market` is the wired WOOD/USD feed — on Robinhood the ceremony's own `WoodPoolFeed`, which is Chainlink-shaped — when it is fresh. `woodUsdPriceX8` SHALL NEVER be served as a price. With no market source available the ledger SHALL revert `NoWoodPrice` rather than fall back to the governance scalar (design revision 2, 2026-08-02).

The runbook SHALL state the operational consequences:
- **Seed and maintain the cap ABOVE market.** It bounds upward manipulation and nothing else; a cap at `M×` market caps manipulation at `M×`. It does not need accuracy, because it is never the valuation — a monthly review is sufficient, since a drifted cap simply stops binding. It does need MAINTENANCE: it is the only thing bounding upward manipulation of a ~$438k pool, where moving spot 2× costs ~$91k.
- **Lowering the cap is the emergency brake** — safe direction, unbounded, immediate, and NOT rate-limited on-chain. The ledger's one-move-per-day interval and its 2×-per-raise ceiling were both removed (issue #89); rate limiting is enforced off-chain by a Zodiac module on the owner Safe. See "Rate limiting is enforced off-chain" below.
- **A keeper SHALL call `WoodPoolFeed.update()`**, permissionlessly and on a schedule shorter than the `maxDelay` passed to `setWoodFeed`. A failing keeper is how the feed goes stale, and a stale feed with no other WOOD source is `NoWoodPrice`. `update()` is a no-op when a pool is early or below its depth floor, so a failing keeper looks like nothing at all.
- **`NoWoodPrice` is fail-safe, not a halt, and the asymmetry is deliberate.** `recordApproval` CATCHES it and books nothing, so approve votes still land and reviews never become block-only. `requireApproveQuorum` (execute), `proposerBondWood` (propose) and `ChallengeGame.file` all let it revert. `slashBpsFor` reads no price at all (PR #102), so convictions still compute through a total outage. Net effect: votes work, nothing new can be proposed, nothing can execute, live challenges resolve.
- **Monitoring SHALL poll `woodPriceDetail()`**, which returns `(price, fromFeed, capBinding)`. Alert on `capBinding == true` persisting beyond a short excursion: it means the cap has drifted BELOW market and is pinning every bond while the market source sits inert. Alert on `woodPriceX8()` reverting at all. There is no event for either state.

#### Scenario: Operator wires a Chainlink WOOD feed
- **WHEN** the operator wires `setWoodFeed(feed, maxDelay)`
- **THEN** the runbook states that the feed is the market source but is still capped by `woodUsdPriceX8`, that on any of the four degraded shapes (feed unset, non-positive answer, stale, reverting) the ledger has NO market source and reverts `NoWoodPrice`, and that unwiring the feed is therefore never safe

#### Scenario: Operator considers the cap a conservative price
- **WHEN** an operator seeds `woodUsdPriceX8` at or below market, as the retired "≤ 30-day low" instruction said to
- **THEN** the cap binds permanently, every bond is valued at the cap, and the market source can no longer track a crash — the runbook names this as the misconfiguration to avoid, not a conservative choice

#### Scenario: The WOOD feed goes stale
- **WHEN** the keeper stops and the newest snapshot ages past the wired `maxDelay`
- **THEN** approve and block votes both continue to land, new proposals are refused at `propose`, tier-gated proposals cannot execute, and convictions on already-filed challenges still compute

### Requirement: The WOOD price carries two accepted overstatements, and `woodHaircutBps` is the control
Two exposures are ACCEPTED rather than eliminated (owner decision 2026-08-02). The runbook SHALL state both, together with the parameter that covers them.

**(a) The two legs are not contemporaneous.** `WoodPoolFeed` multiplies a near-real-time WOOD/ETH average by a single Chainlink ETH/USD answer that may be up to one heartbeat old — the live 4663 feed was measured **10.7 hours old while perfectly healthy**, so this is the normal case, not a degraded one. During an ETH drawdown inside that heartbeat the pair ratio rises while the stale, pre-drawdown ETH price is still the multiplier, so WOOD/USD reads high by roughly the size of the ETH move and every bond is over-valued until the feed ticks. **No attacker capital is required** — ordinary market movement against a slow feed, which makes it likelier than any manipulation scenario.

It is accepted because the remedy is worse. Requiring the ETH answer to be no older than the averaging `window` forces `window >= ~12h`, and a 12-hour window means half a day of blindness to a WOOD crash — unbounded in magnitude and fixed in duration, traded against an overstatement that is bounded in magnitude. Tracking a drawdown without waiting on a human is the whole purpose of the feed. `ethUsdMaxAge` is therefore deliberately INDEPENDENT of `window`, so the window can be short.

**(b) Residual crash lag** of up to `window + maxDelay`, inherent to averaging and the price paid for manipulation resistance.

Both OVERSTATE bond value — the dangerous direction — and both are bounded by the same two controls: `woodUsdPriceX8` truncates anything above the cap, and `woodHaircutBps` pre-funds an allowance below it. **`woodHaircutBps` is therefore LOAD-BEARING.**

**The shipped value is 5,000 — a 50% allowance — and the Plan B phase SHALL seat it** inside the broadcast from `RobinhoodParams.WOOD_HAIRCUT_BPS`, with no runtime override. The ledger's own default is 10,000, which is no haircut and therefore no allowance at all, and its setter ACCEPTS 10,000 as a legal value — so nothing else in the stack refuses that configuration and it would ship silently. Pre-flight 9 refuses it. 5,000 is also the ledger's `MIN_WOOD_HAIRCUT_BPS`, so the deploy default and the floor coincide by design and any raise of the floor must move the deploy constant in the same change. Precisely: 5,000 values every source at 50%, so an overstatement of up to 100% still leaves bonds valued at or below their true worth.

5,000 was once rejected as too costly to guardian return on equity, but that was under full-coverage reservation. With declared locks (SHE-227) the haircut is the ONLY buffer between the WOOD price at approval and at verdict 4–6 weeks later: at 7,000 the cohort's burn equals the loot after a 30% WOOD drop, at 5,000 after a 50% drop, and guardian ROE stays at 1.6–4.2%/yr. SHE-182 adopted 5,000 as the launch configuration on that basis.

**The shipped value sits ON the floor, so there is no downward travel left.** Lowering the haircut would be the safe direction (more allowance, bonds valued lower, quorums harder), but the setter refuses anything below `MIN_WOOD_HAIRCUT_BPS`, and issue #89's removal of the once-per-day interval therefore buys nothing here. The crisis brake is the other lever this section names: lowering `woodUsdPriceX8` truncates every bond, takes one owner transaction, and is likewise un-rate-limited on-chain. Raising the floor is not a parameter change at all — `MIN_WOOD_HAIRCUT_BPS` is a constant, so it needs a ledger redeploy.

Finding 5's window-vs-staleness invariant is unaffected and remains enforced by `WoodPoolFeed` itself — a different problem (structural unavailability) with a different fix.

#### Scenario: Operator sizes the haircut
- **WHEN** the operator seats `woodHaircutBps` before launch
- **THEN** the runbook states that the value is an allowance against the ETH-staleness overstatement and the crash lag, that the shipped value is 5,000 (a 50% allowance, equal to the ledger floor), that 10,000 leaves none at all and is refused by pre-flight 9, and that the earlier guardian-ROE objection to 5,000 was reconsidered under declared locks (SHE-182)

#### Scenario: Deploy would leave the haircut at the ledger default
- **WHEN** `DeployPlanB` would complete with `woodHaircutBps == 10_000`
- **THEN** pre-flight 9 FAILS, naming what the allowance is FOR rather than only that the value is out of range

#### Scenario: Bond valuation needs tightening during a crash
- **GIVEN** the deploy seated the haircut at the floor minutes earlier
- **THEN** `setWoodUsdPrice` succeeds at once — the on-chain interval that would have refused it is gone (issue #89), and any delay now comes from the owner Safe's module configuration — while `setWoodHaircutBps` below `MIN_WOOD_HAIRCUT_BPS` is refused by value, not by time

### Requirement: Rate limiting is enforced off-chain, and the contract imposes none
`ExposureLedger.setWoodUsdPrice` and `setWoodHaircutBps` SHALL impose no rate limit and no per-call size ceiling. The owner may move either lever to any legal value, any number of times, within one block. **Rate limiting is enforced OFF-CHAIN by a Zodiac Delay/Roles module on the owner Safe** (issue #89, owner decision 2026-08-02).

This is a TRUST-MODEL CHANGE and SHALL be documented as one in both the setter natspec and this runbook. An auditor reading `ExposureLedger` previously saw a self-limiting owner; they now see an unrestricted one, with the control living in a Safe configuration that is invisible from the source. Undocumented, the next reviewer either files it as a finding or — worse — assumes a protection that was moved.

**What was removed, and why both together.** A 1-day `MIN_PRICE_UPDATE_INTERVAL` on both setters, and a `newPriceX8 <= current * 2` ceiling on cap raises. The interval was the only thing that made the ceiling a rate limit at all — N calls in one multisig batch move the price 2ᴺ — so the ceiling could not be kept alone without advertising a protection that the exact party it constrains can bypass in a single batch. The storage that backed the interval (`lastPriceUpdateAt`, `lastHaircutUpdateAt`) was deleted; this is safe because `ExposureLedger` is not upgradeable and is not among the layouts `check-layout-goldens.sh` pins.

**Why moved rather than fixed.** The interval gated BOTH directions while the size ceiling gated only raises, so the code limited a move's *size* by direction but its *timing* regardless. After design revision 2 lowering the cap IS the emergency action, so the limit sat directly on crisis response: whoever touched the lever first spent it, urgency-blind, and a routine morning adjustment left no brake that afternoon. A self-limit on an already-trusted owner bought little and cost exactly the responsiveness it most needed to preserve.

**THE PROPERTY THE ZODIAC CONFIGURATION MUST PRESERVE — the delay SHALL be ASYMMETRIC: raises delayed, drops immediate.** A plain Zodiac Delay module is symmetric and would delay the emergency lowering too, relocating the bug rather than fixing it — possibly with a longer delay than the one removed. A Roles modifier can scope by selector and by static parameter conditions but **cannot compare an argument against current on-chain state**, so it cannot express "allow if lower than the stored value". The practical shape is therefore a **fast path for arguments below a fixed threshold** set comfortably beneath any plausible cap, with everything above it routed through the Delay module. **If the configuration cannot preserve the asymmetry, the in-contract limit SHALL NOT have been removed** — restore the direction-scoped interval instead.

**It must actually be deployed.** A documented off-chain control that nobody configured is worse than an on-chain one, because the source no longer carries a trace of the requirement. Pre-flight 10 has MOVED out of the Plan B phase and into the ceremony's post-handoff validation, because the ledger owner is the deployer until the handoff runs and only afterwards is the Safe the answer: on Mainnet posture, `ExposureLedger.pendingOwner()` SHALL be `OWNER_MULTISIG` and that address SHALL hold code. On Fork posture it is SKIPPED — the owner is the deployer, an EOA, and there is no Safe — which retires `ALLOW_EOA_LEDGER_OWNER`: the waiver is now a property of posture rather than an env key an operator could set on mainnet. Acceptance itself is verified later by `script/verify-robinhood.sh`, after the Safe has called `acceptOwnership()`. This is the most an on-chain check can establish. It deliberately does not probe for modules: enumerating a Safe's modules would prove only that *some* module is attached, not that the delay is asymmetric, and a probe that appears to verify the requirement while verifying something weaker is worse than none. **The asymmetry is a runbook obligation, verified by a human before launch.** The Zodiac configuration is a prerequisite for LAUNCH, not for merge; until it exists the protocol has neither the on-chain limit nor the off-chain one.

#### Scenario: Auditor reads the price setters
- **WHEN** a reviewer reads `setWoodUsdPrice` and finds no interval and no size ceiling
- **THEN** the natspec states plainly that rate limiting is enforced off-chain by a Zodiac module and that this contract deliberately imposes none, so the absence reads as a documented decision rather than a missing control

#### Scenario: EOA owner refused at deploy
- **WHEN** a Mainnet run completes with `OWNER_MULTISIG` naming an externally-owned account
- **THEN** pre-flight 10 FAILS in post-handoff validation, naming that the protocol would carry neither the on-chain limit nor the off-chain one

#### Scenario: Fork posture skips the owner check
- **GIVEN** a Tenderly vnet, whose deployer is an impersonated EOA and where no Safe exists
- **THEN** pre-flight 10 does not run at all, because a fork hands off to its own deployer and there is no Safe to check — the waiver is derived from posture rather than set by an operator, so no key exists that could waive it on mainnet

#### Scenario: Symmetric delay module configured
- **GIVEN** the Safe carries a plain Zodiac Delay module applying the same delay to every call
- **THEN** the configuration is REJECTED at review: the emergency lowering is delayed exactly as the removed interval delayed it, which relocates the problem instead of solving it

#### Scenario: Crash requires two cap reductions in one day
- **WHEN** WOOD drops 40% in the morning and a further 50% that afternoon
- **THEN** both reductions land — the on-chain interval that previously locked the lever until the next day is gone, and the Safe's fast path passes low arguments straight through

#### Scenario: ETH drawdown inside the feed heartbeat
- **GIVEN** ETH falls sharply while the ETH/USD answer is several hours old
- **THEN** WOOD/USD reads high by roughly the ETH move until the feed ticks, bonds are over-valued for that period, and the exposure is bounded above by the cap and below by the haircut — an accepted risk, documented, not a defect to file

#### Scenario: Short averaging window with a slow USD feed
- **WHEN** the feed's averaging `window` is short while `ethUsdMaxAge` is 24 hours
- **THEN** the configuration is ACCEPTED — the two are independent by design, and coupling them would force a ~12-hour window and surrender the crash tracking the feed exists to provide
