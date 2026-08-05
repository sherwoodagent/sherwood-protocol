# Epoch NAV and Pricing Specification

## Purpose

Defines how the protocol establishes value: WOOD and vault-asset USD pricing in the `ExposureLedger` with explicit staleness and fallback rules, and the wall-clock epoch schedule that buckets guardian exposure. Per-epoch NAV *checkpointing* (design §3.4a, Plan F) is intentionally absent from v1: a protocol-wide ceiling on strategy duration bounds each commitment to a single covered window instead.

Strategy NAV is deliberately NOT in scope. The vault-side `PriceRouter` that once priced a live strategy was retired with Lane A (issue #54), so vault NAV is float-only and defined by the `syndicate-vault` capability, not here. What survives in this capability is guardian-bond and coverage pricing — `ExposureLedger` and `WoodTwapOracle` — which never referenced the router. V2 reintroduces strategy pricing together with the lane it serves.

## Requirements

### Requirement: WOOD is priced feed-first with a maintained governance fallback

`ExposureLedger.woodPriceX8()` — the WOOD/USD price (8 decimals) behind every bond valuation — SHALL read the wired Chainlink feed first and fall back to the governance-set `woodUsdPriceX8` rather than reverting. The fallback SHALL be taken in all four degraded shapes:

- no feed wired (`_woodFeed.feed == address(0)`),
- feed answer `<= 0`,
- feed answer older than the feed's `maxDelay` (a future `updatedAt` counts as age 0),
- feed reverting on `latestRoundData()` — the call SHALL be wrapped in try/catch so a dead aggregator degrades instead of failing every Approve vote and tier-gated execute.

A healthy feed answer SHALL be normalized to 8 decimals using the feed decimals cached at wiring. The `woodHaircutBps` haircut SHALL apply to BOTH the feed path and the fallback path, so enabling the haircut can never make the degraded path less conservative than the primary. `woodPriceDetail()` SHALL expose whether the returned price came from the fallback, so monitoring can observe the degraded state.

#### Scenario: Stale feed falls back

- **WHEN** the wired feed's `updatedAt` is older than `maxDelay`
- **THEN** `woodPriceX8()` returns the haircut governance price and `woodPriceDetail()` reports `usingFallback == true`

#### Scenario: Reverting feed falls back

- **WHEN** `latestRoundData()` on the wired feed reverts
- **THEN** the price falls back to the haircut governance number instead of propagating the revert into vote, execute, settle and slash paths

#### Scenario: Healthy feed supersedes the governance price

- **WHEN** the wired feed answers a positive price within `maxDelay`
- **THEN** `woodPriceX8()` returns the feed price normalized to 8 decimals with the haircut applied, and `usingFallback == false`

#### Scenario: Haircut binds both paths

- **WHEN** `woodHaircutBps` is below 10_000
- **THEN** both the feed price and the governance fallback are scaled by `woodHaircutBps / 10_000`

### Requirement: WOOD feed wiring is explicit in both directions

`setWoodFeed(feed, maxDelay)` SHALL be owner-only and SHALL enforce:

- **Clearing**: `feed == address(0)` is legal ONLY with `maxDelay == 0`; it deletes the feed config and returns pricing to the governance fallback. A zero address paired with a non-zero delay SHALL revert `InvalidParameter`, so a mistyped address cannot silently disable the feed.
- **Wiring**: a non-zero `feed` SHALL require `maxDelay != 0` (revert `InvalidParameter` otherwise), and the ledger SHALL read `feed.decimals()` at wiring time and cache it — an address that cannot answer `decimals()` (including any EOA, via the extcodesize guard on the high-level call) cannot be wired.
- `WoodFeedSet(feed, maxDelay)` SHALL be emitted on both wire and clear.

#### Scenario: Explicit clear returns to fallback

- **WHEN** the owner calls `setWoodFeed(address(0), 0)`
- **THEN** the feed config is deleted, `WoodFeedSet(address(0), 0)` is emitted, and `woodPriceX8()` uses the governance fallback

#### Scenario: Zero maxDelay on a real feed is rejected

- **WHEN** the owner calls `setWoodFeed(feed, 0)` with a non-zero feed
- **THEN** the call reverts `InvalidParameter`

#### Scenario: Zero address with a real delay is rejected

- **WHEN** the owner calls `setWoodFeed(address(0), 1 days)`
- **THEN** the call reverts `InvalidParameter` rather than treating it as a clear

### Requirement: The governance WOOD price is rate-limited upward only

`setWoodUsdPrice(newPriceX8)` SHALL be owner-only and SHALL enforce:

- at least `MIN_PRICE_UPDATE_INTERVAL` (1 day) between updates, with only the first-ever price exempt,
- an upward move bounded at 2x the current price, except recovery from a current price of zero,
- NO bound on downward moves — the price exists to absorb a WOOD crash, and zero remains settable as the emergency stop (which disables coverage protocol-wide, documented fail-closed).

#### Scenario: Batched pump is blocked

- **WHEN** the owner sets a price and attempts a second update within 1 day
- **THEN** the second call reverts `InvalidParameter`

#### Scenario: More-than-2x upward move is blocked

- **WHEN** the current price is non-zero and `newPriceX8 > current * 2`
- **THEN** the call reverts `InvalidParameter`

#### Scenario: Crash markdown is immediate

- **WHEN** the owner marks the price down by any factor (respecting the update interval)
- **THEN** the call succeeds — downward moves are unbounded by design

### Requirement: The WOOD haircut is floored, capped and rate-limited

`setWoodHaircutBps(newBps)` SHALL be owner-only, SHALL accept only `[5_000, 10_000]` (a haircut below half of market is a mis-set parameter; above 100% would value bonds above market), and SHALL enforce the same 1-day minimum interval between updates (first update exempt). The default is 10_000 (no haircut), so wiring a feed alone does not silently change valuations.

#### Scenario: Out-of-range haircut rejected

- **WHEN** the owner sets a haircut below 5_000 or above 10_000
- **THEN** the call reverts `InvalidParameter`

### Requirement: Vault-asset pricing fails closed on staleness

`ExposureLedger.coverageUsd(asset, amount)` — the USD-18 valuation behind every coverage check — SHALL fail closed, in contrast to the WOOD price's fail-degraded stance:

- an asset with no registered feed SHALL revert `FeedNotConfigured`,
- a feed answer `<= 0` or older than the feed's `maxDelay` SHALL revert `StalePrice` (a future `updatedAt` counts as age 0, never an underflow),
- conversions floor (sub-wei dust accepted).

`setAssetFeed(asset, feed, maxDelay)` SHALL be owner-only, SHALL reject zero addresses and `maxDelay` of 0 or above `type(uint64).max`, and SHALL cache both asset and feed decimals at registration so the hot pricing path makes no external metadata calls. WOOD deliberately does not go through this path.

#### Scenario: Unpriceable asset blocks coverage

- **WHEN** `coverageUsd` is called for an asset with no configured feed
- **THEN** it reverts `FeedNotConfigured` — a proposal in an unpriceable asset cannot be coverage-checked

#### Scenario: Stale asset feed blocks coverage

- **WHEN** the asset feed's answer is non-positive or older than `maxDelay`
- **THEN** `coverageUsd` reverts `StalePrice`

#### Scenario: Approval hook degrades instead of reverting

- **WHEN** `recordApproval` runs for a vault whose asset pricing fails (no feed or stale)
- **THEN** the guardian books zero exposure and the vote succeeds — the coverage shortfall surfaces at the execute-time quorum, not as an un-castable Approve vote

### Requirement: Coverage epochs are a fixed wall-clock schedule

The `ExposureLedger` SHALL derive coverage epochs from an immutable schedule: `epochLength` is set at construction (non-zero; 28 days initial per design §5), `epochGenesis` is the deployment timestamp, and `currentEpoch() = (block.timestamp - epochGenesis) / epochLength`. Guardian exposure SHALL be bucketed by epoch so that open exposure counts only buckets whose challenge window has not elapsed — bounding each commitment at one epoch plus the challenge window regardless of strategy duration. See `openspec/specs/exposure-ledger/spec.md` for the bucket accounting itself.

#### Scenario: Epoch index advances on wall clock

- **WHEN** `epochLength` seconds elapse from `epochGenesis`
- **THEN** `currentEpoch()` increments by exactly one, independent of any protocol activity

#### Scenario: Zero epoch length is undeployable

- **WHEN** the ledger is constructed with `epochLength_ == 0`
- **THEN** construction reverts `InvalidParameter`

### Requirement: Bounded duration substitutes for per-epoch NAV checkpointing in v1

The protocol SHALL NOT record per-epoch NAV checkpoints on-chain in v1. Instead, `ProtocolConfig.maxStrategyDuration` SHALL impose a protocol-wide ceiling on `strategyDuration` (clamping every vault's own maximum), so a single guardian commitment spans the whole risk window and the drawdown predicate (predicate 5, `DrawdownBreach`) is enforceable at settlement without renewal, NAV checkpointing or claims-made attribution. The setter SHALL be owner-only and SHALL reject a non-zero value below 1 day; zero means "no protocol ceiling" (preserving pre-parameter deployments) and changes never rebind in-flight proposals, which snapshot parameters at propose time. In the challenge game the drawdown predicate is a label carried in the filing event — no contract derives it from on-chain NAV records.

#### Scenario: Degenerate ceiling rejected

- **WHEN** the owner sets `maxStrategyDuration` to a non-zero value below 1 day
- **THEN** the call reverts `InvalidMaxStrategyDuration`

#### Scenario: In-flight proposals keep their snapshot

- **WHEN** the ceiling changes while a proposal is live
- **THEN** only proposals created afterwards see the new ceiling

### Requirement: Hardened Chainlink USD reads (library contract)

The `ChainlinkReader` library's `readUsd(feed, sequencerUptimeFeed, maxDelay, gracePeriod)` SHALL provide a fully fail-closed USD read for any consumer that adopts it:

- revert `SequencerDown` when the L2 sequencer-uptime feed reports the sequencer down,
- revert `GracePeriodNotOver` when the sequencer round is uninitialized (`startedAt == 0`), started in the future, or restarted within `gracePeriod`,
- revert `StaleOracle` when the price answer is `<= 0`, `answeredInRound < roundId`, `startedAt == 0`, or the answer's age exceeds `maxDelay` (a future `updatedAt` counts as age 0).

No production contract currently consumes this library (the `ExposureLedger` uses its own inline reads, and Robinhood Chain 4663 has no sequencer-uptime feed — an accepted v1 risk); its guarantees bind any future adapter that adopts it.

#### Scenario: Sequencer restart within grace fails closed

- **WHEN** the sequencer-uptime feed reports up but the restart happened within `gracePeriod`
- **THEN** `readUsd` reverts `GracePeriodNotOver`

#### Scenario: Incomplete round fails closed

- **WHEN** the price feed reports `answeredInRound < roundId` or `startedAt == 0`
- **THEN** `readUsd` reverts `StaleOracle`
