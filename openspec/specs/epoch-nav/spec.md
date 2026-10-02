# Epoch NAV and Pricing Specification

## Purpose

Defines how `ExposureLedger` prices value for coverage: the WOOD/USD price (the wired feed, on Robinhood the ceremony's `WoodPoolFeed`, capped by the governance-set `woodUsdPriceX8` and haircut, reverting `NoWoodPrice` when unavailable), vault-asset USD pricing that fails closed on staleness, and the wall-clock epoch schedule that buckets guardian exposure. Strategy NAV is not in scope: vault NAV is float-only and defined by the `syndicate-vault` capability. Per-epoch NAV checkpointing does not exist; a protocol-wide ceiling on strategy duration bounds each commitment to one covered window instead.

## Requirements
### Requirement: Coverage epochs are a fixed wall-clock schedule

The `ExposureLedger` SHALL derive coverage epochs from an immutable schedule: `epochLength` is set at construction (non-zero; 28 days on the Robinhood deployment), `epochGenesis` is the deployment timestamp, and `currentEpoch() = (block.timestamp - epochGenesis) / epochLength`. Each guardian lock SHALL be booked into the epoch containing the proposal's `executeBy + strategyDuration` (at most `MAX_COVERAGE_HORIZON`, 60 days, ahead) and SHALL count toward open exposure until that epoch's end plus the challenge window. The bucket accounting itself is specified by the guardian-coverage capability ("Epoch-bucketed exposure accounting").

#### Scenario: Epoch index advances on wall clock

- **WHEN** `epochLength` seconds elapse from `epochGenesis`
- **THEN** `currentEpoch()` increments by exactly one, independent of any protocol activity

#### Scenario: Zero epoch length is undeployable

- **WHEN** the ledger is constructed with `epochLength_ == 0`
- **THEN** construction reverts `InvalidParameter`

### Requirement: Bounded duration substitutes for per-epoch NAV checkpointing in v1

The protocol SHALL NOT record per-epoch NAV checkpoints on-chain in v1. Instead, `ProtocolConfig.maxStrategyDuration` SHALL impose a protocol-wide ceiling on `strategyDuration` (clamping every vault's own maximum), so a single guardian commitment spans the whole risk window and the drawdown predicate (predicate 5, `DrawdownBreach`) is enforceable at settlement without renewal, NAV checkpointing or claims-made attribution. The clamp SHALL hold at `propose`: a proposal whose `strategyDuration` exceeds the smaller of the vault's stored `maxStrategyDuration` and the live ceiling of the governor's `protocolConfig` SHALL revert `StrategyDurationTooLong`, whatever maximum the vault stored before the ceiling dropped. The setter SHALL be owner-only and SHALL reject a non-zero value below 1 day; zero means "no protocol ceiling" (preserving pre-parameter deployments) and changes never rebind in-flight proposals, which snapshot parameters at propose time. In the challenge game the drawdown predicate is a label carried in the filing event — no contract derives it from on-chain NAV records.

#### Scenario: Degenerate ceiling rejected

- **WHEN** the owner sets `maxStrategyDuration` to a non-zero value below 1 day
- **THEN** the call reverts `InvalidMaxStrategyDuration`

#### Scenario: In-flight proposals keep their snapshot

- **WHEN** the ceiling changes while a proposal is live
- **THEN** only proposals created afterwards see the new ceiling

#### Scenario: Lowered ceiling binds existing and new vaults at propose

- **WHEN** the owner lowers the ceiling below a vault's stored `maxStrategyDuration`, on a vault created before or after the change
- **THEN** a proposal longer than the ceiling reverts `StrategyDurationTooLong`, and one within both bounds proposes

### Requirement: WOOD feed wiring and clearing

`setWoodFeed(feed, maxDelay)` SHALL be owner-only and SHALL enforce:

- **Clearing**: `feed == address(0)` is legal ONLY with `maxDelay == 0`; it deletes the feed config, after which every WOOD price read reverts `NoWoodPrice` (there is no fallback price). A zero address paired with a non-zero delay SHALL revert `InvalidParameter`, so a mistyped address cannot silently disable the feed.
- **Wiring**: a non-zero `feed` SHALL require `maxDelay != 0` and at most `type(uint64).max` (revert `InvalidParameter` otherwise), and the ledger SHALL read `feed.decimals()` at wiring time, reject more than 18, and cache it — an address that cannot answer `decimals()` cannot be wired.
- `WoodFeedSet(feed, maxDelay)` SHALL be emitted on both wire and clear.

How the wired feed and the cap compose into `woodPriceX8()` is specified by the guardian-coverage capability ("WOOD is priced by the feed, capped by governance, with no fallback").

#### Scenario: Explicit clear leaves WOOD unpriced

- **WHEN** the owner calls `setWoodFeed(address(0), 0)`
- **THEN** the feed config is deleted, `WoodFeedSet(address(0), 0)` is emitted, and `woodPriceX8()` reverts `NoWoodPrice`

#### Scenario: Zero maxDelay on a real feed is rejected

- **WHEN** the owner calls `setWoodFeed(feed, 0)` with a non-zero feed
- **THEN** the call reverts `InvalidParameter`

#### Scenario: Zero address with a real delay is rejected

- **WHEN** the owner calls `setWoodFeed(address(0), 1 days)`
- **THEN** the call reverts `InvalidParameter` rather than treating it as a clear

### Requirement: Vault-asset pricing fails closed

`ExposureLedger.coverageUsd(asset, amount)` — the USD-18 valuation behind every coverage check — SHALL fail closed, as the WOOD price does:

- an asset with no registered feed SHALL revert `FeedNotConfigured`,
- a feed answer `<= 0` or older than the feed's `maxDelay` SHALL revert `StalePrice` (a future `updatedAt` counts as age 0, never an underflow),
- conversions floor (sub-wei dust accepted).

`setAssetFeed(asset, feed, maxDelay)` SHALL be owner-only, SHALL reject zero addresses (`ZeroAddress`), `maxDelay` of 0 or above `type(uint64).max`, and feed decimals above 18 (`InvalidParameter`), and SHALL cache both asset and feed decimals at registration so the hot pricing path makes no external metadata calls. WOOD deliberately does not go through this path.

#### Scenario: Unpriceable asset blocks coverage

- **WHEN** `coverageUsd` is called for an asset with no configured feed
- **THEN** it reverts `FeedNotConfigured` — a proposal in an unpriceable asset cannot be coverage-checked

#### Scenario: Stale asset feed blocks coverage

- **WHEN** the asset feed's answer is non-positive or older than `maxDelay`
- **THEN** `coverageUsd` reverts `StalePrice`

#### Scenario: Approval reverts on an unpriceable asset

- **WHEN** `recordApproval` runs for a vault whose asset pricing fails (no feed or stale)
- **THEN** it reverts with the pricing error, so an Approve vote cannot be cast while the asset cannot be priced; a Block vote is unaffected

