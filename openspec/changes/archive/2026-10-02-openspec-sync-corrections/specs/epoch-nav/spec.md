## MODIFIED Requirements

### Requirement: Coverage epochs are a fixed wall-clock schedule

The `ExposureLedger` SHALL derive coverage epochs from an immutable schedule: `epochLength` is set at construction (non-zero; 28 days on the Robinhood deployment), `epochGenesis` is the deployment timestamp, and `currentEpoch() = (block.timestamp - epochGenesis) / epochLength`. Each guardian lock SHALL be booked into the epoch containing the proposal's `executeBy + strategyDuration` (at most `MAX_COVERAGE_HORIZON`, 60 days, ahead) and SHALL count toward open exposure until that epoch's end plus the challenge window. The bucket accounting itself is specified by the guardian-coverage capability ("Epoch-bucketed exposure accounting").

#### Scenario: Epoch index advances on wall clock

- **WHEN** `epochLength` seconds elapse from `epochGenesis`
- **THEN** `currentEpoch()` increments by exactly one, independent of any protocol activity

#### Scenario: Zero epoch length is undeployable

- **WHEN** the ledger is constructed with `epochLength_ == 0`
- **THEN** construction reverts `InvalidParameter`

## ADDED Requirements

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

## REMOVED Requirements

### Requirement: WOOD is priced feed-first with a maintained governance fallback
**Reason**: There is no fallback and no `woodPriceDetail()`. `woodPriceX8()` is `haircut(min(feed, woodUsdPriceX8))` and reverts `NoWoodPrice` without a fresh feed or with a zero cap.
**Migration**: guardian-coverage "WOOD is priced by the feed, capped by governance, with no fallback".

### Requirement: WOOD feed wiring is explicit in both directions
**Reason**: A cleared feed leaves WOOD unpriced; it does not return pricing to a fallback.
**Migration**: Replaced by "WOOD feed wiring and clearing".

### Requirement: The governance WOOD price is rate-limited upward only
**Reason**: `setWoodUsdPrice` has no update interval and no size ceiling; rate limiting is enforced off-chain.
**Migration**: guardian-coverage "The WOOD price cap has no on-chain rate limit" and deployment-docs "Rate limiting is enforced off-chain, and the contract imposes none".

### Requirement: The WOOD haircut is floored, capped and rate-limited
**Reason**: `setWoodHaircutBps` has no update interval.
**Migration**: guardian-coverage "WOOD haircut is bounded".

### Requirement: Vault-asset pricing fails closed on staleness
**Reason**: It contrasted the asset feed with a fail-degraded WOOD price that no longer exists, and said an approval degrades on an unpriceable asset; it reverts.
**Migration**: Replaced by "Vault-asset pricing fails closed".

### Requirement: Hardened Chainlink USD reads (library contract)
**Reason**: No `ChainlinkReader` library exists in the source.
**Migration**: None.
