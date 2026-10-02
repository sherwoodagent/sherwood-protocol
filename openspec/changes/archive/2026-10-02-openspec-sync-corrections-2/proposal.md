# OpenSpec sync corrections, round 2: review findings on PR #378

## Why

An independent spec-compliance review of the OpenSpec sync replayed every archive and traced the resulting specs against the code on `post-audit-v2`. It found two statements that are false on the code and eight smaller imprecisions. This change corrects them through deltas, each checked against the code first. It is documents only.

## What Changes

- `tier-policy`: coverage is sized per call (`Σ cap_i × boundBps_i / 10_000` over both legs), not `maxCapital × Σ boundBps`; the class epoch is named `_classEpoch`.
- `concentrated-liquidity-strategy`: init does not check the tick domain; an out-of-domain range reverts inside the position manager's mint at execute.
- `syndicate-vault`: an owner raise of `minBufferBps` mid-proposal can make a net-inflow settlement batch revert `BufferBreached`.
- `syndicate-governor`: the state transition precedes the execute batch, not every external call; an invalid fee split would zero the fee legs, and `ProtocolConfig` makes one unreachable.
- `guardian-staking`: with no ledger wired a blocked review slashes nothing; the consent requirement is restated without an issue reference in a scenario title.
- `challenge-game`: `file` also reverts `AlreadyConvicted` on a `verdictSlashed` accused, and reports `WoodPriceUnset` / `BondTooSmall` before an unwired sWOOD's `ZeroAddress`; the gas-floor arithmetic uses the code's single 63/64 haircut.
- `deployment-docs`: vnet identifiers removed; the delegation pre-flight is described as the selector probe it is.
- `guardian-agent`, `guardian-fleet`: who signs `openReview` / `resolveReview` is stated consistently — an agent alone in `defend` mode, the keeper role in a fleet.

## Capabilities

### Modified Capabilities

- `tier-policy`, `concentrated-liquidity-strategy`, `syndicate-vault`, `syndicate-governor`, `guardian-staking`, `challenge-game`, `deployment-docs`, `guardian-agent`, `guardian-fleet`.

## Impact

`openspec/` only. No source, test, script or storage change.
