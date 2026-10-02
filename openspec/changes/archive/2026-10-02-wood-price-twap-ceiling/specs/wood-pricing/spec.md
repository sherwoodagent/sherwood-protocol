# wood-pricing (delta)

> Reflects revision 2 (see `../../design-revision-2026-08-01.md`), which
> deleted `woodFallbackPriceX8` and made `woodUsdPriceX8` a cap that is never
> served as a price. The unavailability requirements below were re-derived
> against that model rather than annotated on top of it.

## ADDED Requirements

### Requirement: The TWAP may only lower the WOOD price, never raise it

The TWAP SHALL only ever lower the WOOD price relative to the governance
number, and SHALL NEVER raise it.

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

### Requirement: An unavailable price halts new risk without halting the protocol

With no fresh market source, `woodPriceX8()` SHALL revert `NoWoodPrice` rather
than serve a price. `woodUsdPriceX8` is a CAP and SHALL NEVER be served as a
price, so there is no branch on which a hand-maintained number becomes the
valuation:

```
sourceX8 = feed fresh ? min(feedX8, woodUsdPriceX8)
         : twap fresh ? min(twapX8, woodUsdPriceX8)
         :              revert NoWoodPrice          // incl. a zero cap
price    = haircut(sourceX8), floored at 1 when sourceX8 != 0
```

`recordApproval` SHALL CATCH `NoWoodPrice` and book nothing; every other
consumer SHALL let it revert. The adversary for that carve-out is a stale
price turning a full review into a block-only one: a revert inside
`recordApproval` disenfranchises approvers while block votes still land, which
is the failure reviews M3/N1/N4 each removed.

Serving `0` instead of reverting is rejected: it silently values every bond at
nothing, and `effectiveTotal == 0` on the slash path marks a challenge
convicted while recovering nothing and permanently blocking a re-file
(2026-08-01 audit). A loud failure beats a silent one.

#### Scenario: no oracle wired

- **GIVEN** the oracle address is `address(0)`
- **AND** no fresh Chainlink WOOD feed is configured, as on chain 4663
- **THEN** `woodPriceX8()` reverts `NoWoodPrice` — this is not a working
  production configuration, not a degraded one

#### Scenario: no price from any source

- **GIVEN** neither the feed nor the TWAP is fresh, or the cap is zero
- **THEN** `woodPriceX8()` **reverts** `NoWoodPrice`
- **AND** a deploy pre-flight asserts `woodUsdPriceX8 != 0` and that the
  composed price resolves non-zero, so the state is a configuration guard
  rather than a live failure mode

#### Scenario: approvers are not disenfranchised by a stale price

- **GIVEN** no source is fresh, so the WOOD read reverts `NoWoodPrice`
- **THEN** `recordApproval` catches it and books nothing, while
  `requireApproveQuorum`, `propose` and `ChallengeGame.file` let it revert
- **AND** the net effect is that proposals can neither be created nor executed,
  votes still function, and live challenges resolve normally

### Requirement: The emergency ceiling caps every source

Lowering `woodUsdPriceX8` SHALL cap the price served on every branch, whatever
source is live at the time. The brake MUST NOT have a hole on the branch that
is serving precisely when it is pulled.

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
- **THEN** the read degrades to "TWAP unavailable" rather than propagating the
  failure, mirroring `_woodPrice`'s existing `code.length` + `try/catch`
  treatment of a bad Chainlink feed
- **AND** with no fresh feed either, `woodPriceX8()` then reverts
  `NoWoodPrice` — it does NOT fall back to serving the governance number

#### Scenario: ETH/USD feed unusable

- **GIVEN** the ETH/USD Chainlink feed is stale, unset, or non-positive
- **THEN** the TWAP cannot be converted to USD, so `consult()` reports
  unavailable and the ceiling is skipped.

### Requirement: The oracle is permissionless and non-discretionary

`update()` SHALL be callable by any address, with no owner check, allowlist, or
privileged keeper. The TWAP window SHALL be bounded on both sides, so it can
neither be shrunk to a cheaply-manipulated interval nor stretched until it
stops tracking reality.

#### Scenario: anyone snapshots

- **WHEN** any address calls `update()`
- **THEN** it succeeds and records `(cumulative, blockTimestamp)`; there is no
  owner check, no allowlist, and no privileged keeper.

#### Scenario: window is bounded

- **WHEN** the owner sets the TWAP window
- **THEN** values below the minimum (at least 1 hour) or above the configured
  maximum are rejected, so the window can neither be shrunk to a
  cheaply-manipulated interval nor stretched until it stops tracking reality.

### Requirement: The pair is validated before it is trusted

The wiring path SHALL confirm the configured pair's token ordering and a
non-zero cumulative accumulator, so an empty or wrong-token pool cannot be
wired by address alone. Unwiring by setting the oracle to `address(0)` SHALL
remain accepted as a deliberate escape hatch.

#### Scenario: wiring an oracle

- **WHEN** the owner wires an oracle
- **THEN** the wiring path confirms the configured pair reports the expected
  token ordering for the WOOD/WETH pair and that its cumulative accumulator is
  non-zero, so an empty or wrong-token pool cannot be wired by address alone.

#### Scenario: unwire

- **WHEN** the owner sets the oracle to `address(0)`
- **THEN** it is accepted, returning the protocol to the governance-only price —
  the same deliberate escape hatch `setWoodFeed` provides.

## MODIFIED Requirements

### Requirement: `woodPriceDetail` reports which source bound the price

`woodPriceDetail()` SHALL return `(price, fromFeed, capBinding)` rather than
`(price, usingFallback)` — naming which market source answered, and whether
`woodUsdPriceX8` is currently binding that answer.

`usingFallback` alone is uninformative once there is no Chainlink WOOD feed on
4663, so it is always `true` and never distinguishes anything.

#### Scenario: operator inspects pricing

- **WHEN** `woodPriceDetail()` is called
- **THEN** it reports whether the feed or the TWAP answered, and whether the
  cap is binding — so an operator can tell that the manual number has drifted
  below market, which is the state in which the cap silently becomes the
  valuation basis.
