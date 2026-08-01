# wood-pricing (delta)

## ADDED Requirement: The TWAP may only lower the WOOD price, never raise it

This is the load-bearing invariant. It is stated as a requirement rather than a
comment because the whole safety argument rests on it: the TWAP source is a
~$438k pool, and promoting it to a primary price would make that pool the
valuation basis for all guardian collateral.

#### Scenario: TWAP above the governance number

- **GIVEN** an oracle is wired and reporting a fresh TWAP
- **AND** `twapUsd > woodUsdPriceX8`
- **THEN** `woodPriceX8()` returns `_haircut(woodUsdPriceX8)` — the TWAP is
  ignored entirely, so manipulating it upward changes nothing.

#### Scenario: TWAP below the governance number

- **GIVEN** `twapUsd < woodUsdPriceX8`
- **THEN** `woodPriceX8()` returns `_haircut(twapUsd)` — the ceiling binds, and
  a governance number that has drifted above market stops overvaluing bonds.

## ADDED Requirement: An unavailable TWAP degrades to today's behaviour

The change must be incapable of failing *worse* than the current design.

#### Scenario: no oracle wired

- **GIVEN** the oracle address is `address(0)`
- **THEN** `woodPriceX8()` behaves exactly as it does today.

#### Scenario: stale snapshot falls back to the maintained price

- **GIVEN** the oracle's last `update()` is older than `maxTwapAge`
- **AND** `woodFallbackPriceX8 != 0`
- **THEN** `woodPriceX8()` returns
  `_haircut(min(woodFallbackPriceX8, woodUsdPriceX8))` — the maintained
  conservative price, still capped by the emergency ceiling.
- **AND** it does **not** fall back to `woodUsdPriceX8` as a *price*: that
  number is deliberately set high under the emergency-only doctrine, so using
  it as the price would fail in the dangerous direction at exactly the moment
  market data stopped arriving.

#### Scenario: no price from any source

- **GIVEN** the TWAP is unavailable or stale
- **AND** `woodFallbackPriceX8 == 0`
- **THEN** `woodPriceX8()` **reverts** `NoWoodPrice`.
- **AND** a deploy pre-flight asserts `woodFallbackPriceX8 != 0` and
  `woodUsdPriceX8 != 0`, so this state is unreachable in production and the
  revert is a configuration guard rather than a live failure mode.

Serving `0` here is rejected as the alternative: it silently values every bond
at nothing, and `effectiveTotal == 0` on the slash path marks a challenge
convicted while recovering nothing and permanently blocking a re-file
(2026-08-01 audit). A loud failure on an unreachable state beats a silent one
on a reachable path.

## ADDED Requirement: The emergency ceiling caps every source

#### Scenario: brake pulled while the TWAP is live

- **WHEN** the owner lowers `woodUsdPriceX8`
- **THEN** the new value caps the TWAP-derived price immediately.

#### Scenario: brake pulled while the fallback is in use

- **GIVEN** the TWAP is stale and the fallback price is serving
- **WHEN** the owner lowers `woodUsdPriceX8`
- **THEN** the new value caps the fallback price too — the brake must not have
  a hole on the branch that is live precisely when it is being pulled.

#### Scenario: oracle reverts, is codeless, or returns malformed data

- **GIVEN** the wired oracle has no code, reverts, or returns short data
- **THEN** `woodPriceX8()` still returns a price from the governance number,
  mirroring `_woodPrice`'s existing `code.length` + `try/catch` treatment of a
  bad Chainlink feed.

#### Scenario: ETH/USD feed unusable

- **GIVEN** the ETH/USD Chainlink feed is stale, unset, or non-positive
- **THEN** the TWAP cannot be converted to USD, so `consult()` reports
  unavailable and the ceiling is skipped.

## ADDED Requirement: The oracle is permissionless and non-discretionary

#### Scenario: anyone snapshots

- **WHEN** any address calls `update()`
- **THEN** it succeeds and records `(cumulative, blockTimestamp)`; there is no
  owner check, no allowlist, and no privileged keeper.

#### Scenario: window is bounded

- **WHEN** the owner sets the TWAP window
- **THEN** values below the minimum (at least 1 hour) or above the configured
  maximum are rejected, so the window can neither be shrunk to a
  cheaply-manipulated interval nor stretched until it stops tracking reality.

## ADDED Requirement: The pair is validated before it is trusted

#### Scenario: wiring an oracle

- **WHEN** the owner wires an oracle
- **THEN** the wiring path confirms the configured pair reports the expected
  token ordering for the WOOD/WETH pair and that its cumulative accumulator is
  non-zero, so an empty or wrong-token pool cannot be wired by address alone.

#### Scenario: unwire

- **WHEN** the owner sets the oracle to `address(0)`
- **THEN** it is accepted, returning the protocol to the governance-only price —
  the same deliberate escape hatch `setWoodFeed` provides.

## MODIFIED Requirement: `woodPriceDetail` reports which source bound the price

`usingFallback` alone is uninformative once the fallback is permanent (there is
no Chainlink WOOD feed on 4663, so it is always `true`).

#### Scenario: operator inspects pricing

- **WHEN** `woodPriceDetail()` is called
- **THEN** it distinguishes at least: feed-priced, governance-priced, and
  governance-priced-but-capped-by-TWAP — so an operator can tell whether the
  ceiling is currently binding, which is the signal that the manual number has
  drifted.
