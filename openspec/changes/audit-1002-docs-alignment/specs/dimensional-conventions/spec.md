## MODIFIED Requirements

### Requirement: The composed WOOD price and the raw scalar are different quantities
`D8{USD/WOOD}` (`priceX8`) SHALL be the WOOD price normalized to 8 decimals via `(uint256(answer) * 1e8) / (10 ** f.feedDecimals)`. `woodPriceX8()` SHALL be `haircut(min(feedX8, woodUsdPriceX8))`, floored at 1: the governance-set `woodUsdPriceX8` is an UPPER CAP only. It is never served as a price and there is no fallback: a stale, unset or non-positive feed, or a zero cap, reverts `NoWoodPrice`. A cap set below market binds on every read and understates every bond valued at `woodPriceX8()`. The raw storage scalar `woodUsdPriceX8` and the composed `woodPriceX8()` (feed-derived, capped, haircut-applied) are DIFFERENT QUANTITIES at the same precision and SHALL NOT be substituted: `ChallengeGame.file` prices the challenger bond with `woodPriceX8()` so the bond and the slash rails share a basis — it previously read the raw scalar, and that mismatch was the bug.

#### Scenario: Bond priced off the raw scalar
- **WHEN** any slash-coupled figure reads `woodUsdPriceX8` directly instead of `woodPriceX8()`
- **THEN** the bond and the slash rails diverge whenever the feed is live — the composed accessor is the only valid basis

#### Scenario: No market source
- **WHEN** the WOOD feed is stale or unset while `woodUsdPriceX8` is non-zero
- **THEN** `woodPriceX8()` reverts `NoWoodPrice`; the cap is not used as a price

### Requirement: Vote weight is not spendable WOOD and not the slash basis
`WOOD{voteWeight}` (`getPastVotes`) SHALL be aged own stake: the raw own-stake checkpoint times the age factor. There is no delegated component. It is WOOD-scaled but NOT spendable WOOD and NOT the slash basis. `getPastStake` returns the raw, un-aged trace, and is the weight guardian review and emergency ballots use; subtracting one trace from the other is a basis error.

#### Scenario: Mixing aged and raw traces
- **WHEN** code computes `getPastVotes(...) - getPastStake(...)` or otherwise combines the two traces arithmetically
- **THEN** it is a basis error — one is aged, the other raw
