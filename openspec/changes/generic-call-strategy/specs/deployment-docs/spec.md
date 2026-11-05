## MODIFIED Requirements

### Requirement: Deploy ceremony order and skip rules
The ceremony SHALL be ONE script, `script/robinhood-mainnet/DeployAll.s.sol:DeployAll`, whose phases run in a fixed order inside ONE broadcast: Create3Factory bootstrap → core (`deployCore` + `_seatOwnerWrites`, including the TierRegistry launch set) → UniswapSwapAdapter and the Portfolio / MorphoSupply / ConcentratedLiquidity / GenericCall templates → StrategyFactory → the WOOD price source → Plan B → Plan D → open syndicate creation (`setAgentRegistry`, Mainnet run 2 only) → handoff.

The Fork posture completes in ONE run. The Mainnet posture completes in TWO runs separated by the WOOD feed's warm-up: the first run mints `WoodPoolFeed`, returns `Checkpoint.AwaitingWoodFeed` and performs NO handoff; the operator then calls `WoodPoolFeed.update()` on a keeper until `latestRoundData()` answers (at least one `window`, 24h minimum); the second run finds the feed answering, deploys the coverage stack and hands off. Between the two runs the deployer key still owns every contract — that window is the price of the warm-up and SHALL be stated in the runbook, not discovered.

The broadcaster SHALL equal the book's `DEPLOYER`, and the script reverts "broadcaster != DEPLOYER in the address book" otherwise. There is no skip flag: WHO ends up owning the protocol is a property of the posture. On Mainnet `OWNER_MULTISIG` is REQUIRED from the book and MUST be a contract (Safe), not an EOA, with ONE exception: a book whose `OWNER_MULTISIG` equals its `DEPLOYER` DEFERS the handoff, so the run completes with the deployer key owning every contract and nothing pending. The handoff then happens in a later run, after the book names the real owner and the deployer has re-pointed the creation-fee recipient to it. On Fork the owner is the deployer itself, so the handoff still runs and is a no-op; a Fork book MAY carry `OWNER_MULTISIG` only when it equals `DEPLOYER`, and anything else is REFUSED ("Fork posture hands off to the deployer: OWNER_MULTISIG must be absent or equal DEPLOYER") so a mainnet Safe copied into a fork book cannot become the target. `_handoffAll` SHALL refuse an unset target, which would be unrecoverable.

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

`StrategyFactory`'s approval map starts empty and nothing else populates it, so a template the ceremony does not approve can never be cloned by a proposal. The StrategyFactory phase SHALL approve EXACTLY the four templates carried on the ceremony's `Stack` and SHALL assert all four read back approved. There is no skip path and no `approved > 0` threshold: a template with no code refuses the run ("template holds no code: run the template phases first"). `DeployStrategyFactory._templateKeys()` names the four address-book keys `_persist` writes, and is pinned as an exact set.

The list SHALL name `PORTFOLIO_TEMPLATE`, `MORPHO_SUPPLY_TEMPLATE`, `CONCENTRATED_LIQUIDITY_TEMPLATE` and `GENERIC_CALL_TEMPLATE`, and nothing else — every key on it has a live contract in `src/strategies/` and a script that deploys it. `MOONWELL_SUPPLY_TEMPLATE`, `AERODROME_LP_TEMPLATE`, `WSTETH_MOONWELL_TEMPLATE` and `MAMO_YIELD_TEMPLATE` were REMOVED (deprecated, 2026-08-04): none has a contract remaining in `src/strategies/`, none resolves in a committed address book, and removal affects only a NEW `StrategyFactory` — already-deployed factories keep the approvals they were given.

`MorphoSupplyStrategy` requires NO Morpho address and NO market params at deploy time. It is an ERC-1167 template: the Morpho singleton, the `MarketParams` tuple and the supply amount all arrive per clone via `_initialize(bytes)`, so they are proposal inputs. The template is deliberately left uninitialized, which is the correct resting state for a clone source.

`GenericCallStrategy` likewise requires NO venue address at deploy time: its call lists, pull amount and sweep tokens arrive per clone via `_initialize(bytes)`, and it binds no counterparty, so it needs no TierRegistry seeding. On a chain whose TierRegistry the deployer no longer owns (4663 after the handoff), the StrategyFactory phase cannot run, so the template reaches the allowlist only through the owner's `setTemplateApproval(template, true)`.

#### Scenario: Morpho template reaches the allowlist
- **WHEN** the ceremony completes
- **THEN** `chains/{chainId}.json` carries `MORPHO_SUPPLY_TEMPLATE`, `_templateKeys()` names it, and `StrategyFactory.approvedTemplate` is true for it

#### Scenario: Deprecated template keys refused entry
- **WHEN** a deprecated key is re-added to `_templateKeys()`
- **THEN** the exact-set assertion in `test/factory/deploy/DeployMorphoStrategy.t.sol` FAILS, because a key with no backing contract overstates what the protocol can propose

#### Scenario: Generic-call template reaches the allowlist
- **WHEN** the ceremony completes on a fresh deployment
- **THEN** `chains/{chainId}.json` carries `GENERIC_CALL_TEMPLATE`, `_templateKeys()` names it, and `StrategyFactory.approvedTemplate` is true for it
