# Dimensional Conventions Specification

## Purpose

The dimensional vocabulary for the guardian / insurance layer, expressed as enforceable conventions. Every bug this vocabulary exists to expose has one shape: two quantities of identical Solidity type and precision where only one is correct, with no compiler check between them (`USD18{reserved}` vs `USD18{allocated}`; `WOOD{votable}` vs `WOOD{liability}`; the raw governance WOOD scalar vs the feed-composed price; vote weight vs raw stake). Where this spec disagrees with the source code, the code wins — this is a reading of the code, not a check the code is run against. Anchors are symbol names, never line numbers.

## Requirements

### Requirement: Notation
Dimensional annotations SHALL use the form `<PREFIX>{<unit>}` — e.g. `D18{USD}` is a USD amount carried as an integer scaled by `1e18`. A brace tag after a unit (`USD18{reserved}`) SHALL mark a SEMANTIC subtype: same integer scale, NOT interchangeable with sibling subtypes.

#### Scenario: Semantic subtype crossing
- **WHEN** arithmetic combines two quantities whose annotations differ only in the brace tag (e.g. `USD18{reserved}` + `USD18{allocated}`)
- **THEN** the site is a dimensional violation unless it is one of the documented conversion points — the identical Solidity type is exactly why review must catch it

### Requirement: USD amounts are 18-decimal WAD
Dollar values (`{USD}`) SHALL always be carried as `D18{USD}` in this layer, and SHALL be produced only by `ExposureLedger.coverageUsd` and `_slashableBondUsd`. Carriers: `coverageUsd`, `coveredTvlCapUsd`, `openExposureUsd`, `slashableBondUsd`, `liabilityUsd`, `allocatedUsd`, `frozenCoverageUsd`, `_committedUsd`, `_buckets`, `RecordedExposure.usd` (`uint192`).

#### Scenario: USD produced anywhere else
- **WHEN** a new site synthesizes a USD amount without going through `coverageUsd` / `_slashableBondUsd`
- **THEN** it is a violation — the two producers are the only places asset/WOOD quantities are lifted to `D18{USD}`

### Requirement: WOOD amounts are 18-decimal wei of a plain ERC20
`{WOOD}` quantities SHALL be WOOD wei (18 decimals), and WOOD SHALL be assumed a plain ERC20 — no fee-on-transfer, no rebasing (asserted in `CompensationEscrow`'s header). Carriers: `Guardian.stakedAmount`, `totalGuardianStake`, `minGuardianStake`, `minOwnerStake`, `bondWood`, `counterBondWood`, `bondedWood`, `forfeitedWood`, `unclaimedWood`, `Case.proceeds`, `Case.redeemed`, `totalEscrowed`.

#### Scenario: Non-plain token substituted
- **WHEN** a fee-on-transfer or rebasing token is used where `{WOOD}` is expected
- **THEN** escrow accounting invariants (e.g. `totalEscrowed` vs actual balance) break — the plain-ERC20 assumption is load-bearing

### Requirement: Asset amounts stay in the asset's own decimals
`{ASSET}` — a vault's underlying ERC-20 — SHALL be carried in THAT ASSET'S OWN decimals (USDC 6, WETH 18) and SHALL never be normalized on its own; only `coverageUsd` lifts it to `D18{USD}` using the cached `AssetFeed.assetDecimals`. Carriers: `SyndicateVault.totalAssets`, `asset()` balances, `SyndicateGovernor`'s `envelope.maxCapital` and `requiredCoverage`, strategy `nav()`.

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
`{s}` quantities SHALL be seconds: `block.timestamp`, `epochLength`, `challengeWindow`, `reviewPeriod`, `maturationPeriod`, `autoSlashDelay`, `disputeTimeout`, `voteWindow`, `SECONDS_PER_YEAR`, `elapsed`, `age`.

#### Scenario: Window comparison
- **WHEN** cross-contract window invariants are checked (e.g. `autoSlashDelay + voteWindow + FINALIZE_BUFFER <= disputeTimeout`)
- **THEN** every operand is `{s}` — no mixed units enter the inequality

### Requirement: Basis points carry a 10_000 denominator
`{bps}` quantities SHALL be basis points with denominator `BPS_DENOMINATOR = 10_000`, declared independently in `ExposureLedger`, `GuardianRegistry`, `ChallengeGame` and `TokenCourt`. Carriers: `proposerBondBps`, `woodHaircutBps`, `maxDelegatedSlashBps`, `minSlashBps`, `maxSlashBps`, `ageFloorBps`, `challengerBondBps`, `forfeitBurnBps`, `settleBurnBps`, `inconclusiveBurnBps`, `participationFloorBps`, `convictionBountyBps`, `maxSlippageBps`.

#### Scenario: bps applied without the denominator
- **WHEN** a `{bps}` value multiplies a quantity without a `/ 10_000`
- **THEN** the result is 10,000× too large — every bps application must divide by the declared denominator

### Requirement: Dimensionless scalars are distinct from bps
`{1}` — dimensionless scalars with no bps denominator — SHALL NOT be confused with `{bps}`: `kNumerator`, `delegatedWeightCapX`, `epoch` index, `MAX_SCAN_BUCKETS`, `MAX_APPROVERS_PER_PROPOSAL`, `_frozenCommitments` (a COUNT, deliberately not a USD sum), `_frozenKeyCount`, `envelopeTier` (ordinal 0..3).

#### Scenario: Count summed as USD
- **WHEN** `_frozenCommitments` is treated as a USD total rather than a count
- **THEN** it is a violation — the count is deliberately not a USD sum

### Requirement: Reservation and allocation are never interchangeable
`USD18{reserved}` and `USD18{allocated}` are both `D18{USD}` `uint256`s in `ExposureLedger` and SHALL NOT be interchanged. A RESERVATION is what a guardian booked at approve time — `min(free budget, the proposal's FULL required coverage)` (`recordApproval`) — so every approver reserves up to the whole need and `sum(reserved) = A × needUsd` for A well-funded approvers: reservations SUM ABOVE the need, by a factor that GROWS WITH THE APPROVER COUNT. An ALLOCATION is what a guardian actually owes: the need split pro-rata by EFFECTIVE bond, so `sum(allocated) <= needUsd` (rounds down; `settleCoverage` hands the residue to the first holder). Reservation carriers: `RecordedExposure.usd`, `_committedUsd`, `_buckets`, `approversOf(...).committedUsd`, `openExposureUsd`, and the `haveUsd` sum inside `requireApproveQuorum` (correctly reservation-typed — summing allocations there would be circular and fail on truncation dust). Allocation producers/readers: `_allocate`, `allocatedUsd`, `slashBpsFor`, `liabilityUsd`. Two real bugs this rule exists to catch are recorded in source comments: `ChallengeGame.file()` once summed `approversOf` (the RESERVATION) to size a challenger bond while every slash prices the ALLOCATION; and `slashBpsFor`'s note that slashing the reservation "would take the whole coverage from EVERY approver".

#### Scenario: Sizing a bond off reservations
- **WHEN** a challenger bond (or any slash-priced figure) is computed from `approversOf(...).committedUsd`
- **THEN** it over-states exposure by up to the approver count — the correct basis is the allocation (`liabilityUsd` / `allocatedUsd`)

#### Scenario: Correct reservation use in the quorum
- **WHEN** `requireApproveQuorum` sums `haveUsd` over approvers
- **THEN** reservation-typing is correct there — it asks "did enough get booked", not "who owes what"

### Requirement: Effective-value ladder
The derived USD quantities SHALL compose as follows, and substitutions between rungs are basis errors:
- `USD18{effective}` = `min(USD18{reserved}, USD18{bond})` per guardian — what it can ACTUALLY pay, not what it pledged. The shared basis of `requireApproveQuorum`, `allocatedUsd`, `slashBpsFor` and `settleCoverage`.
- `USD18{effectiveTotal}` = sum of `USD18{effective}` over a proposal's approvers (`_effectiveTotal`) — the pro-rata DENOMINATOR. Using raw `_committedUsd` here is a known wrong substitution.
- `USD18{need}` = required coverage, `coverageUsd(asset, requiredCoverage)`, re-derived from the LIVE feed at each read — two reads at different timestamps are not the same number.
- `USD18{bond}` = `slashableBondUsd(g)`, composed as `{WOOD} × D8{USD/WOOD} / 1e8`.
- `USD18{budget}` = `kNumerator × USD18{bond}`, the per-guardian batching cap; `free = budget − USD18{open}`.
- `USD18{liability}` = `min(USD18{need}, USD18{effectiveTotal})`, the cohort's real exposure on one proposal and the basis a challenger bond is sized against.

#### Scenario: Raw committed as denominator
- **WHEN** a pro-rata split divides by `_committedUsd` instead of `_effectiveTotal`
- **THEN** guardians whose bond collapsed below their reservation are over-allocated — the denominator must be effective, not pledged

#### Scenario: Caching the need across time
- **WHEN** `USD18{need}` read at propose time is reused at execute time as if equal
- **THEN** the comparison is invalid — the need is feed-live and must be re-derived at each consumption point

### Requirement: The composed WOOD price and the raw scalar are different quantities
`D8{USD/WOOD}` (`priceX8`) SHALL be the WOOD price normalized to 8 decimals via `(uint256(answer) * 1e8) / (10 ** f.feedDecimals)`, then multiplied by `woodHaircutBps / 10_000`. `woodPriceX8()` is feed-first with the governance-set `woodUsdPriceX8` as the degraded fallback. The raw storage scalar `woodUsdPriceX8` (a conservative governance floor) and the composed `woodPriceX8()` (feed-derived, haircut-applied) are DIFFERENT QUANTITIES at the same precision and SHALL NOT be substituted: `ChallengeGame.file` prices the challenger bond with `woodPriceX8()` so the bond and the slash rails share a basis — it previously read the raw scalar, and that mismatch was the bug.

#### Scenario: Bond priced off the raw scalar
- **WHEN** any slash-coupled figure reads `woodUsdPriceX8` directly instead of `woodPriceX8()`
- **THEN** the bond and the slash rails diverge whenever the feed is live — the composed accessor is the only valid basis

### Requirement: Feed prices use the feed's own decimals
`Dn{USD/TOK}` — a raw Chainlink `answer` — SHALL be interpreted at the feed's own `decimals()` (`AssetFeed.feedDecimals`, `PortfolioStrategy._priceDecimals`). 18 or 8 SHALL NEVER be assumed: `PortfolioStrategy` supports 8 (tokenized stocks) and 18 (crypto).

#### Scenario: Hardcoded feed decimals
- **WHEN** a conversion assumes an 8-decimal feed for a token whose feed reports 18
- **THEN** values are off by `1e10` — the feed's `decimals()` must be read and applied dynamically

### Requirement: PRICE_PRECISION is a legacy anchor only
`D18{USD/TOK}` (`PRICE_PRECISION = 1e18`) is `PortfolioStrategy`'s nominal price scale and SHALL be treated as a legacy anchor only. Per the Sherlock #21/#29 fix, real conversions SHALL use `10 ** (tokenDecimals + priceDecimals)` against the cached `assetDecimals` (`_tokensToValue` / `_valueToTokens`), NOT the constant.

#### Scenario: Conversion through the constant
- **WHEN** a token↔value conversion divides by `PRICE_PRECISION` instead of the dynamic `10 ** (tokenDecimals + priceDecimals)` form
- **THEN** it reintroduces the Sherlock #21/#29 scaling bug for any token/feed pair whose decimals differ from the nominal case

### Requirement: Vault conversion rate is a frozen num/den pair
The `{ASSET}/{SHARE}` vault conversion rate SHALL be materialized as the frozen settlement pair `num = totalAssets() + 1` (an `{ASSET}` quantity), `den = totalSupply() + 10 ** offset` (a `{SHARE}` quantity), consumed by `VaultWithdrawalQueue` as `mulDiv(shares, num, den)`.

#### Scenario: Live-rate substitution
- **WHEN** a queued withdrawal is settled against the live conversion rate instead of the frozen pair
- **THEN** later vault activity changes the payout — the frozen pair exists so it cannot

### Requirement: Per-approver slash rate rounds up and is positional
`bps{slash}` SHALL be `ceil(USD18{allocated} × 10_000 / USD18{bond})`, clamped to `10_000` (`slashBpsFor`) — rounding UP toward the protocol. It SHALL be consumed POSITIONALLY by `StakedWood.slashToEscrow`: alignment with the approver array is load-bearing.

#### Scenario: Array misalignment
- **WHEN** the slash-bps array order diverges from the approver array order
- **THEN** guardians are slashed at each other's rates — the positional contract is part of the unit

### Requirement: Age factor is a linear bps ramp
`bps{age}` (`_ageFactorBps`) SHALL be a linear ramp from `ageFloorBps` at age 0 to `10_000` at `maturationPeriod`.

#### Scenario: Young stake weighting
- **WHEN** a guardian's stake has age 0
- **THEN** its aged weight is `ageFloorBps / 10_000` of raw stake, growing linearly to full weight at maturation

### Requirement: Vote weight is not spendable WOOD and not the slash basis
`WOOD{voteWeight}` (`getPastVotes`) SHALL be aged own stake plus delegated inbound, capped at `delegatedWeightCapX × agedOwn`. It is WOOD-scaled but NOT spendable WOOD and NOT the slash basis. `getPastStake` returns the raw, un-aged trace; subtracting one from the other is a basis error.

#### Scenario: Mixing aged and raw traces
- **WHEN** code computes `getPastVotes(...) - getPastStake(...)` or otherwise combines the two traces arithmetically
- **THEN** it is a basis error — one is aged-and-capped, the other raw

### Requirement: Liability and votable checkpoints are distinct traces
`WOOD{liability}` and `WOOD{votable}` SHALL be maintained as two distinct checkpoint traces on the same guardian: `_liabilityCheckpoints` is NOT zeroed by `requestUnstakeGuardian`; `_stakeCheckpoints` is. `_slashOne` SHALL take `Math.max` of the two. Substituting the votable trace for the liability trace is the PR #25 F1b bug — an exiting guardian would escape a slash it already owed.

#### Scenario: Exiting guardian slashed correctly
- **WHEN** a guardian who requested unstake (votable trace zeroed) is slashed for a pre-exit approval
- **THEN** the slash reads the liability trace via `Math.max` and lands — reading the votable trace alone would find zero

### Requirement: Compensation apportionment uses a cached snapshot supply
`SHARE{votes}` — vault `ERC20Votes` weight at a past timestamp — SHALL be the compensation apportionment numerator: `proceeds × votes / snapshotSupply` yields `{WOOD}` (`CompensationEscrow`), with `Case.snapshotSupply` cached at case open so a past snapshot cannot change.

#### Scenario: Live supply in the denominator
- **WHEN** apportionment divides by the live total supply instead of the cached `Case.snapshotSupply`
- **THEN** post-open mints/burns distort every claim — the cache exists to freeze the denominator

### Requirement: The two epoch clocks are not comparable
`{epoch}` SHALL be a dimensionless bucket index, `(block.timestamp - epochGenesis) / epochLength`. Two independent epoch clocks exist and SHALL NOT be compared or mixed: `ExposureLedger.epochLength` (immutable) and `GuardianRegistry.EPOCH_DURATION` (7 days).

#### Scenario: Cross-clock epoch arithmetic
- **WHEN** an `ExposureLedger` epoch index is compared with a `GuardianRegistry` epoch index
- **THEN** it is a violation — same word, different genesis and length, incommensurable

### Requirement: Precision prefixes
The precision vocabulary SHALL be: `D6` = `1e6` (USDC/USDT native decimals); `D8` = `1e8` (Chainlink USD feeds and the canonical `priceX8` WOOD price); `D12` = `1e12` (`SyndicateVault` share decimals when the asset is USDC — derived as 2 × assetDecimals, never a literal in source); `D18` = `1e18` (`WAD` — WOOD wei, all USD coverage/liability/bond values, `PRICE_PRECISION`, `MIN_COHORT_STAKE_AT_OPEN`); `BPS` = `10_000` (`BPS_DENOMINATOR`, declared separately in four contracts); `Dn` (dynamic) = `10 ** decimals`, resolved at runtime from `IERC20Metadata.decimals()` or `IAggregatorV3.decimals()` (bounded at 36). Any site that hard-codes `1e18` or `1e8` where a dynamic `Dn` is required SHALL be treated as a scaling bug — exactly what Sherlock #21/#29 fixed in `PortfolioStrategy`.

#### Scenario: D12 as a literal
- **WHEN** `1e12` appears as a literal for USDC-vault share scale
- **THEN** it is a violation — `D12` is derived (2 × assetDecimals), never written as a constant

#### Scenario: Static scale where Dn is required
- **WHEN** a conversion hard-codes `1e8` for a feed whose `decimals()` is dynamic
- **THEN** it is the Sherlock #21/#29 bug class — the scale must come from the runtime `decimals()` read
