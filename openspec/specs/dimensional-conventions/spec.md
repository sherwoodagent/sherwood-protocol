# Dimensional Conventions Specification

## Purpose

The dimensional vocabulary for the guardian / insurance layer, expressed as enforceable conventions. Every bug this vocabulary exists to expose has one shape: two quantities of identical Solidity type and precision where only one is correct, with no compiler check between them (`USD18{reserved}` vs `USD18{allocated}`; `WOOD{votable}` vs `WOOD{liability}`; the raw governance WOOD scalar vs the feed-composed price; vote weight vs raw stake). Where this spec disagrees with the source code, the code wins — this is a reading of the code, not a check the code is run against. Anchors are symbol names, never line numbers.
## Requirements
### Requirement: Notation
Dimensional annotations SHALL use the form `<PREFIX>{<unit>}` — e.g. `D18{USD}` is a USD amount carried as an integer scaled by `1e18`. A brace tag after a unit (`WOOD{liability}`) SHALL mark a SEMANTIC subtype: same integer scale, NOT interchangeable with sibling subtypes.

#### Scenario: Semantic subtype crossing
- **WHEN** arithmetic combines two quantities whose annotations differ only in the brace tag (e.g. `WOOD{votable}` + `WOOD{liability}`)
- **THEN** the site is a dimensional violation unless it is one of the documented conversion points — the identical Solidity type is exactly why review must catch it

### Requirement: USD amounts are 18-decimal WAD
Dollar values (`{USD}`) SHALL always be carried as `D18{USD}` in this layer, and SHALL be produced only by `ExposureLedger.coverageUsd` (asset → USD) and the WOOD → USD lifts `_slashableBondUsd` and `_recoverableUsd`. Carriers: `coverageUsd`, `coveredTvlCapUsd`, `slashableBondUsd`, `liabilityUsd`, `unsharedLiabilityUsd`, `coverageUsdOf`, `requireApproveQuorum`'s returned pair, and `ChallengeGame`'s `frozenCoverageUsd`.

#### Scenario: USD produced anywhere else
- **WHEN** a new site synthesizes a USD amount without going through `coverageUsd`, `_slashableBondUsd` or `_recoverableUsd`
- **THEN** it is a violation — those are the only places asset/WOOD quantities are lifted to `D18{USD}`

### Requirement: WOOD amounts are 18-decimal wei of a plain ERC20
`{WOOD}` quantities SHALL be WOOD wei (18 decimals), and WOOD SHALL be assumed a plain ERC20 — no fee-on-transfer, no rebasing. Carriers: `Guardian.stakedAmount`, `totalGuardianStake`, `minGuardianStake`, `minOwnerStake`, `LockRecord.wood`, the ledger's epoch `_buckets`, `openExposure`, `bondWood`, `bondedWood`, `totalStakeAtFiling`, `convictWeight`, `acquitWeight`.

#### Scenario: Non-plain token substituted
- **WHEN** a fee-on-transfer or rebasing token is used where `{WOOD}` is expected
- **THEN** escrow accounting invariants (e.g. `ChallengeGame.bondedWood` vs the game's actual balance) break — the plain-ERC20 assumption is load-bearing

### Requirement: Asset amounts stay in the asset's own decimals
`{ASSET}` — a vault's underlying ERC-20 — SHALL be carried in THAT ASSET'S OWN decimals (USDC 6, WETH 18) and SHALL never be normalized on its own; only `coverageUsd` lifts it to `D18{USD}` using the cached `AssetFeed.assetDecimals`. Carriers: `SyndicateVault.totalAssets`, `asset()` balances, and `SyndicateGovernor`'s `envelope.maxCapital`, per-call caps and `requiredCoverage`.

#### Scenario: Premature normalization
- **WHEN** code scales an `{ASSET}` amount to 18 decimals before handing it to `coverageUsd`
- **THEN** the USD lift double-scales — `{ASSET}` values must flow raw until the single lift point

### Requirement: Share decimals are twice the asset decimals
`{SHARE}` — ERC-4626 shares of a `SyndicateVault` — SHALL have decimals `assetDecimals + _decimalsOffset()`, where `_decimalsOffset()` RETURNS THE ASSET'S DECIMALS (stamped once into `_cachedDecimalsOffset` at `initialize`). Share decimals are therefore **2 × assetDecimals** — 12 dp on USDC, not 18 + 6.

#### Scenario: Assuming 18-decimal shares
- **WHEN** code treats a USDC-vault share amount as 18-decimal
- **THEN** it is off by `1e6` — the correct scale is `D12` (2 × 6)

### Requirement: Generic token amounts use runtime decimals
`{TOK}` — a generic external ERC-20 — SHALL be carried in its own `decimals()` (`PortfolioStrategy._tokenDecimals`, swap-adapter `amountIn`/`amountOutMinimum`), resolved at runtime, never assumed.

#### Scenario: Hardcoded token scale
- **WHEN** a swap amount is computed with a literal `1e18` for a token whose `decimals()` is not 18
- **THEN** the amount is mis-scaled — `{TOK}` sites must read `IERC20Metadata.decimals()`

### Requirement: Time quantities are seconds
`{s}` quantities SHALL be seconds: `block.timestamp`, `epochLength`, `challengeWindow`, `reviewPeriod`, `maturationPeriod`, `voteWindow`, `voteWindowAtFiling`, `MIN_VOTE_WINDOW`, the governor's `365 days` year in the management fee, `elapsed`, `age`.

#### Scenario: Window comparison
- **WHEN** a window is compared against its bound or its deadline (e.g. `voteWindow >= MIN_VOTE_WINDOW`, `block.timestamp >= filedAt + voteWindowAtFiling`)
- **THEN** every operand is `{s}` — no mixed units enter the inequality

### Requirement: Basis points carry a 10_000 denominator
`{bps}` quantities SHALL be basis points with denominator `BPS_DENOMINATOR = 10_000`, declared independently in `ProposalLifecycle`, `GovernorParameters`, `FeeConstants`, `ExposureLedger`, `GuardianRegistry`, `ChallengeGame`, `PortfolioStrategy` and `ConcentratedLiquidityStrategy`. Carriers: `proposerBondBps`, `woodHaircutBps`, `minSlashBps`, `maxSlashBps`, `ageFloorBps`, `challengerBondBps`, `forfeitBurnBps`, `settleBurnBps`, `prosecutorFeeBps`, `challengeQuorumBps`, `maxSlippageBps`.

#### Scenario: bps applied without the denominator
- **WHEN** a `{bps}` value multiplies a quantity without a `/ 10_000`
- **THEN** the result is 10,000× too large — every bps application must divide by the declared denominator

### Requirement: Dimensionless scalars are distinct from bps
`{1}` — dimensionless scalars with no bps denominator — SHALL NOT be confused with `{bps}`: `kNumerator`, `epoch` index, `MAX_SCAN_BUCKETS`, `MAX_APPROVERS_PER_PROPOSAL`, `_frozenCommitments` (a COUNT, deliberately not a sum), `_frozenKeyCount`, `envelopeTier` (ordinal 0..2).

#### Scenario: Count summed as USD
- **WHEN** `_frozenCommitments` is treated as a WOOD or USD total rather than a count
- **THEN** it is a violation — the count is deliberately not a sum

### Requirement: The composed WOOD price and the raw scalar are different quantities
`D8{USD/WOOD}` (`priceX8`) SHALL be the WOOD price normalized to 8 decimals via `(uint256(answer) * 1e8) / (10 ** f.feedDecimals)`. `woodPriceX8()` SHALL be `haircut(min(feedX8, woodUsdPriceX8))`, floored at 1: the governance-set `woodUsdPriceX8` is an UPPER CAP only. It is never served as a price and there is no fallback: a stale, unset or non-positive feed, or a zero cap, reverts `NoWoodPrice`. A cap set below market binds on every read and understates every bond valued at `woodPriceX8()`. The raw storage scalar `woodUsdPriceX8` and the composed `woodPriceX8()` (feed-derived, capped, haircut-applied) are DIFFERENT QUANTITIES at the same precision and SHALL NOT be substituted: `ChallengeGame.file` prices the challenger bond with `woodPriceX8()` so the bond and the slash rails share a basis — it previously read the raw scalar, and that mismatch was the bug.

#### Scenario: Bond priced off the raw scalar
- **WHEN** any slash-coupled figure reads `woodUsdPriceX8` directly instead of `woodPriceX8()`
- **THEN** the bond and the slash rails diverge whenever the feed is live — the composed accessor is the only valid basis

#### Scenario: No market source
- **WHEN** the WOOD feed is stale or unset while `woodUsdPriceX8` is non-zero
- **THEN** `woodPriceX8()` reverts `NoWoodPrice`; the cap is not used as a price

### Requirement: Feed prices use the feed's own decimals
`Dn{USD/TOK}` — a raw Chainlink `answer` — SHALL be interpreted at the feed's own `decimals()` (`AssetFeed.feedDecimals`, `PortfolioStrategy._priceDecimals`). 18 or 8 SHALL NEVER be assumed: `PortfolioStrategy` supports 8 (tokenized stocks) and 18 (crypto).

#### Scenario: Hardcoded feed decimals
- **WHEN** a conversion assumes an 8-decimal feed for a token whose feed reports 18
- **THEN** values are off by `1e10` — the feed's `decimals()` must be read and applied dynamically

### Requirement: Vault conversion rate is a frozen num/den pair
The `{ASSET}/{SHARE}` vault conversion rate SHALL be materialized as the frozen settlement pair `num = totalAssets() + 1` (an `{ASSET}` quantity), `den = _pricingSupply() + 10 ** offset` (a `{SHARE}` quantity, total supply less the shares of earlier stamped-but-unclaimed redeems), consumed by `VaultWithdrawalQueue` as `mulDiv(shares, num, den)`.

#### Scenario: Live-rate substitution
- **WHEN** a queued withdrawal is settled against the live conversion rate instead of the frozen pair
- **THEN** later vault activity changes the payout — the frozen pair exists so it cannot

### Requirement: Per-approver slash rate rounds up and is positional
`bps{slash}` (`slashBpsFor`) SHALL be `ceil(lock × 10_000 / slash basis)` for every approver holding a lock, saturating at 10_000 when the lock meets or exceeds the basis or the basis is zero, and 0 for a zero lock; `StakedWood.slashVerdict` clamps each non-zero rate into `[minSlashBps, maxSlashBps]`. Both the lock and the basis are `{WOOD}`, so the rate reads no price. It SHALL be consumed POSITIONALLY by `StakedWood.slashVerdict`: alignment with the approver array is load-bearing.

#### Scenario: Array misalignment
- **WHEN** the slash-bps array order diverges from the approver array order
- **THEN** guardians are slashed at each other's rates — the positional contract is part of the unit

### Requirement: Age factor is a linear bps ramp
`bps{age}` (`_ageFactorBps`) SHALL be a linear ramp from `ageFloorBps` at age 0 to `10_000` at `maturationPeriod`.

#### Scenario: Young stake weighting
- **WHEN** a guardian's stake has age 0
- **THEN** its aged weight is `ageFloorBps / 10_000` of raw stake, growing linearly to full weight at maturation

### Requirement: Vote weight is not spendable WOOD and not the slash basis
`WOOD{voteWeight}` (`getPastVotes`) SHALL be aged own stake: the raw own-stake checkpoint times the age factor. There is no delegated component. It is WOOD-scaled but NOT spendable WOOD and NOT the slash basis. `getPastStake` returns the raw, un-aged trace, and is the weight guardian review, emergency and challenge ballots use; subtracting one trace from the other is a basis error.

#### Scenario: Mixing aged and raw traces
- **WHEN** code computes `getPastVotes(...) - getPastStake(...)` or otherwise combines the two traces arithmetically
- **THEN** it is a basis error — one is aged, the other raw

### Requirement: Liability and votable checkpoints are distinct traces
`WOOD{liability}` and `WOOD{votable}` SHALL be maintained as two distinct checkpoint traces on the same guardian: `_liabilityCheckpoints` is NOT zeroed by `requestUnstakeGuardian`; `_stakeCheckpoints` is. The slash basis (`StakedWood._slashableAt`, shared by `_slashOne` and `slashableStakeAt`) SHALL take `Math.max` of the two, capped by live stake. Substituting the votable trace for the liability trace would let an exiting guardian escape a slash it already owed.

#### Scenario: Exiting guardian slashed correctly
- **WHEN** a guardian who requested unstake (votable trace zeroed) is slashed for a pre-exit approval
- **THEN** the slash reads the liability trace via `Math.max` and lands — reading the votable trace alone would find zero

### Requirement: The two epoch clocks are not comparable
`{epoch}` SHALL be a dimensionless bucket index, `(block.timestamp - epochGenesis) / epochLength`. Two independent epoch clocks exist and SHALL NOT be compared or mixed: `ExposureLedger.epochLength` (immutable) and `GuardianRegistry.EPOCH_DURATION` (7 days).

#### Scenario: Cross-clock epoch arithmetic
- **WHEN** an `ExposureLedger` epoch index is compared with a `GuardianRegistry` epoch index
- **THEN** it is a violation — same word, different genesis and length, incommensurable

### Requirement: Precision prefixes
The precision vocabulary SHALL be: `D6` = `1e6` (USDC/USDT native decimals); `D8` = `1e8` (Chainlink USD feeds and the canonical `priceX8` WOOD price); `D12` = `1e12` (`SyndicateVault` share decimals when the asset is USDC — derived as 2 × assetDecimals, never a literal in source); `D18` = `1e18` (`WAD` — WOOD wei and all USD coverage/liability/bond values); `BPS` = `10_000` (`BPS_DENOMINATOR`, declared separately in eight contracts); `Dn` (dynamic) = `10 ** decimals`, resolved at runtime from `IERC20Metadata.decimals()` or `IAggregatorV3.decimals()` (feed decimals bounded at 18 by `ExposureLedger` and `WoodPoolFeed`, at 36 by `PortfolioStrategy`). Any site that hard-codes `1e18` or `1e8` where a dynamic `Dn` is required SHALL be treated as a scaling bug.

#### Scenario: D12 as a literal
- **WHEN** `1e12` appears as a literal for USDC-vault share scale
- **THEN** it is a violation — `D12` is derived (2 × assetDecimals), never written as a constant

#### Scenario: Static scale where Dn is required
- **WHEN** a conversion hard-codes `1e8` for a feed whose `decimals()` is dynamic
- **THEN** it is a scaling bug — the scale must come from the runtime `decimals()` read

### Requirement: A guardian's exposure to a proposal is one WOOD lock
Each approver's exposure to a proposal SHALL be a single `{WOOD}` figure, `LockRecord.wood`, written once by `recordApproval` as `min(declared lock, kNumerator × guardianStake − openExposure)` and erased only by release or retirement. It is at once the guardian's booking (summed into the epoch `_buckets` that `openExposure` scans), its pledge and its slash base. There is no USD reservation and no pro-rata allocation. USD enters only when a lock is valued: `min(lock, slash basis) × woodPriceX8() / 1e8`.

#### Scenario: Valuing a lock
- **WHEN** a coverage, liability or quorum read values an approver
- **THEN** it reads the WOOD lock and the WOOD slash basis, takes the smaller, and lifts that to USD at the composed WOOD price

### Requirement: Recoverable-value ladder
The derived quantities SHALL compose as follows, and substitutions between rungs are basis errors:
- `WOOD{basis}` = `swood.slashableStakeAt(g, anchor)` — `min(max(liability, votable) one second before the anchor, live stake)` — or live `guardianStake` where no anchor applies.
- `USD18{recoverable}` = `min(WOOD{lock}, WOOD{basis}) × D8{USD/WOOD} / 1e8` per guardian (`_recoverableUsd`) — what a conviction could actually take.
- `USD18{need}` = required coverage, `coverageUsd(asset, requiredCoverage)`, re-derived from the LIVE feed at each read — two reads at different timestamps are not the same number.
- `WOOD{budget}` = `kNumerator × guardianStake`, the per-guardian batching cap; `free = budget − openExposure`, all in WOOD.
- `USD18{liability}` = `min(USD18{need}, Σ USD18{recoverable})`, the cohort's recoverable exposure on one proposal and the basis a challenger bond is sized against.

#### Scenario: Caching the need across time
- **WHEN** `USD18{need}` read at propose time is reused at execute time as if equal
- **THEN** the comparison is invalid — the need is feed-live and must be re-derived at each consumption point

### Requirement: Portfolio conversions use dynamic decimals
`PortfolioStrategy` token↔value conversions (`_tokensToValue`, `_valueToTokens`) SHALL scale by `10 ** (tokenDecimals + priceDecimals)` against the cached asset decimals; no fixed price-precision constant exists.

#### Scenario: Conversion through a fixed constant
- **WHEN** a token↔value conversion divides by a fixed `1e18` instead of the dynamic `10 ** (tokenDecimals + priceDecimals)` form
- **THEN** it mis-scales every token/feed pair whose decimals differ from the nominal case

