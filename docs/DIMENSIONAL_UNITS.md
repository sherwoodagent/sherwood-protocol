# Dimensional Units

The dimensional vocabulary for the guardian / insurance layer.

> **WHAT THIS IS FOR.** Every bug this vocabulary exists to expose has one shape:
> two quantities of identical Solidity type and precision where only one is
> correct, with no compiler check between them. `USD18{reserved}` vs
> `USD18{allocated}`; `WOOD{votable}` vs `WOOD{liability}`; the raw governance
> WOOD scalar vs the feed-composed price; vote weight vs raw stake. Each of
> those has already produced a real bug. Reach for this when adding arithmetic
> that crosses one of those boundaries.
>
> **Anchors are symbol names, not line numbers.** An earlier draft cited line
> numbers; every one of them had drifted before the document was first opened.
> Symbols survive edits, so they are what this file names.
>
> **Where this disagrees with the source, the source wins.** This is a reading
> of the code, not a specification the code is checked against.

Notation: `<PREFIX>{<unit>}` — `D18{USD}` is a USD amount carried as an integer
scaled by `1e18`. A brace tag after a unit (`USD18{reserved}`) marks a SEMANTIC
subtype: same integer scale, NOT interchangeable.

---

## Base Units

- `{USD}` — dollar value, always `D18{USD}` in this layer. Produced only by
  `ExposureLedger.coverageUsd` and `_slashableBondUsd`.
  Carried by: `coverageUsd`, `coveredTvlCapUsd`, `openExposureUsd`,
  `slashableBondUsd`, `liabilityUsd`, `allocatedUsd`, `frozenCoverageUsd`,
  `_committedUsd`, `_buckets`, `RecordedExposure.usd` (`uint192`).

- `{WOOD}` — WOOD wei, 18 decimals, plain ERC20 (no fee-on-transfer, no
  rebasing — asserted in `CompensationEscrow`'s header).
  Carried by: `Guardian.stakedAmount`, `totalGuardianStake`, `minGuardianStake`,
  `minOwnerStake`, `bondWood`, `counterBondWood`, `bondedWood`, `forfeitedWood`,
  `unclaimedWood`, `Case.proceeds`, `Case.redeemed`, `totalEscrowed`.

- `{ASSET}` — a vault's underlying ERC-20 in THAT ASSET'S OWN decimals (USDC 6,
  WETH 18). Never normalized on its own; only `coverageUsd` lifts it to
  `D18{USD}` using the cached `AssetFeed.assetDecimals`.
  Carried by: `SyndicateVault.totalAssets`, `asset()` balances,
  `SyndicateGovernor`'s `envelope.maxCapital` and `requiredCoverage`,
  strategy `nav()`.

- `{SHARE}` — ERC-4626 shares of a `SyndicateVault`. Share decimals are
  `assetDecimals + _decimalsOffset()`, and `_decimalsOffset()` RETURNS THE
  ASSET'S DECIMALS (stamped once into `_cachedDecimalsOffset` at `initialize`),
  so **share decimals = 2 × assetDecimals** — 12 dp on USDC, not 18 + 6.

- `{TOK}` — a generic external ERC-20 in its own `decimals()`
  (`PortfolioStrategy._tokenDecimals`, swap-adapter `amountIn`/`amountOutMinimum`).

- `{s}` — seconds. `block.timestamp`, `epochLength`, `challengeWindow`,
  `reviewPeriod`, `maturationPeriod`, `autoSlashDelay`, `disputeTimeout`,
  `voteWindow`, `SECONDS_PER_YEAR`, `elapsed`, `age`.

- `{bps}` — basis points, denominator `BPS_DENOMINATOR = 10_000`, declared
  independently in `ExposureLedger`, `GuardianRegistry`, `ChallengeGame` and
  `TokenCourt`. Carried by `proposerBondBps`, `woodHaircutBps`,
  `maxDelegatedSlashBps`, `minSlashBps`, `maxSlashBps`, `ageFloorBps`,
  `challengerBondBps`, `forfeitBurnBps`, `settleBurnBps`,
  `inconclusiveBurnBps`, `participationFloorBps`, `convictionBountyBps`,
  `maxSlippageBps`.

- `{1}` — dimensionless scalar with no bps denominator. `kNumerator`,
  `delegatedWeightCapX`, `epoch` index, `MAX_SCAN_BUCKETS`,
  `MAX_APPROVERS_PER_PROPOSAL`, `_frozenCommitments` (a COUNT, deliberately not
  a USD sum), `_frozenKeyCount`, `envelopeTier` (ordinal 0..3).

---

## The reservation / allocation split

**The headline distinction.** Both are `D18{USD}` `uint256`, both live in
`ExposureLedger`, and they are NOT interchangeable. Summing reservations where
an allocation is meant over-states exposure by a factor that GROWS WITH THE
APPROVER COUNT.

- `USD18{reserved}` — RESERVATION. What a guardian booked at approve time:
  `min(free budget, the proposal's FULL required coverage)` (`recordApproval`).
  Every approver reserves up to the whole need, so `sum(reserved) = A × needUsd`
  for A well-funded approvers — reservations SUM ABOVE the need.
  Carried by `RecordedExposure.usd`, `_committedUsd`, `_buckets`,
  `approversOf(...).committedUsd`, `openExposureUsd`, and the `haveUsd` sum
  inside `requireApproveQuorum` — correctly reservation-typed there, since
  summing allocations would be circular and fail on truncation dust.

- `USD18{allocated}` — ALLOCATION. What a guardian actually owes: the need split
  pro-rata by EFFECTIVE bond, so `sum(allocated) <= needUsd` (rounds down;
  `settleCoverage` hands the residue to the first holder). Produced by
  `_allocate`; read via `allocatedUsd`, `slashBpsFor`, `liabilityUsd`.

  **Two real bugs this distinction exists to catch**, both recorded in source
  comments: `ChallengeGame.file()` once summed `approversOf` (the RESERVATION)
  to size a challenger bond while every slash prices the ALLOCATION; and
  `slashBpsFor`'s note that slashing the reservation "would take the whole
  coverage from EVERY approver".

- `USD18{effective}` — `min(USD18{reserved}, USD18{bond})` for one guardian:
  what it can ACTUALLY pay, not what it pledged. The shared basis of
  `requireApproveQuorum`, `allocatedUsd`, `slashBpsFor` and `settleCoverage`.

- `USD18{effectiveTotal}` — sum of `USD18{effective}` over a proposal's approvers
  (`_effectiveTotal`). The pro-rata DENOMINATOR. Using raw `_committedUsd` here
  is a known wrong substitution.

- `USD18{need}` — required coverage, `coverageUsd(asset, requiredCoverage)`.
  Re-derived from the LIVE feed at each read, so two reads at different
  timestamps are not the same number.

- `USD18{bond}` — `slashableBondUsd(g)`, composed as `{WOOD} × D8{USD/WOOD} / 1e8`.

- `USD18{budget}` — `kNumerator × USD18{bond}`, the per-guardian batching cap;
  `free = budget − USD18{open}`.

- `USD18{liability}` — `min(USD18{need}, USD18{effectiveTotal})`, the cohort's
  real exposure on one proposal. The basis a challenger bond is sized against.

---

## Prices

- `D8{USD/WOOD}` (`priceX8`) — WOOD price normalized to 8 decimals via
  `(uint256(answer) * 1e8) / (10 ** f.feedDecimals)`, then multiplied by
  `woodHaircutBps / 10_000`. `woodPriceX8()` is feed-first with the
  governance-set `woodUsdPriceX8` as the degraded fallback.

  **`woodUsdPriceX8` (raw storage) and `woodPriceX8()` (composed) are different
  quantities at the same precision.** The raw scalar is a conservative
  governance floor; the composed value is feed-derived and haircut-applied.
  `ChallengeGame.file` prices the challenger bond with `woodPriceX8()` so the
  bond and the slash rails share a basis — it previously read the raw scalar,
  and that mismatch was the bug.

- `Dn{USD/TOK}` — a raw Chainlink `answer` at the feed's own `decimals()`
  (`AssetFeed.feedDecimals`, `PortfolioStrategy._priceDecimals`). NEVER assume
  18 or 8: `PortfolioStrategy` supports 8 (tokenized stocks) and 18 (crypto).

- `D18{USD/TOK}` (`PRICE_PRECISION = 1e18`) — `PortfolioStrategy`'s nominal
  price scale, and a **legacy anchor only**. Per the Sherlock #21/#29 fix, real
  conversions use `10 ** (tokenDecimals + priceDecimals)` against the cached
  `assetDecimals` (`_tokensToValue` / `_valueToTokens`), NOT the constant.

---

## Rates and ratios

- `{ASSET}/{SHARE}` — vault conversion rate, materialized as the frozen
  settlement pair `num = totalAssets() + 1`, `den = totalSupply() + 10 ** offset`,
  consumed by `VaultWithdrawalQueue` as `mulDiv(shares, num, den)`. `num` is
  `{ASSET}`, `den` is `{SHARE}`.

- `bps{slash}` — per-approver slash rate,
  `ceil(USD18{allocated} × 10_000 / USD18{bond})`, clamped to `10_000`
  (`slashBpsFor`). Rounds UP toward the protocol. Consumed **positionally** by
  `StakedWood.slashToEscrow` — alignment with the approver array is load-bearing.

- `bps{age}` — `_ageFactorBps`, a linear ramp from `ageFloorBps` at age 0 to
  `10_000` at `maturationPeriod`.

---

## Weights and snapshots

- `WOOD{voteWeight}` — `getPastVotes` = aged own stake + delegated inbound,
  capped at `delegatedWeightCapX × agedOwn`. WOOD-scaled but **NOT spendable
  WOOD and NOT the slash basis**. `getPastStake` returns the raw, un-aged trace;
  subtracting one from the other is a basis error.

- `WOOD{liability}` vs `WOOD{votable}` — two distinct checkpoint traces on the
  same guardian. `_liabilityCheckpoints` is NOT zeroed by
  `requestUnstakeGuardian`; `_stakeCheckpoints` is. `_slashOne` takes `Math.max`
  of the two. Substituting the votable trace for the liability trace is the
  PR #25 F1b bug — an exiting guardian would escape a slash it already owed.

- `SHARE{votes}` — vault `ERC20Votes` weight at a past timestamp, the
  compensation apportionment numerator: `proceeds × votes / snapshotSupply`
  yields `{WOOD}` (`CompensationEscrow`, with `Case.snapshotSupply` cached at
  open so a past snapshot cannot change).

---

## Time

- `{epoch}` — dimensionless bucket index,
  `(block.timestamp - epochGenesis) / epochLength`. **Two independent epoch
  clocks exist and are not comparable:** `ExposureLedger.epochLength`
  (immutable) and `GuardianRegistry.EPOCH_DURATION` (7 days).

---

## Precision Prefixes

- `D6` — `1e6`. USDC/USDT native decimals.
- `D8` — `1e8`. Chainlink USD feeds and the canonical `priceX8` WOOD price.
- `D12` — `1e12`. `SyndicateVault` share decimals when the asset is USDC
  (= 2 × assetDecimals). Derived, never a literal in source.
- `D18` — `1e18`. `WAD`. WOOD wei, all USD coverage/liability/bond values,
  `PRICE_PRECISION`, `MIN_COHORT_STAKE_AT_OPEN`.
- `BPS` — `10_000`. `BPS_DENOMINATOR`, declared separately in four contracts.
- `Dn` (dynamic) — `10 ** decimals`, resolved at runtime from
  `IERC20Metadata.decimals()` or `IAggregatorV3.decimals()` (bounded at 36).
  **Any site that hard-codes `1e18` or `1e8` where a dynamic `Dn` is required is
  a scaling bug** — exactly what Sherlock #21/#29 fixed in `PortfolioStrategy`.
