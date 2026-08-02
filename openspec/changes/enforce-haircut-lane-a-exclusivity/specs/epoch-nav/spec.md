# epoch-nav — delta

## MODIFIED Requirements

### Requirement: Router pricing parameters are owner-gated with a one-way haircut

All `PriceRouter` configuration SHALL be restricted to the owner:

- `registerAdapter(kind, adapter)` SHALL revert `ZeroAddress` for a zero adapter and emit `AdapterRegistered`.
- `setHaircutBps(kind, bps)` SHALL revert `HaircutTooHigh` above 10_000 and `HaircutCannotDecrease` when lowering — the haircut is monotone-increasing; lowering requires a contract upgrade.
- `setInstantCap(kind, cap)` SHALL set the per-kind instant ceiling (0 = unlimited) and emit `InstantCapSet`.
- `setLaneAEnabled(kind, enabled)` SHALL gate the instant lane per kind; the default is `false`, so a position kind is instant-eligible only after governance explicitly enables it.

A nonzero haircut and an enabled Lane A SHALL be mutually exclusive per kind. The state `haircutBps[kind] != 0 && laneAEnabled[kind] == true` MUST be unreachable through the setters, from either direction:

- `setHaircutBps(kind, bps)` SHALL revert `HaircutLaneAConflict` when `bps != 0` and `laneAEnabled[kind] == true`.
- `setLaneAEnabled(kind, true)` SHALL revert `HaircutLaneAConflict` when `haircutBps[kind] != 0`.
- `setLaneAEnabled(kind, false)` SHALL NOT be blocked by the haircut — disabling is the de-escalation path and MUST always be available.
- `setHaircutBps(kind, 0)` SHALL remain subject only to the pre-existing checks (it cannot conflict; whether it is reachable is governed by `HaircutCannotDecrease`).

Adversary: the haircut discounts the single value `totalAssets()` consumes for both deposit and redemption, so on a Lane-A-enabled kind a depositor mints against understated NAV — a wealth transfer from existing holders — and `HaircutCannotDecrease` makes that state permanent once reached. The exclusion refuses the transfer instead of arming it; a kind that needs a haircut is a kind whose instant lane must stay closed until the two-sided quote exists.

#### Scenario: Haircut cannot be lowered

- **WHEN** the owner attempts to set a kind's haircut below its current value
- **THEN** the call reverts `HaircutCannotDecrease`

#### Scenario: Lane A is opt-in per kind

- **WHEN** a new adapter is registered for a kind but `setLaneAEnabled` has not been called
- **THEN** `valueStrategy` returns `(0, false)` for any strategy holding that kind

#### Scenario: A live Lane A kind refuses a haircut

- **WHEN** `laneAEnabled[kind] == true` and the owner calls `setHaircutBps(kind, bps)` with `bps != 0`
- **THEN** the call reverts `HaircutLaneAConflict` and `haircutBps[kind]` is unchanged

#### Scenario: A haircut kind refuses Lane A enablement

- **WHEN** `haircutBps[kind] != 0` and the owner calls `setLaneAEnabled(kind, true)`
- **THEN** the call reverts `HaircutLaneAConflict` and `laneAEnabled[kind]` remains `false`

#### Scenario: The unsafe state is unreachable from either order

- **WHEN** the owner attempts haircut-then-enable, or enable-then-haircut, for the same kind with a nonzero haircut
- **THEN** the second call of either sequence reverts `HaircutLaneAConflict`

#### Scenario: Disabling Lane A is never blocked

- **WHEN** the owner calls `setLaneAEnabled(kind, false)`, regardless of `haircutBps[kind]`
- **THEN** the call succeeds and emits `LaneAEnabledSet(kind, false)`

#### Scenario: Haircut zero and Lane A enabled is the supported live configuration

- **WHEN** `haircutBps[kind] == 0` and the owner calls `setLaneAEnabled(kind, true)`, or Lane A is enabled and the owner calls `setHaircutBps(kind, 0)`
- **THEN** both calls succeed exactly as before this change

#### Scenario: A haircut on a Lane-A-disabled kind still works

- **WHEN** `laneAEnabled[kind] == false` and the owner calls `setHaircutBps(kind, bps)` with `0 < bps <= 10_000` and `bps >= haircutBps[kind]`
- **THEN** the call succeeds and emits `HaircutSet(kind, bps)`

#### Scenario: A nonzero haircut permanently closes the kind's instant lane

- **WHEN** a kind acquired a nonzero haircut (necessarily while Lane A was disabled)
- **THEN** `setHaircutBps(kind, 0)` reverts `HaircutCannotDecrease` and `setLaneAEnabled(kind, true)` reverts `HaircutLaneAConflict` — the kind cannot re-enter Lane A without a contract upgrade, which is the accepted fail-safe outcome
